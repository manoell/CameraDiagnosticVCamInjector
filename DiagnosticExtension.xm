#import "DiagnosticTweak.h"
#import "VCamInjector.h"
#import <objc/runtime.h>

// Definições de constantes que podem estar faltando
#ifndef kCMFormatDescriptionExtension_ColorSpace
#define kCMFormatDescriptionExtension_ColorSpace CFSTR("ColorSpace")
#endif

#ifndef kCVImageBufferColorPrimaries_P3_D65
#define kCVImageBufferColorPrimaries_P3_D65 CFSTR("P3_D65")
#endif

// Adicionando diagnóstico avançado de formato de buffer
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    logToFile(@"AVCaptureVideoDataOutput setSampleBufferDelegate: chamado");
    
    // Registrar tipo de delegate para diagnóstico de ponto de injeção
    NSString *delegateClassName = NSStringFromClass([sampleBufferDelegate class]);
    NSMutableDictionary *delegateInfo = [NSMutableDictionary dictionary];
    delegateInfo[@"delegateClass"] = delegateClassName ?: @"<nil>";
    delegateInfo[@"hasQueue"] = sampleBufferCallbackQueue ? @YES : @NO;
    
    // Verificar métodos implementados pelo delegate
    if (sampleBufferDelegate) {
        NSMutableDictionary *methods = [NSMutableDictionary dictionary];
        
        // Verificar método principal de processamento de frames
        methods[@"captureOutput:didOutputSampleBuffer:fromConnection:"] =
            @([sampleBufferDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]);
        
        // Verificar outros métodos opcionais
        methods[@"captureOutput:didDropSampleBuffer:fromConnection:"] =
            @([sampleBufferDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]);
        
        delegateInfo[@"implementedMethods"] = methods;
    }
    
    addDiagnosticData(@"videoDataOutputDelegate", delegateInfo);
    
    %orig;
}

%end

// Diagnóstico avançado de pixel buffer
%hook NSObject

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Somente proceder se formos o delegate correto
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    static uint64_t frameCounter = 0;
    frameCounter++;
    
    // Analisar apenas a cada N frames para diagnóstico detalhado (reduzir sobrecarga)
    if (frameCounter % 30 == 0) {
        // Extrair e registrar informações detalhadas do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            NSMutableDictionary *bufferInfo = [NSMutableDictionary dictionary];
            
            // Dimensões e formato
            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
            size_t dataSize = CVPixelBufferGetDataSize(imageBuffer);
            
            bufferInfo[@"width"] = @(width);
            bufferInfo[@"height"] = @(height);
            bufferInfo[@"bytesPerRow"] = @(bytesPerRow);
            bufferInfo[@"dataSize"] = @(dataSize);
            bufferInfo[@"pixelFormat"] = @(pixelFormat);
            
            // Converter formato para string legível
            char formatStr[5] = {0};
            formatStr[0] = (pixelFormat >> 24) & 0xFF;
            formatStr[1] = (pixelFormat >> 16) & 0xFF;
            formatStr[2] = (pixelFormat >> 8) & 0xFF;
            formatStr[3] = pixelFormat & 0xFF;
            bufferInfo[@"pixelFormatString"] = [NSString stringWithCString:formatStr encoding:NSASCIIStringEncoding];
            
            // Planos de imagem (para formatos YUV)
            size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
            bufferInfo[@"planeCount"] = @(planeCount);
            
            if (planeCount > 0) {
                NSMutableArray *planesInfo = [NSMutableArray array];
                
                for (size_t i = 0; i < planeCount; i++) {
                    size_t planeWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, i);
                    size_t planeHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, i);
                    size_t planeBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, i);
                    
                    [planesInfo addObject:@{
                        @"index": @(i),
                        @"width": @(planeWidth),
                        @"height": @(planeHeight),
                        @"bytesPerRow": @(planeBytesPerRow)
                    }];
                }
                
                bufferInfo[@"planes"] = planesInfo;
            }
            
            // Metadados adicionais
            CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (formatDesc) {
                // Dimensões de vídeo
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
                bufferInfo[@"formatWidth"] = @(dimensions.width);
                bufferInfo[@"formatHeight"] = @(dimensions.height);
                
                // Clean aperture (corrigido para usar a assinatura correta)
                CGRect cleanAperture = CGRectZero;
                cleanAperture = CMVideoFormatDescriptionGetCleanAperture(formatDesc, true);
                bufferInfo[@"cleanAperture"] = NSStringFromCGRect(cleanAperture);
                
                // Para pixel aspect ratio, usamos uma abordagem alternativa ou comentamos se não estiver disponível
                #if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
                // Pixel aspect ratio para iOS 13+
                //CGFloat horizRatio = 0.0, vertRatio = 0.0;
                // Esta linha pode precisar ser adaptada conforme a API disponível
                bufferInfo[@"pixelAspectRatioInfo"] = @"Verificando via outro método";
                #endif
                
                // Espaço de cores
                CFTypeRef colorAttachments = CMFormatDescriptionGetExtension(formatDesc, kCMFormatDescriptionExtension_ColorPrimaries);
                if (colorAttachments) {
                    bufferInfo[@"colorPrimaries"] = (__bridge NSString *)colorAttachments;
                }
                
                // HDR
                if (@available(iOS 10.0, *)) {
                    CMVideoFormatDescriptionRef videoFormatDesc = (CMVideoFormatDescriptionRef)formatDesc;
                    CFTypeRef colorSpaceRef = CMFormatDescriptionGetExtension(videoFormatDesc, kCMFormatDescriptionExtension_ColorSpace);
CFStringRef colorSpace = colorSpaceRef ? (CFStringRef)colorSpaceRef : NULL;
                    if (colorSpace) {
                        bufferInfo[@"colorSpace"] = (__bridge NSString *)colorSpace;
                        
                        BOOL isHDR = (CFStringCompare(colorSpace, kCVImageBufferColorPrimaries_ITU_R_2020, 0) == kCFCompareEqualTo ||
                                     CFStringCompare(colorSpace, kCVImageBufferColorPrimaries_P3_D65, 0) == kCFCompareEqualTo);
                        
                        bufferInfo[@"isHDR"] = @(isHDR);
                    }
                }
            }
            
            // Timing e apresentação
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            CMTime decodeTime = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
            CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
            
            bufferInfo[@"presentationTimeSeconds"] = @(CMTimeGetSeconds(presentationTime));
            bufferInfo[@"decodeTimeSeconds"] = @(CMTimeGetSeconds(decodeTime));
            bufferInfo[@"durationSeconds"] = @(CMTimeGetSeconds(duration));
            
            // Informações de conexão
            if (connection) {
                NSMutableDictionary *connectionInfo = [NSMutableDictionary dictionary];
                
                if ([connection isVideoOrientationSupported]) {
                    connectionInfo[@"videoOrientationSupported"] = @YES;
                    connectionInfo[@"videoOrientation"] = @(connection.videoOrientation);
                    
                    // Orientação para string
                    NSString *orientationString = @"Unknown";
                    switch (connection.videoOrientation) {
                        case AVCaptureVideoOrientationPortrait:
                            orientationString = @"Portrait";
                            break;
                        case AVCaptureVideoOrientationPortraitUpsideDown:
                            orientationString = @"PortraitUpsideDown";
                            break;
                        case AVCaptureVideoOrientationLandscapeRight:
                            orientationString = @"LandscapeRight";
                            break;
                        case AVCaptureVideoOrientationLandscapeLeft:
                            orientationString = @"LandscapeLeft";
                            break;
                    }
                    connectionInfo[@"orientationString"] = orientationString;
                }
                
                connectionInfo[@"videoMirrored"] = @(connection.isVideoMirrored);
                
                if ([connection isVideoStabilizationSupported]) {
                    connectionInfo[@"videoStabilizationSupported"] = @YES;
                    connectionInfo[@"videoStabilizationMode"] = @(connection.activeVideoStabilizationMode);
                }
                
                bufferInfo[@"connection"] = connectionInfo;
            }
            
            // Adicionar ao log de diagnóstico
            addDiagnosticData(@"frameDetailedAnalysis", bufferInfo);
            
            // Para frames específicos, registrar informações de ponto potencial de injeção
            if (frameCounter % 300 == 0) { // A cada ~10s em 30fps
                NSMutableDictionary *injectionInfo = [NSMutableDictionary dictionary];
                
                injectionInfo[@"delegateClass"] = NSStringFromClass([self class]);
                injectionInfo[@"outputClass"] = NSStringFromClass([output class]);
                injectionInfo[@"frameCounter"] = @(frameCounter);
                
                // Analisar a hierarquia de objetos para identificar o aplicativo
                NSMutableArray *classHierarchy = [NSMutableArray array];
                Class currentClass = [self class];
                while (currentClass) {
                    [classHierarchy addObject:NSStringFromClass(currentClass)];
                    currentClass = class_getSuperclass(currentClass);
                }
                injectionInfo[@"delegateHierarchy"] = classHierarchy;
                
                // Verificar métodos relevantes
                NSMutableDictionary *methods = [NSMutableDictionary dictionary];
                methods[@"captureOutput:didOutputSampleBuffer:fromConnection:"] =
                    @([self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]);
                methods[@"captureOutput:didDropSampleBuffer:fromConnection:"] =
                    @([self respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]);
                
                injectionInfo[@"methods"] = methods;
                
                // Registrar informações do aplicativo
                injectionInfo[@"appName"] = [[NSProcessInfo processInfo] processName];
                injectionInfo[@"bundleId"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
                
                addDiagnosticData(@"potentialInjectionPoint", injectionInfo);
                
                // Log detalhado
                logToFile([NSString stringWithFormat:@"Ponto potencial de injeção identificado: %@ (%@)",
                          NSStringFromClass([self class]), [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"]);
            }
        }
    }
    
    %orig;
}

%end

// Hook avançado para formatos de mídia
%hook AVCaptureDevice

- (BOOL)lockForConfiguration:(NSError **)outError {
    BOOL result = %orig;
    
    if (result) {
        // Capturar formato ativo e capacidades detalhadas do dispositivo
        AVCaptureDeviceFormat *activeFormat = self.activeFormat;
        if (activeFormat) {
            NSMutableDictionary *formatInfo = [NSMutableDictionary dictionary];
            
            // Informações básicas do dispositivo
            formatInfo[@"deviceName"] = self.localizedName ?: @"unknown";
            formatInfo[@"deviceModelID"] = self.modelID ?: @"unknown";
            formatInfo[@"deviceUniqueID"] = self.uniqueID ?: @"unknown";
            formatInfo[@"devicePosition"] = @(self.position);
            
            // Mapear posição para string
            NSString *positionString = @"Unknown";
            switch (self.position) {
                case AVCaptureDevicePositionFront:
                    positionString = @"Front";
                    break;
                case AVCaptureDevicePositionBack:
                    positionString = @"Back";
                    break;
                case AVCaptureDevicePositionUnspecified:
                    positionString = @"Unspecified";
                    break;
            }
            formatInfo[@"positionString"] = positionString;
            
            // Formato ativo
            CMFormatDescriptionRef formatDescription = activeFormat.formatDescription;
            if (formatDescription) {
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                formatInfo[@"formatWidth"] = @(dimensions.width);
                formatInfo[@"formatHeight"] = @(dimensions.height);
                
                // FourCC do formato
                FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription);
                char subTypeStr[5] = {0};
                subTypeStr[0] = (mediaSubType >> 24) & 0xFF;
                subTypeStr[1] = (mediaSubType >> 16) & 0xFF;
                subTypeStr[2] = (mediaSubType >> 8) & 0xFF;
                subTypeStr[3] = mediaSubType & 0xFF;
                formatInfo[@"formatFourCC"] = [NSString stringWithCString:subTypeStr encoding:NSASCIIStringEncoding];
            }
            
            // Taxas de quadros suportadas
            NSMutableArray *frameRates = [NSMutableArray array];
            for (AVFrameRateRange *range in activeFormat.videoSupportedFrameRateRanges) {
                [frameRates addObject:@{
                    @"minFrameRate": @(range.minFrameRate),
                    @"maxFrameRate": @(range.maxFrameRate),
                    @"minFrameDuration": @(CMTimeGetSeconds(range.minFrameDuration)),
                    @"maxFrameDuration": @(CMTimeGetSeconds(range.maxFrameDuration))
                }];
            }
            formatInfo[@"frameRates"] = frameRates;
            
            // Capacidades de autofoco
            formatInfo[@"autoFocusSupported"] = @([self isFocusModeSupported:AVCaptureFocusModeAutoFocus]);
            formatInfo[@"continuousAutoFocusSupported"] = @([self isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]);
            formatInfo[@"currentFocusMode"] = @(self.focusMode);
            
            // Capacidades de estabilização
            if ([activeFormat isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard]) {
                formatInfo[@"standardStabilizationSupported"] = @YES;
            }
            
            if (@available(iOS 13.0, *)) {
                if ([activeFormat isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeCinematic]) {
                    formatInfo[@"cinematicStabilizationSupported"] = @YES;
                }
            }
            
            // Capacidades HDR - usamos verificação segura
            if ([self respondsToSelector:@selector(isAutoHDRSupported)]) {
                formatInfo[@"autoHDRSupported"] = @NO; // Valor padrão seguro
            }
            
            if (@available(iOS 13.0, *)) {
                // Verificar se o método existe antes de chamar
                SEL videoHDRSelector = NSSelectorFromString(@"isVideoHDRSupported");
                if ([activeFormat respondsToSelector:videoHDRSelector]) {
                    // Usar NSInvocation para chamar o método de forma segura
                    NSMethodSignature *signature = [activeFormat methodSignatureForSelector:videoHDRSelector];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                    [invocation setSelector:videoHDRSelector];
                    [invocation setTarget:activeFormat];
                    [invocation invoke];
                    BOOL isHDRSupported;
                    [invocation getReturnValue:&isHDRSupported];
                    formatInfo[@"videoHDRSupported"] = @(isHDRSupported);
                }
            }
            
            // Capacidades de profundidade - verificação segura
            if (@available(iOS 11.0, *)) {
                SEL depthDataSelector = NSSelectorFromString(@"isDepthDataDeliverySupported");
                if ([activeFormat respondsToSelector:depthDataSelector]) {
                    NSMethodSignature *signature = [activeFormat methodSignatureForSelector:depthDataSelector];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                    [invocation setSelector:depthDataSelector];
                    [invocation setTarget:activeFormat];
                    [invocation invoke];
                    BOOL isDepthSupported;
                    [invocation getReturnValue:&isDepthSupported];
                    formatInfo[@"depthDataSupported"] = @(isDepthSupported);
                }
                
                SEL portraitMatteSelector = NSSelectorFromString(@"isPortraitEffectsMatteDeliverySupported");
                if ([activeFormat respondsToSelector:portraitMatteSelector]) {
                    NSMethodSignature *signature = [activeFormat methodSignatureForSelector:portraitMatteSelector];
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                    [invocation setSelector:portraitMatteSelector];
                    [invocation setTarget:activeFormat];
                    [invocation invoke];
                    BOOL isMatteSupported;
                    [invocation getReturnValue:&isMatteSupported];
                    formatInfo[@"portraitEffectsMatteSupported"] = @(isMatteSupported);
                }
            }
            
            // Zoom
            formatInfo[@"minZoomFactor"] = @(self.minAvailableVideoZoomFactor);
            formatInfo[@"maxZoomFactor"] = @(self.maxAvailableVideoZoomFactor);
            formatInfo[@"currentZoomFactor"] = @(self.videoZoomFactor);
            
            // Log para diagnóstico
            addDiagnosticData(@"deviceDetailedCapabilities", formatInfo);
            
            // Log de texto para referência rápida
            // Usar acesso seguro aos valores numéricos
            NSNumber *widthNum = formatInfo[@"formatWidth"];
            NSNumber *heightNum = formatInfo[@"formatHeight"];
            int width = widthNum ? [widthNum intValue] : 0;
            int height = heightNum ? [heightNum intValue] : 0;
            
            // Acessar de forma segura arrays que podem estar vazios
            NSDictionary *firstFrameRate = frameRates.count > 0 ? frameRates[0] : @{@"minFrameRate": @(0), @"maxFrameRate": @(0)};
            
            logToFile([NSString stringWithFormat:@"Dispositivo: %@ (%@) - Resolução: %dx%d, Taxa: %.1f-%.1f FPS",
                       self.localizedName ?: @"unknown",
                       positionString,
                       width, height,
                       [firstFrameRate[@"minFrameRate"] floatValue],
                       [firstFrameRate[@"maxFrameRate"] floatValue]]);
        }
    }
    
    return result;
}

%end

// Monitorar processamento de amostra e metadados
%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    static uint64_t displayFrameCount = 0;
    displayFrameCount++;
    
    // Log menos frequente para evitar spam
    if (displayFrameCount % 300 == 0) { // Aproximadamente a cada 10 segundos a 30fps
        logToFile([NSString stringWithFormat:@"AVSampleBufferDisplayLayer recebeu frame #%llu", displayFrameCount]);
        
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            
            // Log da camada de exibição
            addDiagnosticData(@"displayLayer", @{
                @"frameCount": @(displayFrameCount),
                @"width": @(width),
                @"height": @(height),
                @"layerBounds": NSStringFromCGRect(self.bounds),
                @"videoGravity": self.videoGravity ?: @"default",
                @"timestamp": [NSDate date].description
            });
        }
    }
    
    %orig;
}

%end

// Monitoramento de propriedades de preview layer
%hook AVCaptureVideoPreviewLayer

- (void)setVideoGravity:(AVLayerVideoGravity)videoGravity {
    logToFile([NSString stringWithFormat:@"AVCaptureVideoPreviewLayer gravity: %@", videoGravity]);
    
    addDiagnosticData(@"previewLayerConfig", @{
        @"videoGravity": videoGravity,
        @"timestamp": [NSDate date].description
    });
    
    %orig;
}

- (void)setFrame:(CGRect)frame {
    // Registrar apenas mudanças significativas
    if (fabs(frame.size.width - self.frame.size.width) > 1 ||
        fabs(frame.size.height - self.frame.size.height) > 1) {
        
        logToFile([NSString stringWithFormat:@"AVCaptureVideoPreviewLayer tamanho: %.1fx%.1f",
                   frame.size.width, frame.size.height]);
        
        addDiagnosticData(@"previewLayerResize", @{
            @"width": @(frame.size.width),
            @"height": @(frame.size.height),
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"timestamp": [NSDate date].description
        });
    }
    
    %orig;
}

%end

// Monitoramento das configurações de buffer
%hook CMFormatDescription

+ (CMFormatDescriptionRef)formatDescriptionWithMediaType:(CMMediaType)mediaType
                                               mediaSubType:(FourCharCode)mediaSubType
                                                 extensions:(NSDictionary *)extensions {
    CMFormatDescriptionRef result = %orig;
    
    // Converter FourCC para string legível
    char mediaTypeStr[5] = {0};
    char mediaSubTypeStr[5] = {0};
    mediaTypeStr[0] = (mediaType >> 24) & 0xFF;
    mediaTypeStr[1] = (mediaType >> 16) & 0xFF;
    mediaTypeStr[2] = (mediaType >> 8) & 0xFF;
    mediaTypeStr[3] = mediaType & 0xFF;
    mediaSubTypeStr[0] = (mediaSubType >> 24) & 0xFF;
    mediaSubTypeStr[1] = (mediaSubType >> 16) & 0xFF;
    mediaSubTypeStr[2] = (mediaSubType >> 8) & 0xFF;
    mediaSubTypeStr[3] = mediaSubType & 0xFF;
    
    NSString *typeStr = [NSString stringWithCString:mediaTypeStr encoding:NSASCIIStringEncoding];
    NSString *subTypeStr = [NSString stringWithCString:mediaSubTypeStr encoding:NSASCIIStringEncoding];
    
    logToFile([NSString stringWithFormat:@"Formato criado: %@/%@", typeStr, subTypeStr]);
    
    addDiagnosticData(@"formatDescription", @{
        @"mediaType": typeStr,
        @"mediaSubType": subTypeStr,
        @"extensions": extensions ?: @{},
        @"timestamp": [NSDate date].description
    });
    
    return result;
}

%end

// Inicialização da extensão de diagnóstico
%ctor {
   @autoreleasepool {
       logToFile(@"DiagnosticExtension carregada - Análise avançada habilitada");
       
       // Registrar no diagnóstico
       addDiagnosticData(@"diagnosticExtension", @{
           @"loadTime": [NSDate date].description,
           @"appName": [[NSProcessInfo processInfo] processName],
           @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
           @"iosVersion": [[UIDevice currentDevice] systemVersion],
           @"deviceModel": [[UIDevice currentDevice] model]
       });
       
       // Observar notificações relevantes
       [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionWasInterruptedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
           NSNumber *reasonVal = note.userInfo[AVCaptureSessionInterruptionReasonKey];
           NSString *reasonStr = @"Desconhecido";
           
           if (reasonVal) {
               AVCaptureSessionInterruptionReason reason = [reasonVal integerValue];
               switch (reason) {
                   case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
                       reasonStr = @"Dispositivo de vídeo não disponível em background";
                       break;
                   case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
                       reasonStr = @"Dispositivo de áudio em uso por outro aplicativo";
                       break;
                   case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
                       reasonStr = @"Dispositivo de vídeo em uso por outro aplicativo";
                       break;
                   case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
                       reasonStr = @"Dispositivo de vídeo não disponível com múltiplos apps em foreground";
                       break;
               }
           }
           
           logToFile([NSString stringWithFormat:@"Sessão de captura interrompida: %@", reasonStr]);
           
           addDiagnosticData(@"sessionInterruption", @{
               @"reason": reasonStr,
               @"timestamp": [NSDate date].description
           });
       }];
       
       // Inicializar hooks
       %init;
   }
}
