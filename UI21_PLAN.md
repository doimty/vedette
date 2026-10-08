# Vedette ui2.1 delivery plan

Base: verified ui2 source `cd0b34807c031d2e179f1ae397ea8c6847be35e3`; user confirmed its visual design is preferable to ui3 compact spacing. New independent branch `feat/ui21-cpu-efficiency`. User authorized “ui2.1 + CPU optimization”; this candidate assigns version `1.1.10-1+ui21`, retains own package/bundle IDs and legacy data channels, and contains two bounded CPU-efficiency changes.

## Assumptions and scope

- Restore all ui2 visual source on root, app list, daemon list, about and header/layout; do not keep ui3 44pt list density, compact custom section headers/footers or row truncation.
- The sole UI change atop ui2 is replace the visually dominant PSSegmentCell with a normal `PSLinkListCell` → `VDTActionListController` backed by `PSListItemsController`, preserving both enum values, order, default and owner configuration callbacks.
- CPU E1: compile-time lazy diagnostics; Release callsites do not evaluate label/payload, Debug keeps fields.
- CPU E2: cache validated config normalization within runningboardd's serial queue; publish snapshot only on config reload. Every actual PID-lifetime/security check remains.
- Do not change CPU thresholds, syscall transition order, automatic two-stage scan/debounce, retirement, recovery, preference file paths, Darwin notification names, disabled entry semantics or mode defaults.
- No device install/restart, APT repository publication, CPU sampling instrumentation, or new automatic foreground/battery/temperature features.

## Contracts / failure signals

1. UI source files except VDTProcessConfiguration must match ui2 byte-for-byte; in process screen only imported action controller, choice cell/class and generic values/title metadata may differ. Original write callback tail and `PREFS_CHANGED_NN` remain untouched.
2. Action picker with no owning VDTProcessConfiguration must not write to a fallback defaults domain. If owner exists, uses same read/set methods.
3. Release diagnostic expressions have zero side effects and no logger symbol; Debug evaluates payload once per call and preserves existing event labels/data. Objective-C dictionary commas remain one expression.
4. Re-normalization occurs only on cold-cache fallback or prefs reload. Every change reloads and replaces snapshot before scanning. Restore-all remains an explicit separate source from old temp prefs.
5. Backend safety paths and C suites byte-identical/pass. No UID, full process identity, launch debounce, retry, restore or strong kill changes.
6. Validate new package ID and both bundle ID/package conflict replacement against the prior ID; old plist path/notification channels remain byte-identical to avoid losing existing rules.

## Validation commands

`make -f Makefile.tests test`; `python3 -B tests/test_preferences_ui.py`; `python3 -B tests/test_ios15_cell_lifecycle.py`; `python3 -B tests/test_package_identity.py`; `git diff --check`.

Apple/UIKit/Preferences host compilation unavailable in iSH. Cloud Xcode 17.5/SDK17.5 ARM64+arm64e build and actual-deb metadata/resource validation are required. Device validation still required for PSListItemsController owner callbacks and Dynamic Type. Existing Frida attach timeout prevents claiming a runtime UI test.
