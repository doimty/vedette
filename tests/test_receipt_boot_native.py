#!/usr/bin/env python3
"""Real Foundation boot-receipt regression. Static PASS is never native evidence.
Darwin/root only: isolated Store, fake sysctl, no policies/helper/notifications.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '1a5e270'
FIXTURE = ROOT / 'tests/test_receipt_boot_native.mm'
NICE = 'VDTNiceShared.mm'
MATCH = 'BOOL VDTNiceReceiptBootMatches(NSDictionary *receipt)'
WRITER = 'NSDictionary *VDTNiceReceiptWithBootSession(NSDictionary *receipt)'
PASS = 'PASS native receipt boot readers/store'


def require(okay, message):
    if not okay:
        raise AssertionError(message)


def function_source(source, signature):
    """Exact function bytes, balancing braces outside strings and comments."""
    require(source.count(signature) == 1, 'nonunique/missing function: ' + signature)
    start = source.index(signature)
    brace = source.index('{', start)
    tokens = re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|[{}]', source[brace:])
    depth = 0
    for token in tokens:
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                return source[start:brace + token.end()]
    raise AssertionError('unterminated function: ' + signature)


def gitshow(name):
    return subprocess.check_output(['git', 'show', BASELINE + ':' + name], cwd=ROOT)


def source_contract():
    # This receipt-only test cannot change journal/removal/kernel authority.
    frozen_files = ['VDTNicePolicy.c', 'VDTNicePolicy.h', 'VDTNiceAttempt.h',
                    'VDTNiceStore.c', 'VDTNiceStore.h', 'VDTPolicyTransition.c',
                    'VDTPolicyTransition.h', 'VDTProcessIdentity.c',
                    'VDTProcessIdentity.h', 'nicectl/main.mm']
    for name in frozen_files:
        require((ROOT / name).read_bytes() == gitshow(name), 'frozen policy/helper/store changed: ' + name)
    frozen_functions = {
        NICE: ['NSString *VDTNiceBootToken(void)', 'BOOL VDTNiceParseValue(id value, int *result)',
               'NSDictionary<NSString *, NSDictionary *> *VDTNiceRulesFromPrefs(NSDictionary *prefs)'],
        'VDTNiceRuntime.mm': ['- (void)load {', '- (void)checkRestoreRequest {',
                              '- (int)save:(const VDTNiceRecord *)r target:(NSDictionary *)target {'],
        'VDTResourceRuntime.mm': ['static BOOL resourcePersist(void)', 'static void resourceLoad(void)',
                                  'void vdt_resource_reload(NSDictionary *prefs)'],
        'VDTShared.mm': ['id valueForProcessConfigKeyWithPrefs(NSString *identifier,',
                         'void setValueForProcessConfigKeyWithPrefs(NSString *identifier,',
                         'BOOL VDTProcessConfigHasCPUFields(NSDictionary *entry)'],
    }
    for name, signatures in frozen_functions.items():
        actual, baseline = (ROOT / name).read_text(), gitshow(name).decode()
        for signature in signatures:
            require(function_source(actual, signature) == function_source(baseline, signature),
                    'frozen legacy/CPU/nice function changed: ' + name + ':' + signature)
    for name, signature, variable in [
        (NICE, 'NSDictionary *VDTNiceMatchingStatusWithHost(', 'receipt'),
        ('VDTResourceShared.mm', 'NSDictionary *VDTResourceMatchingStatus(', 'raw'),
    ]:
        body = function_source((ROOT / name).read_text(), signature)
        require('VDTNiceReceiptBootMatches(' + variable + ')' in body,
                'real reader must use boot-session matcher: ' + name)
        require('VDTNiceBootToken()' not in body, 'legacy nil must not preempt UUID: ' + name)
    require('sudo python3 -B tests/test_receipt_boot_native.py --require-native' in
            (ROOT / 'ci/run_host_tests.sh').read_text(), 'missing required native CI gate')
    fixture = FIXTURE.read_text()
    for marker in ['writer-attaches-session', 'same-session-different-boottime',
                   'foreign-session-same-legacy-rejected', 'invalid-session-no-legacy-fallback',
                   'query-failure-no-legacy-fallback', 'invalid-kernel-uuid-no-fallback',
                   'writer-legacy-on-query-failure', 'legacy-read-does-not-rewrite',
                   'nice-revision-still-checked', 'resource-configuration-still-checked',
                   'same-session-status-error-not-success', 'same-session-store-error-not-success',
                   'foreign-session-error-envelope-rejected', 'uuid-readable-without-legacy-token']:
        require('"' + marker + '"' in fixture, 'missing directed assertion: ' + marker)
    print('PASS static receipt contracts (baseline ' + BASELINE + '); NOT native execution', flush=True)


def mutants(source):
    match = function_source(source, MATCH)
    writer = function_source(source, WRITER)
    legacy = '''BOOL VDTNiceReceiptBootMatches(NSDictionary *receipt) {
    if (![receipt isKindOfClass:NSDictionary.class]) return NO;
    id legacy = receipt[@"boot"];
    return [legacy isKindOfClass:NSString.class] && [legacy isEqual:VDTNiceBootToken()];
}'''
    fallback = '''BOOL VDTNiceReceiptBootMatches(NSDictionary *receipt) {
    if (![receipt isKindOfClass:NSDictionary.class]) return NO;
    id session = receipt[@"bootSession"];
    if ([session isKindOfClass:NSString.class] && [session isEqual:niceReceiptBootSession()]) return YES;
    id legacy = receipt[@"boot"];
    return [legacy isKindOfClass:NSString.class] && [legacy isEqual:VDTNiceBootToken()];
}'''
    no_session = WRITER + ' { return receipt; }'
    # All variants retain a real reference to the UUID helper under -Werror.
    # Also detect a preliminary legacy-token guard blocking a readable UUID.
    legacy_gate = match.replace('{', '{\n    if (!VDTNiceBootToken()) return NO;', 1)
    definitions = [
        ('legacy-only', match, legacy, 'same-session-different-boottime'),
        ('session-failure-falls-back', match, fallback, 'foreign-session-same-legacy-rejected'),
        ('writer-omits-session', writer, no_session, 'writer-attaches-session'),
        ('legacy-nil-preempts-uuid', match, legacy_gate, 'uuid-readable-without-legacy-token'),
    ]
    result = []
    for label, old, new, marker in definitions:
        require(source.count(old) == 1 and old != new, 'mutation anchor invalid: ' + label)
        mutated = source.replace(old, new, 1)
        require(mutated != source, 'mutation did not apply: ' + label)
        result.append((label, mutated, marker))
    print('PASS static mutation anchors: ' + ', '.join(m[0] for m in result) + '; NOT kills', flush=True)
    return result


def run(command):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True)


def native(variants):
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix='vdt-receipt-boot-') as directory:
        tmp = Path(directory)
        store = tmp / 'store.o'
        run(['xcrun', 'clang', '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror',
             '-I.', '-c', ROOT / 'VDTNiceStore.c', '-o', store])
        for label, changed, marker in [('baseline', None, None)] + variants:
            defines = []
            if changed is not None:
                # Only the private production copy is mutated, never the tree.
                production = tmp / (label + '.mm')
                production.write_text(changed)
                defines = ['-DVDT_RECEIPT_NICE_FILE="' + str(production) + '"']
            binary = tmp / label
            run(['xcrun', 'clang++', '-std=gnu++98', '-fobjc-arc', '-fblocks', '-O1',
                 '-Wall', '-Wextra', '-Werror', '-Itests/native_stubs', '-I.',
                 *defines, FIXTURE, ROOT / 'VDTShared.mm', store,
                 '-framework', 'Foundation', '-framework', 'CoreFoundation', '-o', binary])
            # A compile/link error above aborts the gate; it is NEVER a kill.
            isolated = tmp / (label + '-data')
            isolated.mkdir(mode=0o700)
            env = dict(os.environ, VDT_RECEIPT_BOOT_TEST_ROOT=str(isolated))
            result = subprocess.run([str(binary)], env=env, cwd=ROOT, capture_output=True, text=True)
            if changed is None:
                require(result.returncode == 0 and result.stdout.strip() == PASS,
                        'native baseline failed:\n' + result.stdout + result.stderr)
                print(result.stdout.strip(), flush=True)
            else:
                expected = 'RECEIPT_BOOT_ASSERT:' + marker
                require(result.returncode != 0 and expected in result.stderr.splitlines(),
                        'mutant survived or failed off-target: ' + label + '\n' + result.stdout + result.stderr)
                print('KILLED native production mutant: ' + label + ' [' + marker + ']', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--static-only', action='store_true', help='no compile or native claims')
    mode.add_argument('--require-native', action='store_true', help='missing Darwin/root is failure')
    args = parser.parse_args()
    source_contract()
    variants = mutants((ROOT / NICE).read_text())
    if args.static_only:
        return 0
    if platform.system() != 'Darwin':
        print('SKIP native receipt boot: requires Darwin/root + Foundation; NOT a native PASS', flush=True)
        return 1 if args.require_native else 77
    if os.geteuid() != 0:
        print('ERROR requires root-owned isolated Store; invoke explicitly with sudo', file=sys.stderr)
        return 1
    native(variants)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        print('FAIL receipt boot regression: ' + str(error), file=sys.stderr)
        sys.exit(1)
