TARGET := iphone:clang:14.5:14.0
INSTALL_TARGET_PROCESSES = Camera

TWEAK_NAME = CameraDiagnostic VCamInjector

CameraDiagnostic_FILES = DiagnosticExtension.xm DiagnosticTweak.xm VCamHook.xm VCamInjector.mm
CameraDiagnostic_CFLAGS = -fobjc-arc
CameraDiagnostic_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreGraphics Photos

VCamInjector_FILES = VCamHook.xm VCamInjector.mm
VCamInjector_CFLAGS = -fobjc-arc -std=c++11
VCamInjector_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreGraphics Accelerate ImageIO MobileCoreServices

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
