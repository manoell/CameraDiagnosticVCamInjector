#import "DiagnosticTweak.h"

// Inicialização das variáveis globais
NSString *g_sessionId = nil;
NSString *g_appName = nil;
NSString *g_bundleId = nil;
CGSize g_cameraResolution = CGSizeZero;
CGSize g_frontCameraResolution = CGSizeZero;
CGSize g_backCameraResolution = CGSizeZero;
int g_videoOrientation = 0;
BOOL g_isCapturingPhoto = NO;
BOOL g_isRecordingVideo = NO;
BOOL g_usingFrontCamera = NO;
NSDictionary *g_lastPhotoMetadata = nil;
NSMutableDictionary *g_sessionInfo = nil;
NSMutableDictionary *g_appDiagnosticData = nil;

// Função para iniciar uma nova sessão de diagnóstico
void startNewDiagnosticSession(void) {
    // Gerar novo ID de sessão
    g_sessionId = [[NSUUID UUID] UUIDString];
    g_sessionInfo = [NSMutableDictionary dictionary];
    
    // Obter informações do processo atual
    g_appName = [NSProcessInfo processInfo].processName;
    g_bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    
    // Registrar informações básicas da sessão
    g_sessionInfo[@"sessionId"] = g_sessionId;
    g_sessionInfo[@"appName"] = g_appName;
    g_sessionInfo[@"bundleId"] = g_bundleId;
    g_sessionInfo[@"deviceModel"] = [[UIDevice currentDevice] model];
    g_sessionInfo[@"iosVersion"] = [[UIDevice currentDevice] systemVersion];
    g_sessionInfo[@"startTime"] = [NSDate date].description;
    
    logToFile([NSString stringWithFormat:@"Nova sessão de diagnóstico iniciada para %@ (%@)",
                g_appName, g_bundleId]);
}

// Função para registrar informações da sessão
void logSessionInfo(NSString *key, id value) {
    if (!key || !value) return;
    
    // Adicionar ao dicionário da sessão
    g_sessionInfo[key] = value;
    
    // Log para console
    logToFile([NSString stringWithFormat:@"Sessão %@: %@ = %@",
                g_sessionId, key, value]);
}

// Função para finalizar e salvar o diagnóstico
void finalizeDiagnosticSession(void) {
    // Adicionar resumo final
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    
    if (!CGSizeEqualToSize(g_frontCameraResolution, CGSizeZero)) {
        summary[@"frontCameraResolution"] = NSStringFromCGSize(g_frontCameraResolution);
    }
    
    if (!CGSizeEqualToSize(g_backCameraResolution, CGSizeZero)) {
        summary[@"backCameraResolution"] = NSStringFromCGSize(g_backCameraResolution);
    }
    
    if (g_videoOrientation > 0) {
        summary[@"lastVideoOrientation"] = @(g_videoOrientation);
        
        NSString *orientationString;
        switch (g_videoOrientation) {
            case 1: orientationString = @"Portrait"; break;
            case 2: orientationString = @"PortraitUpsideDown"; break;
            case 3: orientationString = @"LandscapeRight"; break;
            case 4: orientationString = @"LandscapeLeft"; break;
            default: orientationString = @"Unknown"; break;
        }
        summary[@"lastVideoOrientationString"] = orientationString;
    }
    
    // Combinar com informações de sessão existentes
    [g_sessionInfo addEntriesFromDictionary:summary];
    g_sessionInfo[@"endTime"] = [NSDate date].description;
    
    // Salvar o JSON final
    NSString *logDir = @"/var/tmp/CameraDiagnostic";
    NSString *filename = [NSString stringWithFormat:@"%@_%@_diagnostics.json", g_appName, g_bundleId];
    NSString *filePath = [logDir stringByAppendingPathComponent:filename];
    
    // Converter para JSON e salvar
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:g_sessionInfo
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    
    if (error) {
        logToFile([NSString stringWithFormat:@"Erro ao converter sessão para JSON: %@", error]);
    } else {
        [jsonData writeToFile:filePath options:NSDataWritingAtomic error:&error];
        if (error) {
            logToFile([NSString stringWithFormat:@"Erro ao salvar arquivo de sessão: %@", error]);
        } else {
            logToFile([NSString stringWithFormat:@"Sessão salva em: %@", filePath]);
        }
    }
    
    // Log para console
    logToFile(@"Sessão de diagnóstico finalizada");
}

// Log para arquivo de texto
void logToFile(NSString *message) {
    NSString *logDir = @"/var/tmp/CameraDiagnostic";
    NSString *logFile = [logDir stringByAppendingPathComponent:@"diagnostic.log"];
    
    // Criar diretório se não existir
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:logDir]) {
        [fileManager createDirectoryAtPath:logDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
    }
    
    // Adicionar timestamp e info do app
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *appInfo = [NSString stringWithFormat:@"%@ (%@)",
                         [NSProcessInfo processInfo].processName,
                         [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] [%@] %@\n", timestamp, appInfo, message];
    
    // Criar arquivo ou adicionar ao existente
    if (![fileManager fileExistsAtPath:logFile]) {
        [logMessage writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFile];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
    
    // Log para console também
    NSLog(@"[CameraDiagnostic] %@", message);
}

// Adicionar dados para o diagnóstico do aplicativo atual
void addDiagnosticData(NSString *eventType, NSDictionary *eventData) {
    @synchronized(g_appDiagnosticData) {
        if (!g_appDiagnosticData) {
            g_appDiagnosticData = [NSMutableDictionary dictionary];
        }
        
        NSString *appName = [NSProcessInfo processInfo].processName;
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        // Garantir que temos dados para este app
        if (!g_appDiagnosticData[bundleId]) {
            g_appDiagnosticData[bundleId] = [NSMutableDictionary dictionary];
            g_appDiagnosticData[bundleId][@"appName"] = appName;
            g_appDiagnosticData[bundleId][@"bundleId"] = bundleId;
            g_appDiagnosticData[bundleId][@"timestamp"] = [NSDate date].description;
            g_appDiagnosticData[bundleId][@"deviceModel"] = [[UIDevice currentDevice] model];
            g_appDiagnosticData[bundleId][@"iosVersion"] = [[UIDevice currentDevice] systemVersion];
            g_appDiagnosticData[bundleId][@"events"] = [NSMutableArray array];
        }
        
        // Adicionar evento com timestamp
        NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:eventData];
        event[@"eventType"] = eventType;
        event[@"timestamp"] = [NSDate date].description;
        
        // Adicionar à lista de eventos
        NSMutableArray *events = g_appDiagnosticData[bundleId][@"events"];
        [events addObject:event];
        
        // Salvar dados atualizados
        NSString *logDir = @"/var/tmp/CameraDiagnostic";
        
        // Criar diretório se não existir
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:logDir]) {
            [fileManager createDirectoryAtPath:logDir
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:nil];
        }
        
        // Salvar JSON
        for (NSString *bundleId in g_appDiagnosticData) {
            NSDictionary *appData = g_appDiagnosticData[bundleId];
            NSString *appName = appData[@"appName"];
            
            // Criar nome de arquivo com app
            NSString *filename = [NSString stringWithFormat:@"%@_%@_events.json", appName, bundleId];
            NSString *filePath = [logDir stringByAppendingPathComponent:filename];
            
            // Salvar como JSON
            NSError *error;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:appData
                                                               options:NSJSONWritingPrettyPrinted
                                                                 error:&error];
            if (jsonData) {
                [jsonData writeToFile:filePath atomically:YES];
            } else {
                logToFile([NSString stringWithFormat:@"Erro ao salvar diagnóstico: %@", error.localizedDescription]);
            }
        }
    }
}

// Inicialização do componente
%ctor {
    @autoreleasepool {
        // Criar diretório de logs
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *logDir = @"/var/tmp/CameraDiagnostic";
        if (![fileManager fileExistsAtPath:logDir]) {
            [fileManager createDirectoryAtPath:logDir
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:nil];
        }
        
        // Log de inicialização
        NSString *processName = [NSProcessInfo processInfo].processName;
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        logToFile([NSString stringWithFormat:@"CameraDiagnostic iniciado em: %@ (%@)", processName, bundleId]);
        
        // Inicializar diagnóstico
        startNewDiagnosticSession();
    }
}

// Finalização do componente
%dtor {
    // Salvar dados antes de descarregar
    logToFile(@"CameraDiagnostic sendo descarregado");
    finalizeDiagnosticSession();
}
