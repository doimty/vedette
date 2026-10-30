#!/usr/bin/env python3
"""Source contracts for the one-shot catalog warm-up and the cheap re-entry gate.

These checks never execute UIKit or Preferences. They prove the reviewed shape:
the two directory catalogs are warmed once per Settings process, and the Apps
list rebuilds only when the saved configuration file actually changed.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PREFETCH = ROOT / 'vedetteprefs/VDTListPrefetch.m'
APPS = ROOT / 'vedetteprefs/VDTApplicationListSubcontrollerController.m'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def body(source, signature):
    match = re.search(re.escape(signature) + r'\s*\{', source)
    require(match is not None, 'method body not found: ' + signature)
    open_brace = match.end() - 1
    depth, index = 1, open_brace + 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[open_brace:index]


def prefetch_contract(source):
    require(source.count('[[VDTExtensionCatalog sharedInstance] ensureLoaded];') == 1,
            'extension catalog must be warmed exactly once per call site')
    require(source.count('[[VDTDaemonList sharedInstance] updateDaemonListIfNeeded];') == 1,
            'daemon catalog must be warmed exactly once per call site')
    warm = body(source, '+ (void)vdtWarmCatalogsOnce')
    require('static BOOL warmed = NO;' in warm, 'warm-up must be one-shot')
    require('if (warmed) return;' in warm, 'warm-up must not rescan')
    require(warm.index('if (warmed) return;') < warm.index('ensureLoaded'),
            'guard must precede both scans')
    require('dispatch_async(dispatch_get_main_queue()' in source,
            'catalogs are main-thread confined and must be warmed from main')
    for forbidden in ('NSTimer', 'dispatch_source', 'dispatch_after', 'while (', 'for ('):
        require(forbidden not in source, 'warm-up must not poll: ' + forbidden)


def apps_contract(source):
    appearance = body(source, '- (void)viewWillAppear:(BOOL)animated')
    require('VDTApplicationListPrefsToken()' in appearance, 're-entry must use the saved-file token')
    require('[self.vdtLastPrefsToken isEqual:token]' in appearance,
            're-entry must compare the previous token')
    require('self.vdtLastPrefsToken = token;' in appearance, 'token must be remembered')
    require(appearance.index('isEqual:token') < appearance.index('[self reloadSpecifiers]'),
            'rebuild must be gated by the comparison')
    require(appearance.count('[self reloadSpecifiers]') == 1,
            'viewWillAppear must contain exactly one conditional rebuild')
    token = body(source, 'static NSString *VDTApplicationListPrefsToken(void)')
    require('attributesOfItemAtPath:PREFS_PATH' in token, 'token must read only file metadata')
    require('NSFileModificationDate' in token and 'NSFileSize' in token,
            'token must notice same-size rewrites')
    for forbidden in ('getPrefs()', 'dictionaryWithContentsOfFile', 'writeToFile'):
        require(forbidden not in token, 'token must stay cheap: ' + forbidden)


def apps_mutants(source):
    yield ('unconditional-rebuild',
           '    if (!self.vdtLastPrefsToken || ![self.vdtLastPrefsToken isEqual:token]) {\n'
           '        self.vdtLastPrefsToken = token;\n        [self reloadSpecifiers];\n    }',
           '    self.vdtLastPrefsToken = token;\n    [self reloadSpecifiers];')


def prefetch_mutants(source):
    yield ('repeat-warm-up',
           '    static BOOL warmed = NO;\n    if (warmed) return;\n    warmed = YES;',
           '    static BOOL warmed = NO;\n    warmed = YES;')
    yield ('timer-based-warm-up',
           '        [self vdtWarmCatalogsOnce];\n    });\n}',
           '        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [self vdtWarmCatalogsOnce]; }];\n    });\n}')


def main():
    prefetch = PREFETCH.read_text(encoding='utf-8')
    apps = APPS.read_text(encoding='utf-8')
    prefetch_contract(prefetch)
    apps_contract(apps)
    print('PASS list warm-up is one-shot and Apps re-entry is gated', flush=True)

    killed = 0
    for name, old, new in apps_mutants(apps):
        require(apps.count(old) == 1, 'mutation anchor missing: ' + name)
        try:
            apps_contract(apps.replace(old, new, 1))
        except (AssertionError, ValueError):
            killed += 1
            print('KILLED source mutant: ' + name, flush=True)
        else:
            raise AssertionError('mutant survived: ' + name)
    for name, old, new in prefetch_mutants(prefetch):
        require(prefetch.count(old) == 1, 'mutation anchor missing: ' + name)
        try:
            prefetch_contract(prefetch.replace(old, new, 1))
        except (AssertionError, ValueError):
            killed += 1
            print('KILLED source mutant: ' + name, flush=True)
        else:
            raise AssertionError('mutant survived: ' + name)
    require(killed == 3, 'every mutant must be rejected')
    return 0


if __name__ == '__main__':
    sys.exit(main())
