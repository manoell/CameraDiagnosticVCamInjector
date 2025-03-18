#import "DiagnosticTweak.h"
#import "VCamInjector.h"
#import <objc/runtime.h>

// Diagnóstico do ponto-chave: delegate de AVCaptureVideoDataOutput
%hook NSObject

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se somos o delegate correto
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    // Estatísticas de frames
    static uint64_t frameCounter = 0;
    frameCounter++;
    
    // Para cada frame, vamos registrar informações detalhadas periodicamente
    if (frameCounter % 30 == 0) { // A cada 30 frames (aproximadamente 1 segundo a 30fps)
        // Capturar informações sobre o delegado
        NSMutableDictionary *delegateInfo = [NSMutableDictionary dictionary];
        delegateInfo[@"class"] = NSStringFromClass([self class]);
        delegateInfo[@"frameCount"] = @(frameCounter);
        delegateInfo[@"appName"] = [[NSProcessInfo processInfo] processName];
        delegateInfo[@"bundleId"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        // Analisar a hierarquia de classes para identificar estrutura do app
        NSMutableArray *classHierarchy = [NSMutableArray array];
        Class currentClass = [self class];
        while (currentClass) {
            [classHierarchy addObject:NSStringFromClass(currentClass)];
            currentClass = class_getSuperclass(currentClass);
        }
        delegateInfo[@"classHierarchy"] = classHierarchy;
        
        // Analisar buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer) {
            NSMutableDictionary *bufferInfo = [NSMutableDictionary dictionary];
            
            // Dimensões e formato
            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
            
            bufferInfo[@"width"] = @(width);
            bufferInfo[@"height"] = @(height);
            bufferInfo[@"bytesPerRow"] = @(bytesPerRow);
            bufferInfo[@"pixelFormat"] = @(pixelFormat);
            
            // Formato como string legível
            char formatStr[5] = {0};
            formatStr[0] = (pixelFormat >> 24) & 0xFF;
            formatStr[1] = (pixelFormat >> 16) & 0xFF;
            formatStr[2] = (pixelFormat >> 8) & 0xFF;
            formatStr[3] = pixelFormat & 0xFF;
            bufferInfo[@"pixelFormatString"] = [NSString stringWithCString:formatStr encoding:NSASCIIStringEncoding];
            
            // Informações de timing
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
            
            bufferInfo[@"presentationTimeSeconds"] = @(CMTimeGetSeconds(presentationTime));
            bufferInfo[@"durationSeconds"] = @(CMTimeGetSeconds(duration));
            
            // Verificar metadados do buffer
            bufferInfo[@"hasAttachments"] = @NO;
            
            // Verificar attachments de forma segura
            CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
            if (attachmentsArray != NULL && CFArrayGetCount(attachmentsArray) > 0) {
                CFDictionaryRef attachmentDict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
                if (attachmentDict != NULL) {
                    bufferInfo[@"hasAttachments"] = @YES;
                    
                    // Contar o número de chaves
                    CFIndex count = CFDictionaryGetCount(attachmentDict);
                    bufferInfo[@"attachmentKeyCount"] = @(count);
                    
                    // Verificar algumas chaves conhecidas
                    if (CFDictionaryContainsKey(attachmentDict, kCMSampleAttachmentKey_DisplayImmediately)) {
                        bufferInfo[@"hasDisplayImmediately"] = @YES;
                    }
                    
                    if (CFDictionaryContainsKey(attachmentDict, kCMSampleAttachmentKey_NotSync)) {
                        bufferInfo[@"hasNotSync"] = @YES;
                    }
                }
            }
            
            delegateInfo[@"bufferInfo"] = bufferInfo;
            
            // Informações da conexão
            if (connection) {
                NSMutableDictionary *connectionInfo = [NSMutableDictionary dictionary];
                connectionInfo[@"videoOrientation"] = @(connection.videoOrientation);
                connectionInfo[@"videoMirrored"] = @(connection.isVideoMirrored);
                
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
                
                // Informações sobre estabilização
                if ([connection isVideoStabilizationSupported]) {
                    connectionInfo[@"stabilizationSupported"] = @YES;
                    connectionInfo[@"activeStabilizationMode"] = @(connection.activeVideoStabilizationMode);
                }
                
                delegateInfo[@"connectionInfo"] = connectionInfo;
            }
            
            // Informações sobre o output
            if (output) {
                NSMutableDictionary *outputInfo = [NSMutableDictionary dictionary];
                outputInfo[@"class"] = NSStringFromClass([output class]);
                
                if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                    AVCaptureVideoDataOutput *videoOutput = (AVCaptureVideoDataOutput *)output;
                    outputInfo[@"alwaysDiscardsLateVideoFrames"] = @(videoOutput.alwaysDiscardsLateVideoFrames);
                    outputInfo[@"videoSettings"] = videoOutput.videoSettings ?: @{};
                }
                
                delegateInfo[@"outputInfo"] = outputInfo;
            }
            
            // Log detalhado para análise
            logToFile([NSString stringWithFormat:@"Frame #%llu: %zux%zu %s em %@ (%@)",
                      frameCounter, width, height, formatStr,
                      NSStringFromClass([self class]),
                      [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"]);
            
            // Registrar informações para análise posterior
            addDiagnosticData(@"frameDiagnostic", delegateInfo);
        }
    }
    
    // Analise mais profunda a cada 300 frames
    if (frameCounter % 300 == 0) {
        // Examinar a sessão relacionada ao output
        if ([output respondsToSelector:@selector(session)]) {
            AVCaptureSession *session = [output performSelector:@selector(session)];
            if (session) {
                NSMutableDictionary *sessionInfo = [NSMutableDictionary dictionary];
                sessionInfo[@"isRunning"] = @(session.isRunning);
                sessionInfo[@"sessionPreset"] = session.sessionPreset ?: @"unknown";
                
                // Inputs e outputs
                NSMutableArray *inputsInfo = [NSMutableArray array];
                for (AVCaptureInput *input in session.inputs) {
                    NSMutableDictionary *inputDict = [NSMutableDictionary dictionary];
                    inputDict[@"class"] = NSStringFromClass([input class]);
                    
                    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
                        AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
                        AVCaptureDevice *device = deviceInput.device;
                        
                        inputDict[@"deviceName"] = device.localizedName ?: @"unknown";
                        inputDict[@"position"] = @(device.position);
                        inputDict[@"hasMediaType"] = [device hasMediaType:AVMediaTypeVideo] ? @"video" : @"other";
                    }
                    
                    [inputsInfo addObject:inputDict];
                }
                sessionInfo[@"inputs"] = inputsInfo;
                
                NSMutableArray *outputsInfo = [NSMutableArray array];
                for (AVCaptureOutput *sessionOutput in session.outputs) {
                    [outputsInfo addObject:NSStringFromClass([sessionOutput class])];
                }
                sessionInfo[@"outputs"] = outputsInfo;
                
                addDiagnosticData(@"sessionAnalysis", sessionInfo);
                
                logToFile([NSString stringWithFormat:@"Sessão analisada: %@ com %lu inputs e %lu outputs",
                          session.sessionPreset ?: @"unknown",
                          (unsigned long)session.inputs.count,
                          (unsigned long)session.outputs.count]);
            }
        }
    }
    
    // Continuar com o processamento normal
    %orig;
}

%end

// Monitor de configuração de AVCaptureVideoDataOutput
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    NSLog(@"[VCamHook] AVCaptureVideoDataOutput configurando delegate: %@ na fila: %@",
          NSStringFromClass([sampleBufferDelegate class]),
          sampleBufferCallbackQueue ? @"custom" : @"nil");
    
    // Registrar informações sobre o delegate
    NSMutableDictionary *delegateInfo = [NSMutableDictionary dictionary];
    delegateInfo[@"delegateClass"] = NSStringFromClass([sampleBufferDelegate class]) ?: @"<nil>";
    delegateInfo[@"hasQueue"] = sampleBufferCallbackQueue ? @YES : @NO;
    
    // Verificar métodos implementados
    if (sampleBufferDelegate) {
        NSMutableDictionary *methods = [NSMutableDictionary dictionary];
        methods[@"captureOutput:didOutputSampleBuffer:fromConnection:"] =
            @([sampleBufferDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]);
        methods[@"captureOutput:didDropSampleBuffer:fromConnection:"] =
            @([sampleBufferDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]);
        
        delegateInfo[@"implementedMethods"] = methods;
        
        // Verificar a hierarquia de classes
        NSMutableArray *classHierarchy = [NSMutableArray array];
        Class currentClass = [sampleBufferDelegate class];
        while (currentClass) {
            [classHierarchy addObject:NSStringFromClass(currentClass)];
            currentClass = class_getSuperclass(currentClass);
        }
        delegateInfo[@"classHierarchy"] = classHierarchy;
    }
    
    // Analisar os videoSettings configurados
    delegateInfo[@"videoSettings"] = self.videoSettings ?: @{};
    
    // Registrar para análise posterior
    addDiagnosticData(@"videoDataOutputDelegate", delegateInfo);
    
    // Log detalhado
    logToFile([NSString stringWithFormat:@"Delegate configurado: %@ em %@",
              NSStringFromClass([sampleBufferDelegate class]) ?: @"<nil>",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"]);
    
    %orig;
}

- (void)setVideoSettings:(NSDictionary<NSString *,id> *)videoSettings {
    NSLog(@"[VCamHook] AVCaptureVideoDataOutput definindo videoSettings: %@", videoSettings);
    
    // Analisar configurações de formato
    if (videoSettings[(id)kCVPixelBufferPixelFormatTypeKey]) {
        NSNumber *formatType = videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
        OSType pixelFormat = [formatType unsignedIntValue];
        
        char formatStr[5] = {0};
        formatStr[0] = (pixelFormat >> 24) & 0xFF;
        formatStr[1] = (pixelFormat >> 16) & 0xFF;
        formatStr[2] = (pixelFormat >> 8) & 0xFF;
        formatStr[3] = pixelFormat & 0xFF;
        
        logToFile([NSString stringWithFormat:@"Formato de pixel configurado: %s (0x%08X)",
                  formatStr, pixelFormat]);
    }
    
    %orig;
}

%end

// Monitor para AVCaptureSession
%hook AVCaptureSession

- (void)startRunning {
    logToFile(@"AVCaptureSession startRunning chamado");
    
    // Analisar a configuração da sessão antes de iniciar
    NSMutableDictionary *sessionInfo = [NSMutableDictionary dictionary];
    sessionInfo[@"sessionPreset"] = self.sessionPreset ?: @"unknown";
    sessionInfo[@"inputCount"] = @(self.inputs.count);
    sessionInfo[@"outputCount"] = @(self.outputs.count);
    
    // Detalhes dos inputs
    NSMutableArray *inputTypes = [NSMutableArray array];
    for (AVCaptureInput *input in self.inputs) {
        NSString *inputInfo = NSStringFromClass([input class]);
        
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
            AVCaptureDevice *device = deviceInput.device;
            inputInfo = [NSString stringWithFormat:@"%@ (%@)",
                        NSStringFromClass([input class]),
                        device.localizedName ?: @"unknown"];
        }
        
        [inputTypes addObject:inputInfo];
    }
    sessionInfo[@"inputTypes"] = inputTypes;
    
    // Detalhes dos outputs
    NSMutableArray *outputTypes = [NSMutableArray array];
    for (AVCaptureOutput *output in self.outputs) {
        [outputTypes addObject:NSStringFromClass([output class])];
    }
    sessionInfo[@"outputTypes"] = outputTypes;
    
    // Registrar para análise posterior
    addDiagnosticData(@"sessionStarted", sessionInfo);
    
    %orig;
}

- (void)addInput:(AVCaptureInput *)input {
    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
        AVCaptureDevice *device = deviceInput.device;
        
        logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando input: %@ (dispositivo: %@)",
                  NSStringFromClass([input class]),
                  device.localizedName ?: @"unknown"]);
        
        // Analisar características do dispositivo
        NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionary];
        deviceInfo[@"deviceName"] = device.localizedName ?: @"unknown";
        deviceInfo[@"uniqueID"] = device.uniqueID ?: @"unknown";
        deviceInfo[@"modelID"] = device.modelID ?: @"unknown";
        deviceInfo[@"position"] = @(device.position);
        
        // Posição como string
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
                break;
        }
        deviceInfo[@"positionString"] = positionString;
        
        // Formato ativo
        AVCaptureDeviceFormat *activeFormat = device.activeFormat;
        if (activeFormat) {
            CMFormatDescriptionRef formatDescription = activeFormat.formatDescription;
            if (formatDescription) {
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                deviceInfo[@"formatWidth"] = @(dimensions.width);
                deviceInfo[@"formatHeight"] = @(dimensions.height);
                
                // Formato como string
                FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription);
                char subTypeStr[5] = {0};
                subTypeStr[0] = (mediaSubType >> 24) & 0xFF;
                subTypeStr[1] = (mediaSubType >> 16) & 0xFF;
                subTypeStr[2] = (mediaSubType >> 8) & 0xFF;
                subTypeStr[3] = mediaSubType & 0xFF;
                deviceInfo[@"formatFourCC"] = [NSString stringWithCString:subTypeStr encoding:NSASCIIStringEncoding];
            }
            
            // Capturar ranges de framerate
            NSMutableArray *frameRates = [NSMutableArray array];
            for (AVFrameRateRange *range in activeFormat.videoSupportedFrameRateRanges) {
                [frameRates addObject:@{
                    @"minFrameRate": @(range.minFrameRate),
                    @"maxFrameRate": @(range.maxFrameRate)
                }];
            }
            deviceInfo[@"frameRates"] = frameRates;
        }
        
        // Registrar para análise posterior
        addDiagnosticData(@"deviceInput", deviceInfo);
    } else {
        logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando input: %@",
                  NSStringFromClass([input class])]);
    }
    
    %orig;
}

- (void)addOutput:(AVCaptureOutput *)output {
    logToFile([NSString stringWithFormat:@"AVCaptureSession adicionando output: %@",
              NSStringFromClass([output class])]);
    
    // Análise específica baseada no tipo de output
    NSMutableDictionary *outputInfo = [NSMutableDictionary dictionary];
    outputInfo[@"class"] = NSStringFromClass([output class]);
    
    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        AVCaptureVideoDataOutput *videoOutput = (AVCaptureVideoDataOutput *)output;
        outputInfo[@"videoSettings"] = videoOutput.videoSettings ?: @{};
        outputInfo[@"alwaysDiscardsLateVideoFrames"] = @(videoOutput.alwaysDiscardsLateVideoFrames);
    }
    else if ([output isKindOfClass:[AVCapturePhotoOutput class]]) {
        AVCapturePhotoOutput *photoOutput = (AVCapturePhotoOutput *)output;
        outputInfo[@"isHighResolutionCaptureEnabled"] = @(photoOutput.isHighResolutionCaptureEnabled);
        outputInfo[@"isLivePhotoCaptureEnabled"] = @(photoOutput.isLivePhotoCaptureEnabled);
    }
    
    // Registrar para análise posterior
    addDiagnosticData(@"sessionOutput", outputInfo);
    
    %orig;
}

%end

// Inicialização do tweak para diagnóstico
%ctor {
    @autoreleasepool {
        NSLog(@"[VCamHook] Inicializando diagnóstico avançado do pipeline da câmera");
        logToFile(@"Diagnóstico avançado iniciado com base na documentação do AVFoundation");
        
        // Registrar informações de ambiente
        NSMutableDictionary *environmentInfo = [NSMutableDictionary dictionary];
        environmentInfo[@"appName"] = [[NSProcessInfo processInfo] processName];
        environmentInfo[@"bundleId"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        environmentInfo[@"iosVersion"] = [[UIDevice currentDevice] systemVersion];
        environmentInfo[@"deviceModel"] = [[UIDevice currentDevice] model];
        environmentInfo[@"timeStamp"] = [NSDate date].description;
        
        addDiagnosticData(@"environmentInfo", environmentInfo);
        
        // Inicializar hooks
        %init;
    }
}
