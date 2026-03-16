THEOS ?= /home/devil/theos
THEOS_PACKAGE_SCHEME ?= rootless

ARCHS = arm64
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniProcMon

MiniProcMon_FILES = Tweak.xm
MiniProcMon_FRAMEWORKS = UIKit QuartzCore
MiniProcMon_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
