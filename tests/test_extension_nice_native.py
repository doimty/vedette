#!/usr/bin/env python3
"""Production Foundation + fake-kernel nice lifecycle regression.
Linux: source contract and iPhone SDK syntax ONLY, exit 77 (or 1 --require-native).
Darwin: root-owned temporary plist/journal, no sudo, no real policy syscalls.
"""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
C_SOURCES = ['VDTNicePolicy', 'VDTNiceStore', 'VDTProcessIdentity',
             'VDTPolicyTransition', 'VDTBundleRules', 'VDTMemoryPolicy',
             'VDTJetsamPolicy', 'VDTResourceApply']
MM_SOURCES = ['VDTNiceShared.mm', 'VDTShared.mm', 'VDTProcessManager.mm',
              'VDTBundleIdentity.mm', 'tests/test_extension_nice_native.mm']
MUTANTS = {
    'noExtensionResolve': ('VDTProcessManager.mm',
        'type = VDTConfigTypeExtension; name = info[@"extensionIdentifier"];',
        'return nil; type = VDTConfigTypeExtension; name = info[@"extensionIdentifier"];'),
    'disableinherit': ('VDTNiceRuntime.mm',
        'NSDictionary *rule = ruleForTarget(target, rules);\n    if (protectedRule(rule)',
        'NSDictionary *rule = rules[ruleKey(target)];\n    if (protectedRule(rule)'),
    'CPUcoupling': ('Vedette.xm',
        'for (NSDictionary *target in targets) vdt_nice_apply(target);',
        'for (NSDictionary *target in targets) { vdt_apply_target(target); vdt_nice_apply(target); }'),
    'PIDreuse': ('VDTNiceRuntime.mm',
        'return VDTNiceIdentityGone;\n    if (!vdt_target_is_current(target))',
        'return VDTNiceIdentityCurrent;\n    if (!vdt_target_is_current(target))'),
    'ignoreownsource': ('VDTNiceShared.mm',
        'NSDictionary *source = rules[key];',
        'NSDictionary *source = type == VDTConfigTypeExtension ? nil : rules[key];'),
    'savejustUI': ('VDTNiceShared.mm',
        'BOOL VDTNiceSavePreference(NSString *identifier, VDTConfigType type, NSString *key, id value, NSError **error) {',
        'BOOL VDTNiceSavePreference(NSString *identifier, VDTConfigType type, NSString *key, id value, NSError **error) {\n    if (type == VDTConfigTypeExtension) return YES;'),
}

def run(command):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(command, check=True)

def source_checks(root):
    life = (root / 'Vedette.xm').read_text()
    runtime = (root / 'VDTNiceRuntime.mm').read_text()
    launch = life.split('static void apply_launch_target_if_needed', 1)[1].split('static NSString *config_identity_key', 1)[0]
    assert 'vdt_nice_apply' not in launch, 'CPU launch still owns nice dispatch'
    assert 'vdt_nice_targets_for_pid_from_rules(pid, current_normalized_nice_rules_sync())' in life
    handler = life[life.index('static void handle_reported_pid_sync'):life.index('// Core prefs reload logic')]
    assert 'VDTGetPrefs' not in handler and 'VDTNiceRulesFromPrefs' not in handler
    assert 'normalized_nice_rules_snapshot = [VDTNiceRulesFromPrefs(newPrefs) copy];' in life
    for begin, end in [('reconcile_unreported_processes_sync', 'schedule_launch_catch_up_sync'),
                       ('reloadPrefsSync', 'reloadPrefs()'),
                       ('restoreAllMonitors()', 'prefsChangedCallback'),
                       ('niceRefreshCallback', 'current_executable_path')]:
        body = life[life.index(begin):life.index(end, life.index(begin) + len(begin))]
        expected_resolver = ('vdt_nice_resolve_targets_from_rules(current_normalized_nice_rules_sync())'
            if begin in ('reconcile_unreported_processes_sync', 'reloadPrefsSync')
            else 'vdt_nice_resolve_targets(prefs)')
        assert expected_resolver in body, begin
        assert 'vdt_nice_publish()' in body, begin
    assert 'NSDictionary *rule = ruleForTarget(target, rules);\n    if (protectedRule(rule)' in runtime
    assert 'target = targetWithSource(target, rule);' in runtime
    assert 'if (key) allRules[key] = ruleForTarget(target, rules);' in runtime
    for _, (file, old, _) in MUTANTS.items():
        assert (root / file).read_text().count(old) == 1, 'mutant anchor: ' + file
    print('PASS: independent lifecycle/source contracts (not native execution)', flush=True)

def snapshot(destination):
    for pattern in ('*.h', '*.mm', '*.c', '*.xm'):
        for path in ROOT.glob(pattern):
            shutil.copy2(path, destination / path.name)
    shutil.copytree(ROOT / 'libproc', destination / 'libproc')
    (destination / 'tests').mkdir()
    shutil.copy2(ROOT / 'tests/test_extension_nice_native.mm', destination / 'tests/test_extension_nice_native.mm')
    for name in ('extension_nice_stubs', 'native_stubs'):
        shutil.copytree(ROOT / 'tests' / name, destination / 'tests' / name)

def generate_life(root):
    text = (root / 'Vedette.xm').read_text()
    assert text.count('%ctor{') == 1 and '%hook' not in text and '%init' not in text
    (root / 'Vedette.fixture.mm').write_text(text.replace('%ctor{', 'static void VDTFixtureCtor(void){'))

def compile_fixture(root, sdk=None, arch='arm64'):
    generate_life(root)
    includes = ['-I' + str(root / 'tests/extension_nice_stubs'),
                '-I' + str(root / 'tests/native_stubs'), '-I' + str(root)]
    warnings = ['-Wall', '-Wextra', '-Werror']
    cross = ['-target', arch + '-apple-ios15.0', '-isysroot', str(sdk)] if sdk else []
    cc = ['clang'] if sdk else ['xcrun', 'clang']
    cxx = ['clang++'] if sdk else ['xcrun', 'clang++']
    objects = []
    for name in C_SOURCES:
        obj = root / (name + '.o')
        run(cc + cross + ['-std=c11'] + warnings + includes +
            (['-fsyntax-only'] if sdk else ['-c']) + [str(root / (name + '.c'))] +
            ([] if sdk else ['-o', str(obj)]))
        objects.append(str(obj))
    common = cxx + cross + ['-std=c++17', '-fobjc-arc', '-fblocks'] + warnings + includes + [
        '-include', str(root / 'tests/extension_nice_stubs/kernel.h')]
    if sdk:
        for source in MM_SOURCES:
            run(common + ['-fsyntax-only', str(root / source)])
        print('PASS: iPhoneOS SDK syntax; not Apple linking/runtime', flush=True)
        return None
    output = root / 'native'
    run(common + [str(root / source) for source in MM_SOURCES] + objects +
        ['-framework', 'Foundation', '-o', str(output)])
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--static-only', action='store_true', help='source contracts only; no native claims')
    parser.add_argument('--require-native', action='store_true')
    parser.add_argument('--sdk', type=Path, default=Path('/var/minis/workspace/netshield2-review/apple-sdk/iPhoneOS16.5.sdk'))
    parser.add_argument('--skip-mutants', action='store_true', help='diagnostic baseline only; not full acceptance')
    args = parser.parse_args()
    source_checks(ROOT)
    if args.static_only:
        if args.require_native: raise SystemExit('FAIL: static-only cannot satisfy require-native')
        return 0
    with tempfile.TemporaryDirectory(prefix='vdt-extension-nice-') as tmp:
        base = Path(tmp) / 'baseline'; base.mkdir(); snapshot(base)
        if platform.system() != 'Darwin':
            if not args.sdk.is_dir():
                raise SystemExit('FAIL: SDK absent; specify --sdk')
            for arch in ('arm64', 'arm64e'):
                compile_fixture(base, args.sdk, arch)
            print('SKIP: Foundation native/mutants require Darwin root; NEVER PASS', flush=True)
            return 1 if args.require_native else 77
        if os.geteuid() != 0:
            print('FAIL: run explicitly as root in isolated macOS CI; runner never calls sudo')
            return 1 if args.require_native else 77
        run([str(compile_fixture(base))])
        if args.skip_mutants:
            print('SKIP: mutants; baseline only')
            return 1 if args.require_native else 0
        for name, (file, old, new) in MUTANTS.items():
            tree = Path(tmp) / name; shutil.copytree(base, tree)
            path = tree / file; path.write_text(path.read_text().replace(old, new, 1))
            binary = compile_fixture(tree)  # compile failure is FAILURE, never a killed mutant
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            if result.returncode == 0 or 'ASSERTION FAILED:' not in result.stderr:
                raise RuntimeError(f'{name}: did not fail a real runtime assertion: {result.returncode}\n{result.stderr}')
            print('KILLED (runtime assertion):', name, result.stderr.strip(), flush=True)
        print('PASS: production Foundation fake-kernel baseline + 6 runtime mutants (not device)', flush=True)
        return 0

if __name__ == '__main__':
    raise SystemExit(main())
