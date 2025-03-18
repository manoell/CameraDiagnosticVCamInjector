#import "VCamInjector.h"

// Ponto chave de injeção - captura de dados de vídeo
%hook NSObject

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se somos o delegate correto
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    // Verificar se a substituição está habilitada
    if (!VCamShouldReplaceFrame()) {
        %orig;
        return;
    }
    
    // Analisar buffer original para logs e diagnóstico
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer) {
        size_t width = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
        
        // Log a cada N frames para evitar spam
        static uint64_t frameCounter = 0;
        frameCounter++;
        
        if (frameCounter % 100 == 0) {
            NSLog(@"[VCamHook] Frame #%llu: %zux%zu, Format: %d", 
                  frameCounter, width, height, (int)pixelFormat);
        }
    }
    
    // Criar buffer substituto
    CMSampleBufferRef replacementBuffer = VCamCreateReplacementSampleBuffer(sampleBuffer, connection);
    
    // Chamar método original com o buffer modificado
    if (replacementBuffer && replacementBuffer != sampleBuffer) {
        // Substituir o buffer
        [self captureOutput:output didOutputSampleBuffer:replacementBuffer fromConnection:connection];
        
        // Liberar o buffer de substituição após o uso
        CFRelease(replacementBuffer);
    } else {
        // Usar o buffer original se não conseguimos substituir
        %orig;
    }
}

%end

// Hook para monitorar orientação de vídeo
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    NSLog(@"[VCamHook] Orientação de vídeo alterada: %d", (int)videoOrientation);
    %orig;
}

- (void)setVideoMirrored:(BOOL)videoMirrored {
    NSLog(@"[VCamHook] Espelhamento de vídeo: %@", videoMirrored ? @"SIM" : @"NÃO");
    
    // Atualizar configuração de espelhamento
    [VCamInjector sharedInstance].mirrorOutput = videoMirrored;
    
    %orig;
}

%end

// Hook para monitorar sessão e detectar mudanças importantes
%hook AVCaptureSession

- (void)startRunning {
    NSLog(@"[VCamHook] Sessão de captura iniciada");
    %orig;
}

- (void)stopRunning {
    NSLog(@"[VCamHook] Sessão de captura interrompida");
    %orig;
}

- (void)addInput:(AVCaptureInput *)input {
    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
        AVCaptureDevice *device = deviceInput.device;
        
        NSLog(@"[VCamHook] Dispositivo adicionado: %@ - Posição: %d", 
              device.localizedName, (int)device.position);
        
        // Detectar câmera frontal vs traseira
        BOOL isFrontCamera = (device.position == AVCaptureDevicePositionFront);
        
        // Atualizar configuração de espelhamento com base na câmera
        if (isFrontCamera) {
            [VCamInjector sharedInstance].mirrorOutput = YES;
        }
    }
    
    %orig;
}

- (void)removeInput:(AVCaptureInput *)input {
    NSLog(@"[VCamHook] Input removido da sessão");
    %orig;
}

%end

// Inicialização do tweak
%ctor {
    @autoreleasepool {
        NSLog(@"[VCamHook] Inicializando hook de câmera virtual");
        
        // Criar diretório para arquivos de recursos
        NSString *appSupportDir = @"/var/mobile/Library/Application Support/VCamMJPEG";
        [[NSFileManager defaultManager] createDirectoryAtPath:appSupportDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
        
        // Carregar configuração
        [[VCamConfiguration sharedConfig] loadSettings];
        
        // Inicializar injetor com configurações
        VCamInjector *injector = [VCamInjector sharedInstance];
        [injector setupWithOptions:[[VCamConfiguration sharedConfig] currentSettings]];
        
        // Ativar injeção
        VCamSetEnabled(YES);
        
        // Observar notificações de mudança de estado
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification *note) {
            NSLog(@"[VCamHook] Aplicativo ativo, verificando estado da injeção");
        }];
        
        // Observar troca para background
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification *note) {
            NSLog(@"[VCamHook] Aplicativo em background");
        }];
        
        // Inicializar todos os hooks
        %init;
    }
}

// Limpeza final
%dtor {
    NSLog(@"[VCamHook] Finalizando e limpando recursos");
    
    // Desativar injeção
    VCamSetEnabled(NO);
    
    // Limpar recursos
    [[VCamInjector sharedInstance] clearBufferCache];
    
    // Salvar configurações
    [[VCamConfiguration sharedConfig] saveSettings];
}