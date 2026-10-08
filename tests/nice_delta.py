"""Exact additive nice delta for legacy byte-freeze tests, never a wildcard skip.
Every listed legacy file must equal ui21 + these explicitly reviewed edits.
The rest of its bytes are then tested against the older ui2 contracts as before.
"""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='2994f24bbc73a6081d958f8f64ba4ff76640b8af'
INSTALL='''# A prior failed removal intentionally pauses fresh nice writes. Installation
# resumes the new runtime, without discarding any original-value journal.
if command -v jbroot >/dev/null 2>&1; then
    "$(jbroot)/usr/libexec/vedette-nicectl" resume || exit 1
else
    echo 'Vedette: cannot resolve nice control path.' >&2
    exit 1
fi

'''
ACCESSORS='''- (NSString *)vdtNiceIdentifier { return [self validIdentifier]; }
- (VDTConfigType)vdtNiceConfigurationType { return [self configurationType]; }

- (VDTNicePreferences *)vdtNicePreferences {
    if (!_nicePreferences) _nicePreferences = [[VDTNicePreferences alloc] initWithOwner:self];
    return _nicePreferences;
}

'''
RETRY='''// Explicit nice-only retry. One bounded event debounce; never a polling loop,
// and never calls the CPU policy execution path.
static BOOL nice_refresh_scheduled;
static void niceRefreshCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo){
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(vedette_serial_queue(), ^{
        if (nice_refresh_scheduled) return;
        nice_refresh_scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), vedette_serial_queue(), ^{
            NSDictionary *prefs = getPrefs();
            vdt_nice_reload(prefs);
            vdt_nice_reconcile();
            for (NSDictionary *target in vdt_resolve_targets(vdt_configs_from_prefs(prefs)))
                vdt_nice_apply(target);
            vdt_nice_publish();
            nice_refresh_scheduled = NO;
        });
    });
}

'''
CI_TESTS='''          make -f Makefile.tests test-nice STORE_RUNNER=sudo
          sudo bash tests/run_nice_native_tests.sh
'''
CI_ARTIFACT='''          python3 -B tests/verify_nice_archive.py "$deb"
          nicectl="/tmp/vedette-package/usr/libexec/vedette-nicectl"
          test -x "$nicectl"
          nm -u "$dylib" > /tmp/vedette-main-imports.txt
          nm -u "$nicectl" > /tmp/vedette-nicectl-imports.txt
          grep -Eq '(^|[[:space:]])_setpriority$' /tmp/vedette-main-imports.txt
          ! grep -Eq '(^|[[:space:]])_setpriority$' /tmp/vedette-nicectl-imports.txt
'''
NAMES={'Vedette.xm','Makefile','control','layout/DEBIAN/postinst','vedetteprefs/Makefile',
       'vedetteprefs/VDTProcessConfiguration.m','.github/workflows/roothide-build.yml'}
def expected_nice(name, base):
    s=base.decode()
    def change(old,new,count=1):
        nonlocal s
        assert s.count(old)==count,(name,old,s.count(old))
        s=s.replace(old,new)
    if name=='control': change('Version: 1.1.10-1+ui21','Version: 1.1.11-1+nice2')
    elif name=='Makefile': change('SUBPROJECTS += vedetteprefs\n','SUBPROJECTS += vedetteprefs nicectl\n')
    elif name=='layout/DEBIAN/postinst': change('#!/bin/bash\n\n','#!/bin/bash\n\n'+INSTALL)
    elif name=='vedetteprefs/Makefile':
        change(' ../VDTShared.mm\n',' ../VDTShared.mm ../VDTNiceShared.mm ../VDTNiceStore.c\n')
    elif name=='vedetteprefs/VDTProcessConfiguration.m':
        change('#import "VDTActionListController.h"\n','#import "VDTActionListController.h"\n#import "VDTNicePreferences.h"\n')
        change('- (NSArray *)specifiers {',ACCESSORS+'- (NSArray *)specifiers {')
        change('@"Enable this rule"','@"Enable CPU limits"',2)
        change('[rootSpecifiers addObject:intervalSpec];\n        \n        _specifiers',
               '[rootSpecifiers addObject:intervalSpec];\n\n        // Keep the nice controls independent from the legacy CPU rule editor.\n        [rootSpecifiers addObjectsFromArray:[[self vdtNicePreferences] specifiers]];\n        _specifiers')
    elif name=='.github/workflows/roothide-build.yml':
        s=s.replace('1.1.10-1+ui21','1.1.11-1+nice2')
        package_line='          make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide TARGET=iphone:clang:17.5:15.0 SYSROOT="$system_sdk" 2>&1 | tee /tmp/vedette-build.log\n'
        change(package_line,package_line+'          python3 -B tests/canonicalize_nice_deb.py packages/com.doimty.vedette_1.1.11-1+nice2_iphoneos-arm64e.deb\n')
        change('          python3 -B tests/test_diagnostic_preprocess.py\n','          python3 -B tests/test_diagnostic_preprocess.py\n'+CI_TESTS)
        change('          for binary in "$dylib" "$prefs_binary"; do\n',CI_ARTIFACT+'          for binary in "$dylib" "$prefs_binary" "$nicectl"; do\n')
    elif name=='Vedette.xm':
        change('#import "VDTProcessIdentity.h"\n','#import "VDTProcessIdentity.h"\n#import "VDTNiceRuntime.h"\n#import "VDTNiceShared.h"\n')
        change('static void apply_launch_target_if_needed(NSDictionary *target){\n',
               'static void apply_launch_target_if_needed(NSDictionary *target){\n    // Nice has independent success/retry tracking; CPU dedup must not hide it.\n    vdt_nice_apply(target);\n')
        change('    retire_targets_without_active_config(configs);\n','    retire_targets_without_active_config(configs);\n    vdt_nice_reconcile();\n',2)
        change('    normalized_configs_snapshot = [configs copy];\n','    normalized_configs_snapshot = [configs copy];\n    vdt_nice_reload(newPrefs);\n')
        change('    [tracked_process_instances() removeAllObjects];\n    for (NSDictionary *target in targets) {\n',
               '    [tracked_process_instances() removeAllObjects];\n    for (NSDictionary *target in targets) {\n        vdt_nice_apply(target);\n')
        change('    [tracked_process_instances() intersectSet:liveInstances];\n','    [tracked_process_instances() intersectSet:liveInstances];\n    vdt_nice_publish();\n')
        change('        if (success) [tracked_process_instances() addObject:instanceKey];\n    }\n}\n\n// Async wrapper',
               '        if (success) [tracked_process_instances() addObject:instanceKey];\n    }\n    vdt_nice_publish();\n}\n\n// Async wrapper')
        change('static void restoreAllMonitors(){\n    dispatch_async(vedette_serial_queue(), ^{\n',
               'static void restoreAllMonitors(){\n    dispatch_async(vedette_serial_queue(), ^{\n        // Nice restore follows the CURRENT saved settings, never a public\n        // notification alone. Its durable records do not depend on the CPU temp file.\n        vdt_nice_reload(getPrefs());\n        vdt_nice_reconcile();\n        vdt_nice_publish();\n')
        change('static NSString *current_executable_path(pid_t pid){',RETRY+'static NSString *current_executable_path(pid_t pid){')
        listeners=''.join('                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, niceRefreshCallback, CFSTR('+name+'), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);\n' for name in ['VDT_NICE_RETRY_NOTIFICATION','VDT_NICE_RESTORE_NOTIFICATION'])
        change('            if (isRunningBoard) {\n                reloadPrefs();\n','            if (isRunningBoard) {\n                reloadPrefs();\n'+listeners)
    return s.encode()
def without_nice(name, actual):
    from release_delta import without_release
    actual=without_release(name,actual)
    if name not in NAMES: return actual
    base=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
    assert actual==expected_nice(name,base),f'Unexpected change outside exact nice delta: {name}'
    return base
