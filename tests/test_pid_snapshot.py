#!/usr/bin/env python3
"""Execute the production header-only PID kernel with portable fake callbacks.

No libproc, Foundation, process metadata, device commands or freeze fixture is
involved. Runtime mutants must compile and then fail an assertion, not merely
fail compilation. Separate source checks pin the checked API's production seam.

Run: python3 -B tests/test_pid_snapshot.py --require-compiler
CC accepts an executable path (including Windows spaces) or a shlex command
prefix. CXX is optional and checks portable C++11 object compilation only (no
linking). Without --require-compiler, a missing C compiler is an explicit skip,
never validation.
"""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FLAGS = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic']
REQUIRE_COMPILER = '--require-compiler' in sys.argv
if REQUIRE_COMPILER:
    sys.argv.remove('--require-compiler')


def command_words(value):
    # A literal path needs no shell splitting; preserve Windows backslashes and
    # spaces. For a command prefix, Windows shlex retains enclosing quotes.
    if Path(value).is_file():
        return [str(Path(value).resolve())]
    words = shlex.split(value, posix=os.name != 'nt')
    if os.name == 'nt':
        words = [word[1:-1] if len(word) >= 2 and word[0] == word[-1] and
                 word[0] in ('"', "'") else word for word in words]
    return words


def compiler_command(variable, defaults):
    configured = os.environ.get(variable, '').strip()
    if configured:
        words = command_words(configured)
        if not words:
            raise AssertionError(variable + ' contains no compiler command')
        if Path(words[0]).is_file():
            words[0] = str(Path(words[0]).resolve())
        return words
    for name in defaults:
        found = shutil.which(name)
        if found:
            return [found]
    return None


def function_source(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError('unterminated function: ' + signature)


class PIDSnapshotKernel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = compiler_command('CC', ('cc', 'clang', 'gcc', 'tcc'))
        if cls.cc is None:
            if REQUIRE_COMPILER:
                raise AssertionError('C compiler required but unavailable; no installation attempted')
            raise unittest.SkipTest('C compiler unavailable; no installation attempted')
        cls.header = (ROOT / 'VDTPIDSnapshot.h').read_text(encoding='utf-8')
        cls.test_source = (ROOT / 'tests/test_pid_snapshot.c').read_bytes()

    def run_kernel(self, header, should_pass):
        with tempfile.TemporaryDirectory(prefix='vdt-pid-snapshot-') as tmp:
            directory = Path(tmp)
            (directory / 'VDTPIDSnapshot.h').write_text(header, encoding='utf-8')
            (directory / 'test.c').write_bytes(self.test_source)
            executable = directory / ('test.exe' if os.name == 'nt' else 'test')
            command = self.cc + FLAGS + ['-I', str(directory), str(directory / 'test.c'),
                                        '-o', str(executable)]
            compiled = subprocess.run(command, cwd=directory, capture_output=True,
                                      text=True, errors='replace', timeout=120)
            self.assertEqual(compiled.returncode, 0,
                             'COMPILE FAILURE (not a behavioral mutant kill):\n' +
                             compiled.stdout + compiled.stderr)
            ran = subprocess.run([str(executable)], cwd=directory, capture_output=True,
                                 text=True, errors='replace', timeout=30)
            if should_pass:
                self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
                self.assertIn('PASS production PID snapshot:', ran.stdout)
                print(ran.stdout.strip(), flush=True)
            else:
                self.assertNotEqual(ran.returncode, 0, 'mutant survived the production C suite')
                self.assertIn('assert', ran.stderr.lower(),
                              'failure was not an assertion:\n' + ran.stdout + ran.stderr)
            return ran

    def test_production_kernel(self):
        self.run_kernel(self.header, True)

    def test_behavioral_mutants(self):
        mutations = [
            ('full buffer falsely complete',
             'if ((size_t)writtenBytes < capacityBytes) {',
             'if ((size_t)writtenBytes <= capacityBytes) {'),
            ('byte count used as element count',
             'snapshot.count = (size_t)writtenBytes / sizeof(int);',
             'snapshot.count = (size_t)writtenBytes;'),
            ('zero query error ignored',
             'if (queryBytes < 0 || scanError != 0) {',
             'if (queryBytes < 0) {'),
            ('zero read error ignored',
             'if (writtenBytes < 0 || scanError != 0) {',
             'if (writtenBytes < 0) {'),
            ('misaligned read accepted',
             'if ((size_t)writtenBytes % sizeof(int) != 0 ||\n'
             '            (size_t)writtenBytes > capacityBytes) {',
             'if ((size_t)writtenBytes > capacityBytes) {'),
            ('retry bound exceeded',
             'attempt < VDTPIDSnapshotReadLimit; ++attempt',
             'attempt < VDTPIDSnapshotReadLimit + 1; ++attempt'),
            ('allocation bound doubled',
             'size_t maxCapacity = (size_t)VDTPIDSnapshotMaxPIDs;',
             'size_t maxCapacity = (size_t)VDTPIDSnapshotMaxPIDs * 2;'),
            ('PID buffer not initialised',
             'memset(buffer, 0, capacityBytes);',
             'memset(buffer, 0, 0);'),
        ]
        for label, old, new in mutations:
            with self.subTest(mutant=label):
                self.assertEqual(self.header.count(old), 1, 'ambiguous mutation target: ' + label)
                ran = self.run_kernel(self.header.replace(old, new, 1), False)
                assertion = ran.stderr.strip().splitlines()[-1]
                print('KILLED ' + label + ' (compiled; exit ' + str(ran.returncode) + '): ' +
                      assertion, flush=True)

    def test_cpp_header_syntax(self):
        cpp = compiler_command('CXX', ('clang++', 'g++'))
        if cpp is None:
            self.skipTest('C++ compiler unavailable; no installation attempted')
        code = '''#include "VDTPIDSnapshot.h"
static_assert(VDTPIDSnapshotReadLimit == 6, "bounded reads");
static_assert(VDTPIDSnapshotMaxPIDs == 65536, "bounded allocation");
int main() {
    VDTPIDSnapshot snapshot = VDTCopyPIDSnapshot(NULL);
    return snapshot.complete || snapshot.error != EINVAL;
}
'''
        with tempfile.TemporaryDirectory(prefix='vdt-pid-cpp-') as tmp:
            directory = Path(tmp)
            source = directory / 'header.cpp'
            object_file = directory / 'header.o'
            source.write_text(code, encoding='utf-8')
            compiled = subprocess.run(cpp + ['-std=c++11', '-Wall', '-Wextra', '-Werror',
                                             '-pedantic', '-c', '-I', str(ROOT), str(source),
                                             '-o', str(object_file)],
                                      cwd=directory, capture_output=True, text=True,
                                      errors='replace', timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            self.assertTrue(object_file.is_file(), 'C++ compile produced no object file')
            self.assertGreater(object_file.stat().st_size, 0, 'C++ compile produced an empty object')
        print('PASS portable C++11 PID header compilation (nonempty object; no Apple/Foundation link)',
              flush=True)


class PIDSnapshotProductionWiring(unittest.TestCase):
    def assert_resource_identity_contract(self, manager, header):
        for key, value in (('VDTTargetResourceTypeKey', 'resourceType'),
                           ('VDTTargetResourceNameKey', 'resourceName')):
            self.assertIn('extern NSString * const ' + key + ';', header)
            self.assertIn('NSString * const ' + key + ' = @"' + value + '";', manager)
        target = function_source(manager, 'static NSDictionary *target_for_pid(')
        # CPU source identity and the existing resource-only fallback stay intact.
        for token in ('NSNumber *typeValue = vdt_number(matched[VDTConfigTypeKey]);',
                      'if (matched || !hasResourceIntent || !resourceIdentityType) return nil;',
                      'typeValue = resourceIdentityType;', 'enabledValue = @NO;',
                      'VDTTargetNameKey: matchedName ?: resourceIdentityName ?: @"",',
                      'VDTConfigTypeKey: typeValue,'):
            self.assertIn(token, target)
        # An inherited CPU App target still needs its real Extension namespace
        # after both resource rows are removed; do not gate metadata on intent.
        guard = 'if (resourceIdentityType && resourceIdentityName)'
        self.assertIn(guard + ' {', target)
        metadata = function_source(target, guard)
        self.assertNotIn('hasResourceIntent', metadata)
        self.assertIn('target[VDTTargetResourceTypeKey] = resourceIdentityType;', metadata)
        self.assertIn('target[VDTTargetResourceNameKey] = resourceIdentityName;', metadata)
        self.assertNotIn('VDTConfigTypeKey', metadata)
        self.assertNotIn('VDTTargetNameKey', metadata)
        self.assertNotIn('typeValue', metadata)
        self.assertNotIn('matchedName', metadata)
        for token in ('if (memoryRule) target[VDTTargetMemoryRuleKey] = memoryRule;',
                      'if (jetsamRule) target[VDTTargetJetsamRuleKey] = jetsamRule;'):
            self.assertLess(target.index(token), target.index(guard))
        after_metadata = target[target.index(metadata) + len(metadata):]
        self.assertEqual(after_metadata, '\n    return target;\n}')

    def test_resource_metadata_preserves_cpu_identity(self):
        manager = (ROOT / 'VDTProcessManager.mm').read_text(encoding='utf-8')
        header = (ROOT / 'VDTProcessManager.h').read_text(encoding='utf-8')
        self.assert_resource_identity_contract(manager, header)

    def test_cpu_resource_namespace_swaps_are_rejected(self):
        manager = (ROOT / 'VDTProcessManager.mm').read_text(encoding='utf-8')
        header = (ROOT / 'VDTProcessManager.h').read_text(encoding='utf-8')
        changes = [
            ('resource type overwrites CPU type',
             'target[VDTTargetResourceTypeKey] = resourceIdentityType;',
             'target[VDTConfigTypeKey] = resourceIdentityType;'),
            ('resource name overwrites CPU name',
             'target[VDTTargetResourceNameKey] = resourceIdentityName;',
             'target[VDTTargetNameKey] = resourceIdentityName;'),
            ('CPU type mistaken for resource type',
             'target[VDTTargetResourceTypeKey] = resourceIdentityType;',
             'target[VDTTargetResourceTypeKey] = typeValue;'),
            ('CPU name mistaken for resource name',
             'target[VDTTargetResourceNameKey] = resourceIdentityName;',
             'target[VDTTargetResourceNameKey] = matchedName;'),
            ('removed resource rows suppress real resource identity',
             'if (resourceIdentityType && resourceIdentityName) {',
             'if (hasResourceIntent && resourceIdentityType && resourceIdentityName) {'),
        ]
        for label, old, new in changes:
            with self.subTest(negative=label):
                self.assertEqual(manager.count(old), 1, 'ambiguous source mutation: ' + label)
                with self.assertRaises(AssertionError):
                    self.assert_resource_identity_contract(manager.replace(old, new, 1), header)

    def test_checked_api_and_compatibility_wrapper(self):
        header = (ROOT / 'VDTProcessManager.h').read_text(encoding='utf-8')
        manager = (ROOT / 'VDTProcessManager.mm').read_text(encoding='utf-8')
        signature = ('NSArray<NSDictionary *>* vdt_resolve_targets_checked('
                     'NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules, '
                     'BOOL *outScanComplete, int *outScanError)')
        self.assertIn(signature + ';', header)
        self.assertIn('PID enumeration ONLY', header)
        self.assertIn('#import "VDTPIDSnapshot.h"', manager)
        checked = function_source(manager, signature)
        for output in ('if (outScanComplete) *outScanComplete = NO;',
                       'if (outScanError) *outScanError = 0;'):
            self.assertLess(checked.index(output), checked.index('if (configs.count'))
        for token in ('.listPIDs = pid_snapshot_list,', '.allocate = pid_snapshot_allocate,',
                      '.deallocate = pid_snapshot_deallocate,',
                      'VDTPIDSnapshot snapshot = VDTCopyPIDSnapshot(&operations);',
                      'if (outScanComplete) *outScanComplete = snapshot.complete ? YES : NO;',
                      'if (outScanError) *outScanError = snapshot.error;',
                      'if (!snapshot.complete) return @[];',
                      'pid_t pid = (pid_t)snapshot.pids[idx];',
                      'if (pid <= 0) continue;',
                      'target_for_pid(pid, appConfigsById, extensionConfigsById, daemonConfigs, resourceMaps)',
                      'if (snapshot.pids) operations.deallocate(snapshot.pids, operations.context);'):
            self.assertIn(token, checked)
        self.assertLess(checked.index('if (!snapshot.complete) return @[];'),
                        checked.index('target_for_pid('))
        self.assertNotIn('proc_listpids(', checked) # All scan behavior uses the tested kernel.
        self.assertNotIn('nice_target_for_pid', checked)
        wrapper = function_source(manager, 'NSArray<NSDictionary *>* vdt_resolve_targets(')
        self.assertIn('return vdt_resolve_targets_checked(configs, resourceRules, NULL, NULL);', wrapper)

    def test_libproc_adapter_captures_error_immediately(self):
        manager = (ROOT / 'VDTProcessManager.mm').read_text(encoding='utf-8')
        adapter = function_source(manager, 'static int pid_snapshot_list(')
        self.assertLess(adapter.index('errno = 0;'), adapter.index('proc_listpids('))
        self.assertIn('proc_listpids(PROC_ALL_PIDS, 0, buffer, capacityBytes);', adapter)
        self.assertIn('*outError = bytes <= 0 ? errno : 0;', adapter)
        self.assertIn('return bytes;', adapter)


if __name__ == '__main__':
    unittest.main(verbosity=2)
