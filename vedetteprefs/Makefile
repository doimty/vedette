ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:15.0
else
TARGET := iphone:clang:latest:7.0
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VedettePrefs

VedettePrefs_FILES = $(wildcard *.m) $(wildcard ChoicyPreferences/*.m) ../VDTShared.mm
VedettePrefs_FRAMEWORKS = UIKit
VedettePrefs_PRIVATE_FRAMEWORKS = Preferences
VedettePrefs_EXTRA_FRAMEWORKS = AltList
VedettePrefs_INSTALL_PATH = /Library/PreferenceBundles
VedettePrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)
VedettePrefs_LDFLAGS += -Wl,-rpath,@loader_path/../../Frameworks

include $(THEOS_MAKE_PATH)/bundle.mk
