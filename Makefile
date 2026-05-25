ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = *

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JLYSafePlugin
JLYSafePlugin_FILES = Tweak.xm
JLYSafePlugin_FRAMEWORKS = UIKit Foundation AVKit AVFoundation
JLYSafePlugin_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
