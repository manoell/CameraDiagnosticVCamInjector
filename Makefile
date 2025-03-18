TARGET := iphone:clang:14.5:14.0
INSTALL_TARGET_PROCESSES = Camera

# Compilar como um único tweak para preservar todo o sistema de diagnóstico
TWEAK_NAME = CameraDiagnostic

CameraDiagnostic_FILES = DiagnosticTweak.xm DiagnosticExtension.xm VCamHook.xm VCamInjector.mm
CameraDiagnostic_CFLAGS = -fobjc-arc
CameraDiagnostic_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreGraphics Photos Accelerate ImageIO MobileCoreServices

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
