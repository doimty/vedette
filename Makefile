export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME ?= roothide

export DEBUG = 0
export FINALPACKAGE = 1

export PREFIX ?= $(THEOS)/toolchain/Xcode11.xctoolchain/usr/bin/

ifeq ($(filter $(THEOS_PACKAGE_SCHEME),roothide rootless),)
$(error Supported package schemes: roothide rootless)
endif
export TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Vedette

Vedette_FILES = $(wildcard *.xm) $(wildcard *.mm) $(wildcard *.c)
Vedette_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs nicectl
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	python3 ci/stage_release.py --scheme "$(THEOS_PACKAGE_SCHEME)" --stage "$(THEOS_STAGING_DIR)"
