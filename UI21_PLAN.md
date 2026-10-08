# Vedette ui2.1 delivery plan

Base: verified ui2 source `cd0b34807c031d2e179f1ae397ea8c6847be35e3`; user confirmed its visual design is preferable to ui3 compact spacing. New branch `feat/ui21-cpu-efficiency`; candidate version `1.1.10-1+ui21`. User initially authorized “提交云端”. The generated commits will stay on `feat/ui21-cpu-efficiency`; cloud-build only. Device install/restart and APT publish are not authorized.

## Scope / assumptions

- Restore ui2 root, app/daemon lists, about, header, styling, grouping and whitespace. Only details row changes: giant PSSegmentCell → normal PSLinkListCell into VDTActionListController, which delegates reads/writes to the originating VDTProcessConfiguration.
- Keep package com.doimty.vedette and Preferences bundle com.doimty.vedetteprefs; Conflicts/Replaces the old package. Legacy file paths and Darwin notification names remain unchanged, preserving existing rules. Author udevs remains credited.
- E1 compile-time lazy diagnostic macro; Release arguments not evaluated/logger implementation omitted, Debug unchanged.
- E2 reuse validated config snapshot in runningboardd serial queue; publish after each prefs reload. No PID identity caching.
- No new foreground/background or temperature features. No CPU thresholds, scan timing, transition order, recovery semantics, process identity guards or two-stage reconciliation changed.
- No device install/restart or APT publication authorization.

## Success / failure criteria

1. Visual source (except action cell/controller) matches user-approved ui2 byte-for-byte; does not contain ui3 custom compact section view.
2. Action picker reads/writes only through its parent process controller; no fallback defaults. Enum/value/default/key and original mutation/notification tail unchanged.
3. Release macro side effects zero, Debug emitter/payload work. ObjC dictionary comma expansion remains valid.
4. Config cache only on serial control side: cold fallback/current snapshot or explicit reload generation. Restore-all still consumes the prior temp plist.
5. CPU manager/policy/identity/shared config/libproc/filter/install scripts remain frozen; all native safety tests pass.
6. Actual package name/control ID, own Preferences bundle ID, old package replacement metadata and localized resources are verified.

## Validation / boundary

`make -f Makefile.tests test`, `python3 -B tests/check_auto_monitor_path.py`, `bash tests/run_process_identity_tests.sh`, and `git diff --check` must pass. Apple Clang/Xcode and the real installed package are only checked in GitHub Actions. Frida process enumeration works, but attaching to Settings timed out; source tests cannot claim the picker was exercised natively. Cloud build/package success is not user-device visual acceptance.
