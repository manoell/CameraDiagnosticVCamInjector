#ifndef WEBRTC_MANAGER_H
#define WEBRTC_MANAGER_H

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <CoreVideo/CoreVideo.h>

// Forward declaration para o delegate
@protocol WebRTCManagerDelegate;

/**
 * WebRTCManager - Gerencia conexão WebRTC e recebimento de frames de vídeo
 * 
 * Esta classe é responsável por:
 * 1. Conectar a um servidor de sinalização
 * 2. Estabelecer uma conexão peer-to-peer para streaming de vídeo
 * 3. Receber frames de vídeo e convertê-los para o formato compatível com AVFoundation
 * 4. Gerenciar a qualidade do stream de acordo com a conexão
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, RTCVideoViewDelegate>

// Singleton
+ (instancetype)sharedInstance;

// Delegate para notificações e callbacks
@property (nonatomic, weak) id<WebRTCManagerDelegate> delegate;

// Estado da conexão
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, getter=isConnecting) BOOL connecting;
@property (nonatomic, readonly) NSTimeInterval connectionDuration;

// Estatísticas de frame
@property (nonatomic, readonly) uint64_t receivedFrameCount;
@property (nonatomic, readonly) float currentFPS;
@property (nonatomic, readonly) CGSize currentResolution;
@property (nonatomic, readonly) NSTimeInterval lastFrameTime;

// Configuração
@property (nonatomic, copy) NSString *serverURL;
@property (nonatomic, copy) NSString *roomID;
@property (nonatomic, assign) BOOL automaticQualityControl;
@property (nonatomic, assign) CGSize preferredResolution;
@property (nonatomic, assign) float preferredFrameRate;

// Métodos de conexão
- (void)connectWithConfiguration:(NSDictionary *)config;
- (void)disconnect;
- (void)reconnect;

// Controle do stream
- (void)pauseStream;
- (void)resumeStream;
- (void)setQualityPreset:(NSString *)preset; // "low", "medium", "high", "max"

// Acesso a frames e conversão
- (RTCVideoFrame *)lastReceivedFrame;
- (CVPixelBufferRef)lastReceivedPixelBuffer;
- (CVPixelBufferRef)convertRTCFrameToPixelBuffer:(RTCVideoFrame *)frame;

// Estatísticas e diagnóstico
- (NSDictionary *)currentStatistics;
- (void)logDiagnosticInfo;

@end

/**
 * Protocolo de delegate para WebRTCManager
 */
@protocol WebRTCManagerDelegate <NSObject>

@optional
// Eventos de conexão
- (void)webRTCManager:(WebRTCManager *)manager didChangeConnectionState:(RTCIceConnectionState)state;
- (void)webRTCManager:(WebRTCManager *)manager didConnectWithPeerId:(NSString *)peerId;
- (void)webRTCManager:(WebRTCManager *)manager didDisconnectWithError:(NSError *)error;

// Eventos de mídia
- (void)webRTCManager:(WebRTCManager *)manager didReceiveFirstFrameWithSize:(CGSize)size;
- (void)webRTCManager:(WebRTCManager *)manager didUpdateResolution:(CGSize)newResolution;
- (void)webRTCManager:(WebRTCManager *)manager didUpdateFrameRate:(float)newFrameRate;

// Eventos de diagnóstico
- (void)webRTCManager:(WebRTCManager *)manager didEncounterIssue:(NSString *)issue withSeverity:(NSInteger)severity;

@end

#endif /* WEBRTC_MANAGER_H */