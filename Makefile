export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME = roothide

export DEBUG = 0
export FINALPACKAGE = 1

export PREFIX ?= $(THEOS)/toolchain/Xcode11.xctoolchain/usr/bin/

TARGET := iphone:clang:latest:7.0
INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Vedette

Vedette_FILES = $(wildcard *.xm) $(wildcard *.mm)
Vedette_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
