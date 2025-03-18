#import "VCamInjector.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <Accelerate/Accelerate.h>

// Log de debug
#define VCAM_DEBUG 1
#define VCAMLog(fmt, ...) if (VCAM_DEBUG) NSLog(@"[VCamInjector] " fmt, ##__VA_ARGS__)

// Constantes
static NSString * const kSourceTypeFile = @"file";
static NSString * const kSourceTypeJPEG = @"jpeg";
static NSString * const kSourceTypeStream = @"stream";
static NSString * const kSourceTypeCamera = @"camera";

// Globais privadas para acesso rápido em hooks
static BOOL g_vcam_enabled = NO;
static uint64_t g_frameCounter = 0;
static NSMutableDictionary *g_pixelBufferCache = nil;
static dispatch_queue_t g_processingQueue = nil;

// Estatísticas de desempenho
static NSTimeInterval g_lastFrameTime = 0;
static float g_avgProcessingTime = 0;
static int g_processedFrameCount = 0;

#pragma mark - Implementação do VCamInjector

@implementation VCamInjector {
    NSLock *_stateLock;
    CVPixelBufferPoolRef _pixelBufferPool;
    CMFormatDescriptionRef _outputFormatDescription;
    NSCache *_imageCache;
    CMMemoryPoolRef _memoryPool;


- (void)saveSettings {
    // Salvar configurações atuais no arquivo
    NSDictionary *settings = [self currentSettings];
    [settings writeToFile:_configPath atomically:YES];
    
    // Salvar também no NSUserDefaults como backup
    [_defaults setObject:self.sourceType forKey:@"VCamSourceType"];
    [_defaults setObject:self.sourcePath forKey:@"VCamSourcePath"];
    [_defaults setBool:self.preserveAspectRatio forKey:@"VCamPreserveAspectRatio"];
    [_defaults setBool:self.mirrorOutput forKey:@"VCamMirrorOutput"];
    [_defaults setBool:self.applyFilters forKey:@"VCamApplyFilters"];
    [_defaults setBool:self.matchOriginalFPS forKey:@"VCamMatchOriginalFPS"];
    [_defaults setFloat:self.defaultResolution.width forKey:@"VCamDefaultWidth"];
    [_defaults setFloat:self.defaultResolution.height forKey:@"VCamDefaultHeight"];
    [_defaults synchronize];
    
    VCAMLog(@"Configurações salvas em: %@", _configPath);
}

- (void)resetToDefaults {
    // Restaurar valores padrão
    self.sourceType = kSourceTypeFile;
    self.sourcePath = @"/var/mobile/Library/Application Support/VCamMJPEG/default.jpg";
    self.preserveAspectRatio = YES;
    self.mirrorOutput = NO;
    self.applyFilters = NO;
    self.matchOriginalFPS = YES;
    self.defaultResolution = CGSizeMake(1280, 720);
    
    // Salvar configurações padrão
    [self saveSettings];
    
    VCAMLog(@"Configurações restauradas para valores padrão");
}

@end

#pragma mark - Funções C para uso em hooks

CMSampleBufferRef VCamCreateReplacementSampleBuffer(CMSampleBufferRef original, AVCaptureConnection *connection) {
    return [[VCamInjector sharedInstance] processVideoSampleBuffer:original fromConnection:connection];
}

BOOL VCamShouldReplaceFrame(void) {
    return g_vcam_enabled;
}

void VCamSetEnabled(BOOL enabled) {
    g_vcam_enabled = enabled;
    [VCamInjector sharedInstance].enabled = enabled;
}

CVPixelBufferRef VCamCreatePixelBuffer(size_t width, size_t height, OSType pixelFormat) {
    NSDictionary *options = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        (__bridge CFDictionaryRef)options,
        &pixelBuffer
    );
    
    if (status != kCVReturnSuccess) {
        VCAMLog(@"Falha ao criar pixel buffer: %d", status);
        return NULL;
    }
    
    return pixelBuffer;
}

UIImage *VCamImageFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) {
        return nil;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGContextRef context = CGBitmapContextCreate(
        baseAddress,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    
    return image;
}

NSData *VCamJPEGDataFromPixelBuffer(CVPixelBufferRef pixelBuffer, float quality) {
    UIImage *image = VCamImageFromPixelBuffer(pixelBuffer);
    
    if (!image) {
        return nil;
    }
    
    return UIImageJPEGRepresentation(image, quality);
}

}

#pragma mark - Inicialização

+ (instancetype)sharedInstance {
    static VCamInjector *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _stateLock = [[NSLock alloc] init];
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 10; // Limitar cache para evitar vazamento de memória
        _sourceType = kSourceTypeFile;
        _preserveAspectRatio = YES;
        _mirrorOutput = NO;
        _targetResolution = CGSizeMake(1280, 720); // HD por padrão
        _enabled = NO;
        _processingFrame = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _averageProcessingTime = 0;
        
        // Criar fila de processamento
        if (!g_processingQueue) {
            g_processingQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        }
        
        // Inicializar cache de buffer
        if (!g_pixelBufferCache) {
            g_pixelBufferCache = [NSMutableDictionary dictionary];
        }
        
        // Criar pool de memória
        CMMemoryPoolCreate(NULL, &_memoryPool);
        
        VCAMLog(@"Injetor de câmera virtual inicializado");
    }
    return self;
}

- (void)dealloc {
    [self clearBufferCache];
    
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    
    if (_outputFormatDescription) {
        CFRelease(_outputFormatDescription);
        _outputFormatDescription = NULL;
    }
    
    if (_memoryPool) {
        CMMemoryPoolInvalidate(_memoryPool);
        CFRelease(_memoryPool);
        _memoryPool = NULL;
    }
}

- (void)setupWithOptions:(NSDictionary *)options {
    [_stateLock lock];
    
    if (options[@"enabled"]) {
        self.enabled = [options[@"enabled"] boolValue];
    }
    
    if (options[@"sourceType"]) {
        self.sourceType = options[@"sourceType"];
    }
    
    if (options[@"preserveAspectRatio"]) {
        self.preserveAspectRatio = [options[@"preserveAspectRatio"] boolValue];
    }
    
    if (options[@"mirrorOutput"]) {
        self.mirrorOutput = [options[@"mirrorOutput"] boolValue];
    }
    
    if (options[@"targetWidth"] && options[@"targetHeight"]) {
        CGFloat width = [options[@"targetWidth"] floatValue];
        CGFloat height = [options[@"targetHeight"] floatValue];
        if (width > 0 && height > 0) {
            self.targetResolution = CGSizeMake(width, height);
        }
    }
    
    [_stateLock unlock];
    
    // Atualizar estado global
    g_vcam_enabled = self.enabled;
    
    VCAMLog(@"Configuração atualizada: enabled=%d, sourceType=%@, targetRes=%@", 
           self.enabled, self.sourceType, NSStringFromCGSize(self.targetResolution));
}

#pragma mark - Métodos de Processamento Principal

- (CMSampleBufferRef)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer 
                              fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer || !self.enabled) {
        return sampleBuffer;
    }
    
    // Incrementar contador de frames
    _frameCount++;
    g_frameCounter++;
    
    // Para evitar processamento recursivo
    if (self.processingFrame) {
        return sampleBuffer;
    }
    
    // Iniciar medição de tempo
    NSTimeInterval startTime = CACurrentMediaTime();
    
    // Marcar como processando
    self.processingFrame = YES;
    
    // Analisar o buffer original
    CVImageBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!originalImageBuffer) {
        self.processingFrame = NO;
        return sampleBuffer;
    }
    
    // Obter informações do buffer original
    size_t originalWidth = CVPixelBufferGetWidth(originalImageBuffer);
    size_t originalHeight = CVPixelBufferGetHeight(originalImageBuffer);
    OSType originalPixelFormat = CVPixelBufferGetPixelFormatType(originalImageBuffer);
    
    // Atualizar resolução original
    self.originalResolution = CGSizeMake(originalWidth, originalHeight);
    
    // Decidir a resolução alvo
    CGSize targetSize = self.targetResolution;
    if (CGSizeEqualToSize(targetSize, CGSizeZero)) {
        targetSize = CGSizeMake(originalWidth, originalHeight);
    }
    
    // Obter buffer de substituição baseado na fonte configurada
    CVPixelBufferRef replacementBuffer = NULL;
    
    if ([self.sourceType isEqualToString:kSourceTypeFile]) {
        // Usar imagem de arquivo
        NSString *filePath = [[VCamConfiguration sharedConfig] sourcePath];
        replacementBuffer = [self pixelBufferFromFile:filePath];
    } 
    else if ([self.sourceType isEqualToString:kSourceTypeJPEG]) {
        // Implementação para dados JPEG (ex: de streaming)
        // Código omitido para brevidade
    } 
    else if ([self.sourceType isEqualToString:kSourceTypeStream]) {
        // Implementação para stream (ex: RTSP/HLS)
        // Código omitido para brevidade
    }
    
    // Se não conseguimos um buffer, usar o original
    if (!replacementBuffer) {
        self.processingFrame = NO;
        return sampleBuffer;
    }
    
    // Redimensionar o buffer se necessário
    if (CVPixelBufferGetWidth(replacementBuffer) != targetSize.width || 
        CVPixelBufferGetHeight(replacementBuffer) != targetSize.height) {
        
        CVPixelBufferRef resizedBuffer = [self resizePixelBuffer:replacementBuffer 
                                                        toWidth:targetSize.width 
                                                       toHeight:targetSize.height];
        
        if (resizedBuffer) {
            CVPixelBufferRelease(replacementBuffer);
            replacementBuffer = resizedBuffer;
        }
    }
    
    // Criar um novo sample buffer com nossas modificações
    CMSampleBufferRef modifiedSampleBuffer = NULL;
    
    // Obter timing info do buffer original
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
    
    // Obter formato de descrição para o novo buffer
    CMFormatDescriptionRef formatDescription = NULL;
    CMFormatDescriptionRef originalFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    
    // Usar o formato original quando possível para manter metadados
    if (originalFormatDesc && CVPixelBufferGetPixelFormatType(replacementBuffer) == originalPixelFormat) {
        formatDescription = originalFormatDesc;
        CFRetain(formatDescription);
    } else {
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, replacementBuffer, &formatDescription);
    }
    
    // Criar novo sample buffer
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        replacementBuffer,
        formatDescription,
        &timing,
        &modifiedSampleBuffer
    );
    
    // Copiar metadados e attachments do buffer original
    if (status == noErr && modifiedSampleBuffer) {
        CFDictionaryRef originalAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        CFDictionaryRef newAttachments = CMSampleBufferGetSampleAttachmentsArray(modifiedSampleBuffer, true);
        
        if (originalAttachments && newAttachments) {
            // Copiar todos os attachments para manter metadados importantes
            CFIndex count = CFArrayGetCount(originalAttachments);
            for (CFIndex i = 0; i < count; i++) {
                CFDictionaryRef originalDict = (CFDictionaryRef)CFArrayGetValueAtIndex(originalAttachments, i);
                CFMutableDictionaryRef newDict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(newAttachments, i);
                
                CFIndex dictCount = CFDictionaryGetCount(originalDict);
                CFTypeRef *keys = (CFTypeRef *)malloc(sizeof(CFTypeRef) * dictCount);
                CFTypeRef *values = (CFTypeRef *)malloc(sizeof(CFTypeRef) * dictCount);
                
                CFDictionaryGetKeysAndValues(originalDict, keys, values);
                
                for (CFIndex j = 0; j < dictCount; j++) {
                    CFDictionarySetValue(newDict, keys[j], values[j]);
                }
                
                free(keys);
                free(values);
            }
        }
    }
    
    // Liberar recursos
    if (formatDescription) {
        CFRelease(formatDescription);
    }
    
    CVPixelBufferRelease(replacementBuffer);
    
    // Calcular tempo de processamento
    NSTimeInterval endTime = CACurrentMediaTime();
    NSTimeInterval processingTime = endTime - startTime;
    
    // Atualizar estatísticas de desempenho
    g_processedFrameCount++;
    g_avgProcessingTime = (g_avgProcessingTime * (g_processedFrameCount - 1) + processingTime) / g_processedFrameCount;
    self.averageProcessingTime = g_avgProcessingTime;
    self.lastFrameTime = processingTime;
    g_lastFrameTime = processingTime;
    
    // Registrar informações de processamento periodicamente
    if (g_frameCounter % 100 == 0) {
        VCAMLog(@"Frame #%llu processado em %.3fms (média: %.3fms)", 
               g_frameCounter, processingTime * 1000, g_avgProcessingTime * 1000);
    }
    
    // Finalizar processamento
    self.processingFrame = NO;
    
    // Retornar buffer modificado ou original em caso de erro
    return (status == noErr && modifiedSampleBuffer) ? modifiedSampleBuffer : sampleBuffer;
}

#pragma mark - Utilitários de Pixel Buffer

- (CVPixelBufferRef)createPixelBufferWithData:(NSData *)imageData 
                                  formatType:(OSType)formatType
                                     forSize:(CGSize)size {
    if (!imageData || imageData.length == 0) {
        return NULL;
    }
    
    // Criar buffer de pixel com tamanho e formato especificados
    CVPixelBufferRef pixelBuffer = NULL;
    
    NSDictionary *options = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferMemoryPoolKey: (__bridge id)_memoryPool
    };
    
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        size.width,
        size.height,
        formatType,
        (__bridge CFDictionaryRef)options,
        &pixelBuffer
    );
    
    if (result != kCVReturnSuccess) {
        VCAMLog(@"Falha ao criar pixel buffer: %d", result);
        return NULL;
    }
    
    // Processar dados de imagem e preencher o buffer
    // Implementação varia dependendo do formato de imagem
    // Código simplificado para economia de espaço
    
    return pixelBuffer;
}

- (CVPixelBufferRef)resizePixelBuffer:(CVPixelBufferRef)sourceBuffer 
                            toWidth:(size_t)width 
                           toHeight:(size_t)height {
    if (!sourceBuffer) {
        return NULL;
    }
    
    size_t sourceWidth = CVPixelBufferGetWidth(sourceBuffer);
    size_t sourceHeight = CVPixelBufferGetHeight(sourceBuffer);
    OSType sourcePixelFormat = CVPixelBufferGetPixelFormatType(sourceBuffer);
    
    // Criar buffer de destino
    CVPixelBufferRef destBuffer = NULL;
    
    NSDictionary *options = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferMemoryPoolKey: (__bridge id)_memoryPool
    };
    
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        sourcePixelFormat,
        (__bridge CFDictionaryRef)options,
        &destBuffer
    );
    
    if (result != kCVReturnSuccess) {
        VCAMLog(@"Falha ao criar buffer de destino: %d", result);
        return NULL;
    }
    
    // Bloquear buffers para acesso
    CVPixelBufferLockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destBuffer, 0);
    
    // Podemos usar vImage para redimensionamento eficiente
    if (sourcePixelFormat == kCVPixelFormatType_32BGRA) {
        // Configurar estruturas vImage
        vImage_Buffer srcBuffer = {
            .data = CVPixelBufferGetBaseAddress(sourceBuffer),
            .width = sourceWidth,
            .height = sourceHeight,
            .rowBytes = CVPixelBufferGetBytesPerRow(sourceBuffer)
        };
        
        vImage_Buffer dstBuffer = {
            .data = CVPixelBufferGetBaseAddress(destBuffer),
            .width = width,
            .height = height,
            .rowBytes = CVPixelBufferGetBytesPerRow(destBuffer)
        };
        
        // Redimensionar com alta qualidade
        vImage_Error error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, NULL, kvImageHighQualityResampling);
        
        if (error != kvImageNoError) {
            VCAMLog(@"Erro ao redimensionar imagem: %ld", error);
            CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(destBuffer, 0);
            CVPixelBufferRelease(destBuffer);
            return NULL;
        }
    }
    else {
        // Para outros formatos, usaríamos outra abordagem
        // Como Core Graphics ou implementação manual
        // Código omitido para brevidade
        VCAMLog(@"Formato não suportado para redimensionamento: %d", sourcePixelFormat);
    }
    
    // Desbloquear buffers
    CVPixelBufferUnlockBaseAddress(sourceBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(destBuffer, 0);
    
    return destBuffer;
}

- (CMFormatDescriptionRef)createFormatDescriptionForPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return NULL;
    }
    
    CMFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &formatDescription);
    
    if (status != noErr) {
        VCAMLog(@"Falha ao criar descrição de formato: %d", (int)status);
        return NULL;
    }
    
    return formatDescription;
}

#pragma mark - Métodos de Fonte de Imagem

- (CVPixelBufferRef)pixelBufferFromFile:(NSString *)filePath {
    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return NULL;
    }
    
    // Verificar cache primeiro
    NSString *cacheKey = [NSString stringWithFormat:@"file:%@", filePath];
    CVPixelBufferRef cachedBuffer = (__bridge CVPixelBufferRef)[g_pixelBufferCache objectForKey:cacheKey];
    
    if (cachedBuffer) {
        CVPixelBufferRetain(cachedBuffer);
        return cachedBuffer;
    }
    
    // Criar UIImage a partir do arquivo
    UIImage *image = [UIImage imageWithContentsOfFile:filePath];
    if (!image) {
        VCAMLog(@"Falha ao carregar imagem do arquivo: %@", filePath);
        return NULL;
    }
    
    // Criar CGImage
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return NULL;
    }
    
    // Determinar dimensões
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    // Criar dicionário de atributos
    NSDictionary *options = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferMemoryPoolKey: (__bridge id)_memoryPool
    };
    
    // Criar buffer de pixel
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)options,
        &pixelBuffer
    );
    
    if (status != kCVReturnSuccess) {
        VCAMLog(@"Falha ao criar pixel buffer: %d", status);
        return NULL;
    }
    
    // Bloquear buffer para escrita
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Criar contexto de bitmap
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        baseAddress,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    
    // Desenhar imagem no contexto
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    
    // Limpar
    CGColorSpaceRelease(colorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Adicionar ao cache
    if (pixelBuffer) {
        // Retenção para o cache
        CVPixelBufferRetain(pixelBuffer);
        [g_pixelBufferCache setObject:(__bridge id)pixelBuffer forKey:cacheKey];
    }
    
    return pixelBuffer;
}

- (CVPixelBufferRef)pixelBufferFromJPEGData:(NSData *)jpegData {
    if (!jpegData || jpegData.length == 0) {
        return NULL;
    }
    
    // Criar UIImage a partir dos dados JPEG
    UIImage *image = [UIImage imageWithData:jpegData];
    if (!image) {
        VCAMLog(@"Falha ao criar imagem a partir de dados JPEG");
        return NULL;
    }
    
    // Usar método genérico para criar pixel buffer a partir da imagem
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return NULL;
    }
    
    // Código semelhante ao pixelBufferFromFile, criando buffer a partir do CGImage
    // Omitido para brevidade
    
    return NULL; // Implementação completa omitida
}

- (CVPixelBufferRef)pixelBufferFromStream:(NSURL *)streamURL {
    // Implementação para obter frame de um stream (RTSP, HLS, etc.)
    // Esta é uma implementação complexa que requer AVPlayer ou técnicas de streaming
    // Omitida para brevidade
    
    return NULL; // Implementação completa omitida
}

#pragma mark - Métodos de Gerenciamento

- (void)clearBufferCache {
    [_stateLock lock];
    
    // Liberar todos os buffers em cache
    for (NSString *key in g_pixelBufferCache) {
        CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)g_pixelBufferCache[key];
        if (buffer) {
            CVPixelBufferRelease(buffer);
        }
    }
    
    [g_pixelBufferCache removeAllObjects];
    [_imageCache removeAllObjects];
    
    [_stateLock unlock];
}

- (void)resetState {
    [_stateLock lock];
    
    self.processingFrame = NO;
    g_frameCounter = 0;
    _frameCount = 0;
    g_processedFrameCount = 0;
    g_avgProcessingTime = 0;
    _averageProcessingTime = 0;
    
    [self clearBufferCache];
    
    [_stateLock unlock];
}

@end

#pragma mark - Implementação de VCamConfiguration

@implementation VCamConfiguration {
    NSUserDefaults *_defaults;
    NSString *_configPath;
}

+ (instancetype)sharedConfig {
    static VCamConfiguration *sharedConfig = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedConfig = [[self alloc] init];
    });
    return sharedConfig;
}

- (instancetype)init {
    if (self = [super init]) {
        _defaults = [NSUserDefaults standardUserDefaults];
        
        // Diretório de configuração
        NSString *appSupportDir = @"/var/mobile/Library/Application Support/VCamMJPEG";
        [[NSFileManager defaultManager] createDirectoryAtPath:appSupportDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
        
        _configPath = [appSupportDir stringByAppendingPathComponent:@"config.plist"];
        
        // Valores padrão
        _sourceType = kSourceTypeFile;
        _sourcePath = @"/var/tmp/default.jpg";
        _preserveAspectRatio = YES;
        _mirrorOutput = NO;
        _applyFilters = NO;
        _matchOriginalFPS = YES;
        _defaultResolution = CGSizeMake(1280, 720);
        
        // Carregar configurações salvas
        [self loadSettings];
    }
    return self;
}

- (NSDictionary *)currentSettings {
    return @{
        @"sourceType": self.sourceType ?: kSourceTypeFile,
        @"sourcePath": self.sourcePath ?: @"",
        @"preserveAspectRatio": @(self.preserveAspectRatio),
        @"mirrorOutput": @(self.mirrorOutput),
        @"applyFilters": @(self.applyFilters),
        @"matchOriginalFPS": @(self.matchOriginalFPS),
        @"defaultWidth": @(self.defaultResolution.width),
        @"defaultHeight": @(self.defaultResolution.height)
    };
}

- (void)loadSettings {
    // Verificar configurações em arquivo
    NSDictionary *savedSettings = [NSDictionary dictionaryWithContentsOfFile:_configPath];
    
    if (savedSettings) {
        // Carregar valores salvos
        if (savedSettings[@"sourceType"]) {
            self.sourceType = savedSettings[@"sourceType"];
        }
        
        if (savedSettings[@"sourcePath"]) {
            self.sourcePath = savedSettings[@"sourcePath"];
        }
        
        if (savedSettings[@"preserveAspectRatio"] != nil) {
            self.preserveAspectRatio = [savedSettings[@"preserveAspectRatio"] boolValue];
        }
        
        if (savedSettings[@"mirrorOutput"] != nil) {
            self.mirrorOutput = [savedSettings[@"mirrorOutput"] boolValue];
        }
        
        if (savedSettings[@"applyFilters"] != nil) {
            self.applyFilters = [savedSettings[@"applyFilters"] boolValue];
        }
        
        if (savedSettings[@"matchOriginalFPS"] != nil) {
            self.matchOriginalFPS = [savedSettings[@"matchOriginalFPS"] boolValue];
        }
        
        if (savedSettings[@"defaultWidth"] && savedSettings[@"defaultHeight"]) {
            CGFloat width = [savedSettings[@"defaultWidth"] floatValue];
            CGFloat height = [savedSettings[@"defaultHeight"] floatValue];
            
            if (width > 0 && height > 0) {
                self.defaultResolution = CGSizeMake(width, height);
            }
        }
        
        VCAMLog(@"Configurações carregadas do arquivo: %@", _configPath);
    }
    else {
        // Verificar e carregar do NSUserDefaults como fallback
        NSString *sourceType = [_defaults objectForKey:@"VCamSourceType"];
        if (sourceType) {
            self.sourceType = sourceType;
        }
        
        NSString *sourcePath = [_defaults objectForKey:@"VCamSourcePath"];
        if (sourcePath) {
            self.sourcePath = sourcePath;
        }
        
        self.preserveAspectRatio = [_defaults boolForKey:@"VCamPreserveAspectRatio"];
        self.mirrorOutput = [_defaults boolForKey:@"VCamMirrorOutput"];
        self.applyFilters = [_defaults boolForKey:@"VCamApplyFilters"];
        self.matchOriginalFPS = [_defaults boolForKey:@"VCamMatchOriginalFPS"];
        
        CGFloat defaultWidth = [_defaults floatForKey:@"VCamDefaultWidth"];
        CGFloat defaultHeight = [_defaults floatForKey:@"VCamDefaultHeight"];
        
        if (defaultWidth > 0 && defaultHeight > 0) {
            self.defaultResolution = CGSizeMake(defaultWidth, defaultHeight);
        }
        
        VCAMLog(@"Configurações carregadas dos padrões");
    }
}