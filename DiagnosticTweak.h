#ifndef VCAM_INJECTOR_H
#define VCAM_INJECTOR_H

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>

// Interface principal do injetor de câmera virtual
@interface VCamInjector : NSObject

// Singleton
+ (instancetype)sharedInstance;

// Estado da injeção
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign, getter=isProcessingFrame) BOOL processingFrame;
@property (nonatomic, assign) BOOL preserveAspectRatio;
@property (nonatomic, assign) BOOL mirrorOutput;
@property (nonatomic, strong) NSString *sourceType;

// Configurações de resolução
@property (nonatomic, assign) CGSize targetResolution;
@property (nonatomic, assign) CGSize originalResolution;

// Estatísticas
@property (nonatomic, assign) uint64_t frameCount;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, assign) float averageProcessingTime;

// Inicialização
- (void)setupWithOptions:(NSDictionary *)options;

// Métodos principais de injeção
- (CMSampleBufferRef)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
                              fromConnection:(AVCaptureConnection *)connection;

- (CVPixelBufferRef)createPixelBufferWithData:(NSData *)imageData
                                    formatType:(OSType)formatType
                                       forSize:(CGSize)size;

// Utilitários
- (CVPixelBufferRef)resizePixelBuffer:(CVPixelBufferRef)sourceBuffer
                              toWidth:(size_t)width
                             toHeight:(size_t)height;

- (CMFormatDescriptionRef)createFormatDescriptionForPixelBuffer:(CVPixelBufferRef)pixelBuffer;

// Métodos para diferentes fontes de entrada
- (CVPixelBufferRef)pixelBufferFromFile:(NSString *)filePath;
- (CVPixelBufferRef)pixelBufferFromJPEGData:(NSData *)jpegData;
- (CVPixelBufferRef)pixelBufferFromStream:(NSURL *)streamURL;

// Controle de cache e gerenciamento de memória
- (void)clearBufferCache;
- (void)resetState;

@end

// Interface para configuração
@interface VCamConfiguration : NSObject

+ (instancetype)sharedConfig;
- (NSDictionary *)currentSettings;
- (void)loadSettings;
- (void)saveSettings;
- (void)resetToDefaults;

@property (nonatomic, strong) NSString *sourceType;
@property (nonatomic, strong) NSString *sourcePath;
@property (nonatomic, assign) BOOL preserveAspectRatio;
@property (nonatomic, assign) BOOL mirrorOutput;
@property (nonatomic, assign) BOOL applyFilters;
@property (nonatomic, assign) BOOL matchOriginalFPS;
@property (nonatomic, assign) CGSize defaultResolution;

@end

// Funções C para diagnóstico
void startNewDiagnosticSession(void);
void finalizeDiagnosticSession(void);
void logToFile(NSString *message);
void addDiagnosticData(NSString *eventType, NSDictionary *eventData);
void logSessionInfo(NSString *key, id value);

// Variáveis globais para diagnóstico
extern NSString *g_sessionId;
extern NSString *g_appName;
extern NSString *g_bundleId;
extern CGSize g_cameraResolution;
extern CGSize g_frontCameraResolution;
extern CGSize g_backCameraResolution;
extern int g_videoOrientation;
extern BOOL g_isCapturingPhoto;
extern BOOL g_isRecordingVideo;
extern BOOL g_usingFrontCamera;
extern NSDictionary *g_lastPhotoMetadata;
extern NSMutableDictionary *g_sessionInfo;
extern NSMutableDictionary *g_appDiagnosticData;

// Funções C para simplificar uso em hooks
#ifdef __cplusplus
extern "C" {
#endif

// Função principal para substituição de frame
CMSampleBufferRef VCamCreateReplacementSampleBuffer(CMSampleBufferRef original, AVCaptureConnection *connection);

// Utilitários
BOOL VCamShouldReplaceFrame(void);
void VCamSetEnabled(BOOL enabled);
CVPixelBufferRef VCamCreatePixelBuffer(size_t width, size_t height, OSType pixelFormat);
UIImage *VCamImageFromPixelBuffer(CVPixelBufferRef pixelBuffer);
NSData *VCamJPEGDataFromPixelBuffer(CVPixelBufferRef pixelBuffer, float quality);

#ifdef __cplusplus
}
#endif

#endif /* VCAM_INJECTOR_H */
