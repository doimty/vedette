# Independent diagnostic only. No Theos include/package/install/sign/run target.
# All build/link operations are opt-in; the default only displays usage.
CC := clang
CFLAGS := -std=c11 -Wall -Wextra -Werror -pedantic
SDK_ROOT ?=
OUT_DIR ?=

.PHONY: all help test syntax device-arm64 device-arm64e
all: help
help:
	@echo 'make test                         isolated host fakebackend contracts'
	@echo 'make syntax SDK_ROOT=/path/to/iPhoneOS.sdk   no linking or execution'
	@echo 'make device-arm64 SDK_ROOT=... OUT_DIR=...   manual build, not packaged'
	@echo 'make device-arm64e SDK_ROOT=... OUT_DIR=...  manual build, not packaged'
	@echo 'Device execution is NOT a make target and needs separate authorization.'

test:
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_readonly_contracts.py

syntax:
	@test -n "$(SDK_ROOT)" && test -d "$(SDK_ROOT)/usr/include" || { echo 'SDK_ROOT required' >&2; exit 2; }
	$(CC) $(CFLAGS) -target arm64-apple-ios15.0 -isysroot "$(SDK_ROOT)" -fsyntax-only main.c
	$(CC) $(CFLAGS) -target arm64e-apple-ios15.0 -isysroot "$(SDK_ROOT)" -fsyntax-only main.c

# Future explicitly authorized macOS/Apple-linker build; never runs the binary.
device-arm64:
	@test -n "$(SDK_ROOT)" && test -n "$(OUT_DIR)" || { echo 'SDK_ROOT and OUT_DIR required' >&2; exit 2; }
	mkdir -p "$(OUT_DIR)"
	$(CC) $(CFLAGS) -target arm64-apple-ios15.0 -isysroot "$(SDK_ROOT)" main.c -o "$(OUT_DIR)/memorystatus-readonly-arm64"

device-arm64e:
	@test -n "$(SDK_ROOT)" && test -n "$(OUT_DIR)" || { echo 'SDK_ROOT and OUT_DIR required' >&2; exit 2; }
	mkdir -p "$(OUT_DIR)"
	$(CC) $(CFLAGS) -target arm64e-apple-ios15.0 -isysroot "$(SDK_ROOT)" main.c -o "$(OUT_DIR)/memorystatus-readonly-arm64e"
