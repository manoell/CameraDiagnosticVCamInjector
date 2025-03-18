#import "DiagnosticTweak.h"
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
        logToFile([NSString stringWithFormat:@"Frame #%llu processando em classe %@",
                   frameCounter, NSStringFromClass([self class])]);
        
        // Extrair informações básicas do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            
            // Converter formato para string legível
            char formatStr[5] = {0};
            formatStr[0] = (pixelFormat >> 24) & 0xFF;
            formatStr[1] = (pixelFormat >> 16) & 0xFF;
            formatStr[2] = (pixelFormat >> 8) & 0xFF;
            formatStr[3] = pixelFormat & 0xFF;
            
            logToFile([NSString stringWithFormat:@"Buffer: %zux%zu, Formato: %s",
                       width, height, formatStr]);
            
            // Extrair e registrar informações detalhadas do buffer
            NSMutableDictionary *bufferInfo = [NSMutableDictionary dictionary];
            
            // Dimensões e formato
            bufferInfo[@"width"] = @(width);
            bufferInfo[@"height"] = @(height);
            bufferInfo[@"bytesPerRow"] = @(CVPixelBufferGetBytesPerRow(imageBuffer));
            bufferInfo[@"dataSize"] = @(CVPixelBufferGetDataSize(imageBuffer));
            bufferInfo[@"pixelFormat"] = @(pixelFormat);
            bufferInfo[@"pixelFormatString"] = [NSString stringWithCString:formatStr encoding:NSASCIIStringEncoding];
            
            // Conexão e orientação
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
                    logToFile([NSString stringWithFormat:@"Orientação: %@", orientationString]);
                }
                
                connectionInfo[@"videoMirrored"] = @(connection.isVideoMirrored);
                
                bufferInfo[@"connection"] = connectionInfo;
            }
            
            // Timing e timestamps
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            bufferInfo[@"presentationTimeSeconds"] = @(CMTimeGetSeconds(presentationTime));
            
            // Adicionar dados do buffer ao diagnóstico
            addDiagnosticData(@"frameAnalysis", bufferInfo);
        }
    }
    
    // Para frames específicos, registrar informações de ponto potencial de injeção
    if (frameCounter % 300 == 0) { // A cada ~10s em 30fps
        NSMutableDictionary *injectionInfo = [NSMutableDictionary dictionary];
        
        // Informações básicas
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
    
    %orig;
}

%end

// Diagnóstico da camada de captura de foto (usando AVCapturePhotoOutput para iOS 10+)
%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    logToFile(@"Captura de foto iniciada");
    
    // Análise das configurações
    NSMutableDictionary *photoInfo = [NSMutableDictionary dictionary];
    photoInfo[@"delegateClass"] = NSStringFromClass([delegate class]);
    photoInfo[@"flashEnabled"] = @(settings.flashMode != AVCaptureFlashModeOff);
    photoInfo[@"photoQualityPrioritization"] = @(settings.photoQualityPrioritization);
    
    if (@available(iOS 13.0, *)) {
        if (settings.photoQualityPrioritization != 0) {
            NSString *qualityString;
            switch (settings.photoQualityPrioritization) {
                case AVCapturePhotoQualityPrioritizationSpeed:
                    qualityString = @"Speed";
                    break;
                case AVCapturePhotoQualityPrioritizationBalanced:
                    qualityString = @"Balanced";
                    break;
                case AVCapturePhotoQualityPrioritizationQuality:
                    qualityString = @"Quality";
                    break;
                default:
                    qualityString = @"Unknown";
            }
            photoInfo[@"photoQualityPrioritizationString"] = qualityString;
            logToFile([NSString stringWithFormat:@"Prioridade de qualidade: %@", qualityString]);
        }
    }
    
    addDiagnosticData(@"photoCapture", photoInfo);
    
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

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    AVCaptureDevice *device = %orig;
    
    if (device && [mediaType isEqualToString:AVMediaTypeVideo]) {
        NSString *positionString = @"Unknown";
        switch (device.position) {
            case AVCaptureDevicePositionFront:
                positionString = @"Front";
                g_usingFrontCamera = YES;
                break;
            case AVCaptureDevicePositionBack:
                positionString = @"Back";
                g_usingFrontCamera = NO;
                break;
            case AVCaptureDevicePositionUnspecified:
                positionString = @"Unspecified";
                g_usingFrontCamera = NO;
                break;
        }
        
        logToFile([NSString stringWithFormat:@"Selecionado dispositivo padrão: %@ (%@)",
                   device.localizedName ?: @"unknown", positionString]);
    }
    
    return device;
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

// Diagnóstico de sessão
%hook AVCaptureSession

- (void)startRunning {
    logToFile(@"AVCaptureSession startRunning chamado");
    
    // Verificar inputs e outputs atuais
    NSMutableDictionary *sessionInfo = [NSMutableDictionary dictionary];
    sessionInfo[@"inputCount"] = @(self.inputs.count);
    sessionInfo[@"outputCount"] = @(self.outputs.count);
    sessionInfo[@"preset"] = self.sessionPreset ?: @"default";
    
    NSMutableArray *inputTypes = [NSMutableArray array];
    for (AVCaptureInput *input in self.inputs) {
        [inputTypes addObject:NSStringFromClass([input class])];
    }
    sessionInfo[@"inputTypes"] = inputTypes;
    
    NSMutableArray *outputTypes = [NSMutableArray array];
    for (AVCaptureOutput *output in self.outputs) {
        [outputTypes addObject:NSStringFromClass([output class])];
    }
    sessionInfo[@"outputTypes"] = outputTypes;
    
    addDiagnosticData(@"sessionStarted", sessionInfo);
    
    %orig;
}

- (void)stopRunning {
    logToFile(@"AVCaptureSession stopRunning chamado");
    addDiagnosticData(@"sessionStopped", @{@"timestamp": [NSDate date].description});
    
    %orig;
}

- (void)addInput:(AVCaptureInput *)input {
    NSString *inputClass = NSStringFromClass([input class]);
    
    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
        AVCaptureDevice *device = deviceInput.device;
        NSString *deviceName = device.localizedName ?: @"unknown";
        
        logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando input: %@ (dispositivo: %@)",
                   inputClass, deviceName]);
        
        // Atualizar variáveis globais para diagnóstico
        if (device.position == AVCaptureDevicePositionFront) {
            g_usingFrontCamera = YES;
        } else if (device.position == AVCaptureDevicePositionBack) {
            g_usingFrontCamera = NO;
        }
    } else {
        logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando input: %@", inputClass]);
    }
    
    %orig;
}

- (void)addOutput:(AVCaptureOutput *)output {
    NSString *outputClass = NSStringFromClass([output class]);
    logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando output: %@", outputClass]);
    
    %orig;
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
