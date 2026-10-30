#!/usr/bin/env python3
"""Production Foundation presentation regression and targeted compiled mutants.

On Darwin, compile the real Presentation and Model with the fixture, run the
baseline, then compile and run each precise Presentation mutant. No UIKit,
Preferences framework, device access or device runtime is involved. Elsewhere
return SKIP 77, or fail with --require-native; --source-only reports source
evidence without claiming any Foundation execution.
"""
import argparse
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
HEADER = PREFS / 'VDTCheckPresentation.h'
PRESENTATION = PREFS / 'VDTCheckPresentation.m'
MODEL = PREFS / 'VDTCheckResultModel.m'
FIXTURE = ROOT / 'tests' / 'test_check_presentation_native.m'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def mutants(source):
    changes = [
        ('observed-routed-to-check',
         'NSSet *resultIDs = [NSSet setWithArray:@[@"state", @"target", @"observed"]];',
         'NSSet *resultIDs = [NSSet setWithArray:@[@"state", @"target"]];',
         'group-result'),
        ('errno-routed-to-identity',
         'NSSet *identityIDs = [NSSet setWithArray:@[@"code", @"evidence", @"pid", @"instance", @"original", @"count"]];',
         'NSSet *identityIDs = [NSSet setWithArray:@[@"code", @"evidence", @"pid", @"instance", @"original", @"count", @"errno"]];',
         'group-identity'),
        ('read-time-hidden-in-history',
         'NSSet *historyIDs = [NSSet setWithArray:@[@"lastAttempt"]];',
         'NSSet *historyIDs = [NSSet setWithArray:@[@"lastAttempt", @"readTime"]];',
         'group-check'),
        ('scope-hidden-in-history',
         'NSSet *historyIDs = [NSSet setWithArray:@[@"lastAttempt"]];',
         'NSSet *historyIDs = [NSSet setWithArray:@[@"lastAttempt", @"scope"]];',
         'group-check'),
        ('history-routed-to-primary',
         'if (diagnostics) [history addObject:field];',
         'if (!diagnostics) [check addObject:field];',
         'group-check'),
    ]
    for name, old, new, marker in changes:
        require(source.count(old) == 1, 'mutation anchor absent or ambiguous: ' + name)
        require(old != new, 'empty mutation: ' + name)
        yield name, source.replace(old, new, 1), marker


def fixture_ids(fixture, function):
    pattern = r'static NSArray \*' + re.escape(function) + r'\(void\)\s*\{\s*return @\[(.*?)\];\s*\}'
    match = re.search(pattern, fixture, re.S)
    require(match is not None, 'fixture ID array not found: ' + function)
    return re.findall(r'@"([^"\n]+)"', match.group(1))


def diagnostic_ids(text):
    return re.findall(r'VDTCheckDiagnostic\(\s*diagnostics,\s*@"([^"\n]+)"', text)


def source_contracts():
    header = HEADER.read_text(encoding='utf-8')
    source = PRESENTATION.read_text(encoding='utf-8')
    model = MODEL.read_text(encoding='utf-8')
    fixture = FIXTURE.read_text(encoding='utf-8')
    for symbol in ('VDTCheckPresentationSections', 'VDTCheckPresentationFields'):
        require(symbol + '(' in header and symbol + '(' in source and symbol + '(' in fixture,
                'presentation declaration/implementation/fixture missing: ' + symbol)
    require('#import <Foundation/Foundation.h>' in header and '#import "VDTCheckPresentation.h"' in source,
            'presentation must use its Foundation interface')
    require('UIKit/' not in source and 'Preferences/' not in source,
            'presentation unexpectedly imports a UI framework')
    require('VDTCheckResultModels(' in fixture, 'fixture must exercise the production model')

    core = re.findall(r'VDTCheckField\(\s*@"([^"\n]+)"', model)
    require(core == fixture_ids(fixture, 'resourceCoreIDs'), 'resource fixture core IDs differ from Model source')
    require([item for item in core if item not in ('lastAttempt', 'scanStatus')] == fixture_ids(fixture, 'niceCoreIDs'),
            'nice fixture core IDs differ from Model source')
    start = model.index('    NSMutableArray *diagnostics = [NSMutableArray array];')
    end = model.index('    return @{@"title":', start)
    diagnostic_source = model[start:end]
    nice = diagnostic_source.index('    if (nice) {\n        VDTCheckDiagnostic')
    resource = diagnostic_source.index('    } else {\n        VDTCheckDiagnostic', nice)
    suffix = diagnostic_source.index('    }\n    VDTCheckDiagnostic(diagnostics, @"settingsAvailable"', resource)
    common = diagnostic_ids(diagnostic_source[:nice])
    last = diagnostic_ids(diagnostic_source[suffix:])
    require(common + diagnostic_ids(diagnostic_source[nice:resource]) + last == fixture_ids(fixture, 'niceDiagnosticIDs'),
            'nice fixture diagnostic IDs differ from Model source')
    require(common + diagnostic_ids(diagnostic_source[resource:suffix]) + last == fixture_ids(fixture, 'resourceDiagnosticIDs'),
            'resource fixture diagnostic IDs differ from Model source')
    changes = list(mutants(source))
    for name, _, marker in changes:
        require('REQ("' + marker + '"' in fixture, 'fixture lacks expected mutant marker: ' + name)
    print('PASS source evidence: Presentation symbols and real Model field IDs match the fixture (source only)', flush=True)
    print(f'PASS source evidence: {len(changes)} unique mutation anchors and failure markers exist (not compiled or executed)', flush=True)
    return source


def run_native(source):
    with tempfile.TemporaryDirectory(prefix='vdt-check-presentation-') as directory:
        temporary = Path(directory)
        binary = temporary / 'check-presentation'
        command = ['xcrun', 'clang', '-std=gnu11', '-fobjc-arc', '-fblocks', '-O1',
                   '-Wall', '-Wextra', '-Werror', '-I' + str(PREFS), '-I' + str(ROOT)]

        def build(presentation):
            subprocess.run(command + [str(presentation), str(MODEL), str(FIXTURE),
                                      '-framework', 'Foundation', '-framework', 'CoreFoundation',
                                      '-o', str(binary)], cwd=ROOT, check=True)
            return binary

        # Build and run the production files directly before creating mutants.
        subprocess.run([str(build(PRESENTATION))], cwd=temporary, check=True)
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        for name, altered, marker in mutants(source):
            mutant = temporary / ('VDTCheckPresentation-' + name + '.m')
            mutant.write_text(altered, encoding='utf-8')
            build(mutant)  # A compile failure is a gate failure, never a kill.
            result = subprocess.run([str(binary)], cwd=temporary, capture_output=True, text=True)
            expected = r'(?m)^CHECK_PRESENTATION_FAIL:' + re.escape(marker) + r' line \d+\s*$'
            require(result.returncode != 0 and re.search(expected, result.stderr) is not None,
                    'mutant survived or failed off-target: ' + name + '\nexit=' + str(result.returncode)
                    + '\nstdout:\n' + result.stdout + '\nstderr:\n' + result.stderr)
            print('KILLED compiled Presentation mutant:', name, '(' + marker + ')', flush=True)
        print('PASS native Presentation + Model and 5 targeted mutants (Foundation/CoreFoundation; no device IO)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--require-native', action='store_true', help='fail if Darwin Foundation is unavailable')
    mode.add_argument('--source-only', action='store_true', help='check source evidence only; never a native pass')
    args = parser.parse_args()
    if args.source_only:
        source_contracts()
        return 0
    if platform.system() != 'Darwin':
        if args.require_native:
            print('FAIL check-presentation native gate: Darwin Foundation required; no build or native run performed', flush=True)
            return 1
        print('SKIP check-presentation native gate: requires Darwin Foundation; no build or native run performed', flush=True)
        return 77
    run_native(source_contracts())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
