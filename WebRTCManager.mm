#import "WebRTCManager.h"
#import <Accelerate/Accelerate.h>

// Configuração de logs
#define WEBRTC_DEBUG 1
#define RTCLog(fmt, ...) if (WEBRTC_DEBUG) NSLog(@"[WebRTCManager] " fmt, ##__VA_ARGS__)

// Constantes
static NSString * const kDefaultSTUNServer = @"stun:stun.l.google.com:19302";
static NSString * const kDefaultSignalingURL = @"wss://signaling.example.com";

// Presets de qualidade
static NSDictionary *kQualityPresets = nil;

@interface WebRTCManager () <RTCDataChannelDelegate, RTCSdpObserver>

// Propriedades WebRTC
@property (nonatomic, strong) RTCPeerConnectionFactory *peerConnectionFactory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCDataChannel *dataChannel;
@property (nonatomic, strong) RTCVideoTrack *remoteVideoTrack;
@property (nonatomic, strong) NSMutableArray<RTCVideoRenderer *> *videoRenderers;

// Socket para comunicação de sinalização
@property (nonatomic, strong) SRWebSocket *signalingSocket;

// Estado interno
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) BOOL connecting;
@property (nonatomic, assign) NSDate *connectionStartTime;
@property (nonatomic, assign) uint64_t receivedFrameCount;
@property (nonatomic, assign) float currentFPS;
@property (nonatomic, assign) CGSize currentResolution;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;

// Propriedades de frame
@property (nonatomic, strong) RTCVideoFrame *lastFrame;
@property (nonatomic, strong) dispatch_queue_t frameProcessingQueue;
@property (nonatomic, strong) NSLock *frameLock;
@property (nonatomic, strong) NSMutableDictionary *frameCache;

// Timestamp tracking
@property (nonatomic, assign) NSTimeInterval lastFPSCalculationTime;
@property (nonatomic, assign) uint32_t framesSinceLastFPSCalculation;

@end

@implementation WebRTCManager

#pragma mark - Inicialização e Singleton

+ (void)initialize {
    if (self == [WebRTCManager class]) {
        // Inicializar presets de qualidade
        kQualityPresets = @{
            @"low": @{
                @"width": @320,
                @"height": @240,
                @"fps": @15,
                @"bitrate": @250000
            },
            @"medium": @{
                @"width": @640,
                @"height": @480,
                @"fps": @25,
                @"bitrate": @500000
            },
            @"high": @{
                @"width": @1280,
                @"height": @720,
                @"fps": @30,
                @"bitrate": @1500000
            },
            @"max": @{
                @"width": @1920,
                @"height": @1080,
                @"fps": @30,
                @"bitrate": @2500000
            }
        };
    }
}

+ (instancetype)sharedInstance {
    static WebRTCManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        // Inicializar WebRTC
        [RTCInitializeSSL];
        [RTCLogging setMinimumLogSeverity:RTCLoggingSeverityWarning];
        
        // Inicializar propriedades
        _videoRenderers = [NSMutableArray array];
        _frameProcessingQueue = dispatch_queue_create("com.vcam.webrtc.frame", DISPATCH_QUEUE_SERIAL);
        _frameLock = [[NSLock alloc] init];
        _frameCache = [NSMutableDictionary dictionary];
        
        // Valores padrão
        _serverURL = kDefaultSignalingURL;
        _automaticQualityControl = YES;
        _preferredResolution = CGSizeMake(1280, 720);
        _preferredFrameRate = 30.0;
        
        // Status inicial
        _connected = NO;
        _connecting = NO;
        _receivedFrameCount = 0;
        _currentFPS = 0.0;
        _currentResolution = CGSizeZero;
        _lastFrameTime = 0;
        
        // Inicializar fábrica de conexões WebRTC
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        _peerConnectionFactory = [[RTCPeerConnectionFactory alloc] 
                                 initWithEncoderFactory:encoderFactory 
                                         decoderFactory:decoderFactory];
        
        RTCLog(@"WebRTCManager inicializado");
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    [RTCCleanupSSL];
}

#pragma mark - Métodos Públicos de Conexão

- (void)connectWithConfiguration:(NSDictionary *)config {
    if (self.connected || self.connecting) {
        RTCLog(@"Já conectado ou tentando conectar. Desconecte primeiro.");
        return;
    }
    
    // Aplicar configuração
    if (config[@"serverURL"]) {
        self.serverURL = config[@"serverURL"];
    }
    
    if (config[@"roomID"]) {
        self.roomID = config[@"roomID"];
    }
    
    if (config[@"automaticQualityControl"] != nil) {
        self.automaticQualityControl = [config[@"automaticQualityControl"] boolValue];
    }
    
    if (config[@"preferredWidth"] && config[@"preferredHeight"]) {
        CGFloat width = [config[@"preferredWidth"] floatValue];
        CGFloat height = [config[@"preferredHeight"] floatValue];
        if (width > 0 && height > 0) {
            self.preferredResolution = CGSizeMake(width, height);
        }
    }
    
    if (config[@"preferredFrameRate"]) {
        float fps = [config[@"preferredFrameRate"] floatValue];
        if (fps > 0) {
            self.preferredFrameRate = fps;
        }
    }
    
    // Iniciar conexão
    self.connecting = YES;
    
    // Criar conexão com servidor de sinalização
    [self connectToSignalingServer];
    
    RTCLog(@"Iniciando conexão ao servidor: %@, sala: %@", self.serverURL, self.roomID);
}

- (void)disconnect {
    RTCLog(@"Desconectando...");
    
    // Fechar socket de sinalização
    [self.signalingSocket close];
    self.signalingSocket = nil;
    
    // Liberar conexão WebRTC
    [self.peerConnection close];
    self.peerConnection = nil;
    self.dataChannel = nil;
    self.remoteVideoTrack = nil;
    
    // Limpar renderizadores
    [self.videoRenderers removeAllObjects];
    
    // Atualizar estado
    self.connected = NO;
    self.connecting = NO;
    self.connectionStartTime = nil;
}

- (void)reconnect {
    [self disconnect];
    
    // Pequeno delay antes de reconectar
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self connectWithConfiguration:@{
            @"serverURL": self.serverURL ?: kDefaultSignalingURL,
            @"roomID": self.roomID ?: @"default"
        }];
    });
}

#pragma mark - Controle do Stream

- (void)pauseStream {
    // Pausar recebimento de mídia
    [self.remoteVideoTrack setIsEnabled:NO];
    RTCLog(@"Stream pausado");
}

- (void)resumeStream {
    // Retomar recebimento de mídia
    [self.remoteVideoTrack setIsEnabled:YES];
    RTCLog(@"Stream retomado");
}

- (void)setQualityPreset:(NSString *)preset {
    NSDictionary *presetConfig = kQualityPresets[preset];
    if (!presetConfig) {
        RTCLog(@"Preset de qualidade desconhecido: %@", preset);
        return;
    }
    
    // Aplicar configurações de qualidade
    self.preferredResolution = CGSizeMake([presetConfig[@"width"] floatValue], 
                                          [presetConfig[@"height"] floatValue]);
    self.preferredFrameRate = [presetConfig[@"fps"] floatValue];
    
    // Se estiver conectado, enviar configuração para peer
    if (self.connected && self.dataChannel.readyState == RTCDataChannelStateOpen) {
        NSDictionary *qualityMessage = @{
            @"type": @"quality",
            @"width": presetConfig[@"width"],
            @"height": presetConfig[@"height"],
            @"fps": presetConfig[@"fps"],
            @"bitrate": presetConfig[@"bitrate"]
        };
        
        NSData *data = [NSJSONSerialization dataWithJSONObject:qualityMessage
                                                       options:0
                                                         error:nil];
        
        if (data) {
            RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:data isBinary:NO];
            [self.dataChannel sendData:buffer];
        }
    }
    
    RTCLog(@"Preset de qualidade definido para: %@", preset);
}

#pragma mark - Acesso a Frames e Conversão

- (RTCVideoFrame *)lastReceivedFrame {
    [self.frameLock lock];
    RTCVideoFrame *frame = self.lastFrame;
    [self.frameLock unlock];
    
    return frame;
}

- (CVPixelBufferRef)lastReceivedPixelBuffer {
    RTCVideoFrame *frame = [self lastReceivedFrame];
    if (!frame) {
        return NULL;
    }
    
    return [self convertRTCFrameToPixelBuffer:frame];
}

- (CVPixelBufferRef)convertRTCFrameToPixelBuffer:(RTCVideoFrame *)frame {
    if (!frame) {
        return NULL;
    }
    
    // Verificar cache
    NSString *cacheKey = [NSString stringWithFormat:@"%lld", frame.timeStampNs];
    CVPixelBufferRef cachedBuffer = (__bridge CVPixelBufferRef)[self.frameCache objectForKey:cacheKey];
    
    if (cachedBuffer) {
        CVPixelBufferRetain(cachedBuffer);
        return cachedBuffer;
    }
    
    // Converter frame para pixel buffer
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        // Já é um CVPixelBuffer
        RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
        CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
        
        // Não precisamos converter, apenas criar uma cópia se necessário
        // ou simplesmente reter e retornar
        CVPixelBufferRetain(pixelBuffer);
        
        // Adicionar ao cache
        [self.frameCache setObject:(__bridge id)pixelBuffer forKey:cacheKey];
        
        return pixelBuffer;
    }
    else if ([frame.buffer isKindOfClass:[RTCI420Buffer class]]) {
        // Converter de I420 para pixel buffer BGRA
        RTCI420Buffer *i420Buffer = (RTCI420Buffer *)frame.buffer;
        
        // Criar pixel buffer de destino
        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *pixelAttributes = @{
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        
        CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                              i420Buffer.width,
                                              i420Buffer.height,
                                              kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)pixelAttributes,
                                              &pixelBuffer);
        
        if (result != kCVReturnSuccess) {
            RTCLog(@"Erro ao criar pixel buffer: %d", result);
            return NULL;
        }
        
        // Bloquear o buffer para escrita
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        
        // Acessar os planos YUV do buffer I420
        const uint8_t *yPlane = i420Buffer.dataY;
        const uint8_t *uPlane = i420Buffer.dataU;
        const uint8_t *vPlane = i420Buffer.dataV;
        
        int yStride = i420Buffer.strideY;
        int uStride = i420Buffer.strideU;
        int vStride = i420Buffer.strideV;
        
        int width = i420Buffer.width;
        int height = i420Buffer.height;
        
        // Obter o endereço do buffer de destino BGRA
        uint8_t *bgra = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bgraStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
        // Conversão YUV para BGRA usando Accelerate framework
        vImage_Buffer srcY = {
            .data = (void *)yPlane,
            .width = width,
            .height = height,
            .rowBytes = yStride
        };
        
        vImage_Buffer srcU = {
            .data = (void *)uPlane,
            .width = width / 2,
            .height = height / 2,
            .rowBytes = uStride
        };
        
        vImage_Buffer srcV = {
            .data = (void *)vPlane,
            .width = width / 2,
            .height = height / 2,
            .rowBytes = vStride
        };
        
        vImage_Buffer dest = {
            .data = bgra,
            .width = width,
            .height = height,
            .rowBytes = bgraStride
        };
        
        // Conversão YUV para RGB usando vImage
        vImage_YpCbCrToARGB info;
        vImage_YpCbCrPixelRange pixelRange = { 0, 128, 255, 255, 255, 1, 255, 0 };
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
                                                     &pixelRange,
                                                     &info,
                                                     kvImage_YpCbCrToARGB,
                                                     kvImageNoFlags);
        
        // Aplicar conversão
        vImage_Error error = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY,
                                                                  &srcU,
                                                                  &srcV,
                                                                  &dest,
                                                                  &info,
                                                                  NULL,
                                                                  255,
                                                                  kvImageNoFlags);
        
        // Desbloquear o buffer
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        if (error != kvImageNoError) {
            RTCLog(@"Erro na conversão YUV para BGRA: %ld", error);
            CVPixelBufferRelease(pixelBuffer);
            return NULL;
        }
        
        // Adicionar ao cache
        [self.frameCache setObject:(__bridge id)pixelBuffer forKey:cacheKey];
        
        return pixelBuffer;
    }
    
    RTCLog(@"Tipo de buffer não suportado para conversão");
    return NULL;
}

#pragma mark - Estatísticas e Diagnóstico

- (NSDictionary *)currentStatistics {
    return @{
        @"connected": @(self.connected),
        @"connecting": @(self.connecting),
        @"connectionDuration": @(self.connectionDuration),
        @"receivedFrameCount": @(self.receivedFrameCount),
        @"currentFPS": @(self.currentFPS),
        @"resolution": NSStringFromCGSize(self.currentResolution),
        @"lastFrameTime": @(self.lastFrameTime),
        @"peerConnectionState": @(self.peerConnection.connectionState),
        @"signalingState": @(self.peerConnection.signalingState)
    };
}

- (void)logDiagnosticInfo {
    RTCLog(@"=== WebRTC Status ===");
    RTCLog(@"Conectado: %@", self.connected ? @"Sim" : @"Não");
    RTCLog(@"Duração da conexão: %.2f segundos", self.connectionDuration);
    RTCLog(@"Frames recebidos: %llu", self.receivedFrameCount);
    RTCLog(@"FPS atual: %.1f", self.currentFPS);
    RTCLog(@"Resolução: %@", NSStringFromCGSize(self.currentResolution));
    RTCLog(@"===================");
}

#pragma mark - Propriedades Calculadas

- (NSTimeInterval)connectionDuration {
    if (!self.connectionStartTime || !self.connected) {
        return 0;
    }
    
    return [[NSDate date] timeIntervalSinceDate:self.connectionStartTime];
}

#pragma mark - Métodos Internos de Conexão

- (void)connectToSignalingServer {
    // Criar socket para signaling
    NSURL *signalingURL = [NSURL URLWithString:self.serverURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:signalingURL];
    
    // Adicionar parâmetros como roomID
    if (self.roomID) {
        request.URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@?roomId=%@", 
                                           self.serverURL, self.roomID]];
    }
    
    self.signalingSocket = [[SRWebSocket alloc] initWithURLRequest:request];
    self.signalingSocket.delegate = (id<SRWebSocketDelegate>)self;
    
    [self.signalingSocket open];
    
    RTCLog(@"Conectando ao servidor de sinalização: %@", self.serverURL);
}

- (void)createPeerConnection {
    // Configurar ICE servers (STUN/TURN)
    RTCIceServer *defaultStunServer = [[RTCIceServer alloc] initWithURLStrings:@[kDefaultSTUNServer]];
    NSArray<RTCIceServer *> *iceServers = @[defaultStunServer];
    
    // Criar configuração
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = iceServers;
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    
    // Configurações de mídia
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] 
                                       initWithMandatoryConstraints:nil
                                        optionalConstraints:nil];
    
    // Criar peer connection
    self.peerConnection = [self.peerConnectionFactory peerConnectionWithConfiguration:config
                                                                        constraints:constraints
                                                                           delegate:self];
    
    // Criar canal de dados para controle
    RTCDataChannelConfiguration *dataConfig = [[RTCDataChannelConfiguration alloc] init];
    dataConfig.isOrdered = YES;
    self.dataChannel = [self.peerConnection dataChannelForLabel:@"control" 
                                                 configuration:dataConfig];
    self.dataChannel.delegate = self;
    
    RTCLog(@"Conexão peer criada");
}

- (void)createOfferAndSend {
    if (!self.peerConnection) {
        [self createPeerConnection];
    }
    
    // Criar uma oferta SDP
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] 
                                       initWithMandatoryConstraints:@{
                                           @"OfferToReceiveAudio": @"true",
                                           @"OfferToReceiveVideo": @"true"
                                       }
                                        optionalConstraints:nil];
    
    __weak WebRTCManager *weakSelf = self;
    [self.peerConnection offerForConstraints:constraints 
                         completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        if (error) {
            RTCLog(@"Erro ao criar oferta: %@", error);
            return;
        }
        
        [weakSelf.peerConnection setLocalDescription:sdp 
                                  completionHandler:^(NSError * _Nullable error) {
            if (error) {
                RTCLog(@"Erro ao definir descrição local: %@", error);
                return;
            }
            
            // Enviar oferta para o servidor de sinalização
            NSDictionary *offerDict = @{
                @"type": @"offer",
                @"sdp": sdp.sdp,
                @"roomId": weakSelf.roomID ?: @"default"
            };
            
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:offerDict
                                                               options:0
                                                                 error:nil];
            
            NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            [weakSelf.signalingSocket send:jsonString];
            
            RTCLog(@"Oferta SDP enviada");
        }];
    }];
}

- (void)processSignalingMessage:(id)message {
    if (![message isKindOfClass:[NSDictionary class]]) {
        RTCLog(@"Mensagem de sinalização inválida");
        return;
    }
    
    NSDictionary *messageDict = (NSDictionary *)message;
    NSString *type = messageDict[@"type"];
    
    if ([type isEqualToString:@"offer"]) {
        // Recebemos uma oferta (raro neste caso, já que somos o iniciador)
        NSString *sdpString = messageDict[@"sdp"];
        RTCSessionDescription *remoteSdp = [[RTCSessionDescription alloc] 
                                           initWithType:RTCSdpTypeOffer
                                                   sdp:sdpString];
        
        [self.peerConnection setRemoteDescription:remoteSdp 
                                completionHandler:^(NSError * _Nullable error) {
            if (error) {
                RTCLog(@"Erro ao definir descrição remota (oferta): %@", error);
                return;
            }
            
            // Criar resposta
            RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] 
                                               initWithMandatoryConstraints:nil
                                                      optionalConstraints:nil];
            
            [self.peerConnection answerForConstraints:constraints 
                                   completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
                if (error) {
                    RTCLog(@"Erro ao criar resposta: %@", error);
                    return;
                }
                
                [self.peerConnection setLocalDescription:sdp 
                                      completionHandler:^(NSError * _Nullable error) {
                    if (error) {
                        RTCLog(@"Erro ao definir descrição local (resposta): %@", error);
                        return;
                    }
                    
                    // Enviar resposta
                    NSDictionary *answerDict = @{
                        @"type": @"answer",
                        @"sdp": sdp.sdp,
                        @"roomId": self.roomID ?: @"default"
                    };
                    
                    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:answerDict
                                                                       options:0
                                                                         error:nil];
                    
                    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                    [self.signalingSocket send:jsonString];
                    
                    RTCLog(@"Resposta SDP enviada");
                }];
            }];
        }];
    }
    else if ([type isEqualToString:@"answer"]) {
        // Recebemos uma resposta à nossa oferta
        NSString *sdpString = messageDict[@"sdp"];
        RTCSessionDescription *remoteSdp = [[RTCSessionDescription alloc] 
                                           initWithType:RTCSdpTypeAnswer
                                                   sdp:sdpString];
        
        [self.peerConnection setRemoteDescription:remoteSdp 
                                completionHandler:^(NSError * _Nullable error) {
            if (error) {
                RTCLog(@"Erro ao definir descrição remota (resposta): %@", error);
                return;
            }
            
            RTCLog(@"Descrição remota definida com sucesso");
        }];
    }
    else if ([type isEqualToString:@"candidate"]) {
        // Recebemos um candidato ICE
        NSString *sdpMid = messageDict[@"sdpMid"];
        NSNumber *sdpMLineIndex = messageDict[@"sdpMLineIndex"];
        NSString *sdp = messageDict[@"candidate"];
        
        RTCIceCandidate *candidate = [[RTCIceCandidate alloc] 
                                     initWithSdp:sdp
                                      sdpMLineIndex:sdpMLineIndex.intValue
                                           sdpMid:sdpMid];
        
        [self.peerConnection addIceCandidate:candidate];
        
        RTCLog(@"Candidato ICE adicionado");
    }
    else if ([type isEqualToString:@"bye"]) {
        // Peer se desconectou
        RTCLog(@"Peer desconectou, fechando conexão");
        [self disconnect];
        
        // Notificar delegate
        if ([self.delegate respondsToSelector:@selector(webRTCManager:didDisconnectWithError:)]) {
            NSError *error = [NSError errorWithDomain:@"WebRTCManager" 
                                                code:1 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Peer desconectou"}];
            [self.delegate webRTCManager:self didDisconnectWithError:error];
        }
    }
}

#pragma mark - SRWebSocketDelegate

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    RTCLog(@"Conexão com servidor de sinalização estabelecida");
    
    // Criar a conexão peer
    [self createPeerConnection];
    
    // Iniciar o processo de oferta
    [self createOfferAndSend];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    RTCLog(@"Falha na conexão com servidor de sinalização: %@", error);
    
    self.connecting = NO;
    
    // Notificar delegate
    if ([self.delegate respondsToSelector:@selector(webRTCManager:didDisconnectWithError:)]) {
        [self.delegate webRTCManager:self didDisconnectWithError:error];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    // Processar mensagem recebida (JSON)
    NSData *jsonData = nil;
    
    if ([message isKindOfClass:[NSString class]]) {
        jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([message isKindOfClass:[NSData class]]) {
        jsonData = message;
    }
    
    if (jsonData) {
        NSError *error = nil;
        NSDictionary *messageDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                    options:0
                                                                      error:&error];
        
        if (error) {
            RTCLog(@"Erro ao parsear mensagem JSON: %@", error);
            return;
        }
        
        // Processar mensagem de sinalização
        [self processSignalingMessage:messageDict];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    RTCLog(@"Conexão com servidor de sinalização fechada: %@", reason);
    
    self.connecting = NO;
    
    // Se estava conectado, considerar como desconexão inesperada
    if (self.connected) {
        self.connected = NO;
        
        // Notificar delegate
        if ([self.delegate respondsToSelector:@selector(webRTCManager:didDisconnectWithError:)]) {
            NSError *error = [NSError errorWithDomain:@"WebRTCManager" 
                                                code:code 
                                            userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Conexão fechada"}];
            [self.delegate webRTCManager:self didDisconnectWithError:error];
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    RTCLog(@"Estado de sinalização alterado: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    RTCLog(@"Stream adicionada: %@ (vídeo: %lu, áudio: %lu)", 
           stream.streamId,
           (unsigned long)stream.videoTracks.count,
           (unsigned long)stream.audioTracks.count);
    
    // Capturar a primeira faixa de vídeo
    if (stream.videoTracks.count > 0) {
        RTCVideoTrack *videoTrack = stream.videoTracks[0];
        self.remoteVideoTrack = videoTrack;
        
        RTCLog(@"Faixa de vídeo recebida: %@", videoTrack.trackId);
        
        // Configurar para receber frames
        __weak WebRTCManager *weakSelf = self;
        RTCVideoRendererAdapter *adapter = [[RTCVideoRendererAdapter alloc] initWithRenderer:^(RTCVideoFrame * _Nonnull frame) {
            [weakSelf didReceiveVideoFrame:frame];
        }];
        
        [self.videoRenderers addObject:adapter];
        [videoTrack addRenderer:adapter];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    RTCLog(@"Stream removida: %@", stream.streamId);
    
    // Limpar recursos associados à stream
    self.remoteVideoTrack = nil;
    [self.videoRenderers removeAllObjects];
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    RTCLog(@"Renegociação necessária");
    
    // Iniciar renegociação
    [self createOfferAndSend];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    RTCLog(@"Estado de conexão ICE alterado: %ld", (long)newState);
    
    switch (newState) {
        case RTCIceConnectionStateConnected:
            self.connected = YES;
            self.connecting = NO;
            self.connectionStartTime = [NSDate date];
            RTCLog(@"Conexão WebRTC estabelecida");
            
            // Notificar delegate
            if ([self.delegate respondsToSelector:@selector(webRTCManager:didChangeConnectionState:)]) {
                [self.delegate webRTCManager:self didChangeConnectionState:newState];
            }
            break;
            
        case RTCIceConnectionStateFailed:
        case RTCIceConnectionStateDisconnected:
            self.connected = NO;
            RTCLog(@"Conexão WebRTC perdida ou falhou");
            
            // Notificar delegate
            if ([self.delegate respondsToSelector:@selector(webRTCManager:didChangeConnectionState:)]) {
                [self.delegate webRTCManager:self didChangeConnectionState:newState];
            }
            break;
            
        default:
            // Notificar delegate para outros estados
            if ([self.delegate respondsToSelector:@selector(webRTCManager:didChangeConnectionState:)]) {
                [self.delegate webRTCManager:self didChangeConnectionState:newState];
            }
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    RTCLog(@"Estado de coleta ICE alterado: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    // Enviar candidato ICE para o peer remoto
    NSDictionary *candidateDict = @{
        @"type": @"candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomID ?: @"default"
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:candidateDict
                                                   options:0
                                                     error:nil];
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.signalingSocket send:jsonString];
    
    RTCLog(@"Candidato ICE enviado: %@", candidate.sdp);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    RTCLog(@"Candidatos ICE removidos: %lu", (unsigned long)candidates.count);
}

#pragma mark - RTCDataChannelDelegate

- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {
    RTCLog(@"Estado do canal de dados alterado: %ld", (long)dataChannel.readyState);
    
    if (dataChannel.readyState == RTCDataChannelStateOpen) {
        // Canal de dados aberto, podemos enviar controles
        RTCLog(@"Canal de dados aberto, enviando preferências de qualidade");
        
        // Enviar configurações iniciais de qualidade
        NSDictionary *qualityMessage = @{
            @"type": @"quality",
            @"width": @(self.preferredResolution.width),
            @"height": @(self.preferredResolution.height),
            @"fps": @(self.preferredFrameRate),
            @"automaticQuality": @(self.automaticQualityControl)
        };
        
        NSData *data = [NSJSONSerialization dataWithJSONObject:qualityMessage
                                                       options:0
                                                         error:nil];
        
        if (data) {
            RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:data isBinary:NO];
            [dataChannel sendData:buffer];
        }
    }
}

- (void)dataChannel:(RTCDataChannel *)dataChannel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    if (buffer.isBinary) {
        // Ignorar mensagens binárias por enquanto
        return;
    }
    
    // Processar mensagem de texto (JSON)
    NSString *message = [[NSString alloc] initWithData:buffer.data encoding:NSUTF8StringEncoding];
    NSData *jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *messageDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                options:0
                                                                  error:&error];
    
    if (error) {
        RTCLog(@"Erro ao parsear mensagem do canal de dados: %@", error);
        return;
    }
    
    NSString *type = messageDict[@"type"];
    if ([type isEqualToString:@"stats"]) {
        // Estatísticas do peer remoto
        RTCLog(@"Estatísticas recebidas do peer: %@", messageDict[@"stats"]);
    }
}

#pragma mark - Tratamento de Frames

- (void)didReceiveVideoFrame:(RTCVideoFrame *)frame {
    NSTimeInterval now = CACurrentMediaTime();
    
    // Incrementar contador de frames
    self.receivedFrameCount++;
    
    // Atualizar estatísticas
    self.framesSinceLastFPSCalculation++;
    
    // Verificar resolução
    CGSize frameSize = CGSizeMake(frame.width, frame.height);
    if (!CGSizeEqualToSize(self.currentResolution, frameSize)) {
        self.currentResolution = frameSize;
        
        // Notificar mudança de resolução
        if ([self.delegate respondsToSelector:@selector(webRTCManager:didUpdateResolution:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate webRTCManager:self didUpdateResolution:frameSize];
            });
        }
        
        // Se for o primeiro frame, notificar
        if (self.receivedFrameCount == 1) {
            if ([self.delegate respondsToSelector:@selector(webRTCManager:didReceiveFirstFrameWithSize:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate webRTCManager:self didReceiveFirstFrameWithSize:frameSize];
                });
            }
        }
    }
    
    // Calcular FPS aproximadamente a cada segundo
    if (now - self.lastFPSCalculationTime >= 1.0) {
        float fps = self.framesSinceLastFPSCalculation / (now - self.lastFPSCalculationTime);
        self.currentFPS = fps;
        self.framesSinceLastFPSCalculation = 0;
        self.lastFPSCalculationTime = now;
        
        // Notificar mudança de FPS
        if ([self.delegate respondsToSelector:@selector(webRTCManager:didUpdateFrameRate:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate webRTCManager:self didUpdateFrameRate:fps];
            });
        }
        
        // Log periódico
        RTCLog(@"Stream WebRTC: %dx%d @ %.1f FPS (total: %llu frames)", 
               (int)self.currentResolution.width, 
               (int)self.currentResolution.height,
               self.currentFPS,
               self.receivedFrameCount);
    }
    
    // Armazenar o último frame recebido
    [self.frameLock lock];
    self.lastFrame = frame;
    self.lastFrameTime = now;
    [self.frameLock unlock];
    
    // Limpar cache periódicamente para evitar vazamento de memória
    if (self.frameCache.count > 10) {
        // Manter apenas os 3 frames mais recentes
        NSArray *keys = [self.frameCache.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (int i = 0; i < keys.count - 3; i++) {
            CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)[self.frameCache objectForKey:keys[i]];
            if (buffer) {
                CVPixelBufferRelease(buffer);
            }
            [self.frameCache removeObjectForKey:keys[i]];
        }
    }
}

@end