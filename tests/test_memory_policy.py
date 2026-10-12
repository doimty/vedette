#!/usr/bin/env python3
"""Run real production C; every behavioral mutant must compile, then assert-fail.

No source freeze/hash is a behavior oracle. No device or syscall backend exists.
Run directly: python3 -B tests/test_memory_policy.py (no Makefile edits required).
"""
from pathlib import Path
import os
import resource
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FLAGS = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic']
SOURCES = ('VDTMemoryPolicy.c', 'VDTJetsamPolicy.c')
# Avoid core dumps from intentional assertion failures in isolated mutants.
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class MemoryPolicyCore(unittest.TestCase):
    def run_kernel(self, texts, test, should_pass):
        with tempfile.TemporaryDirectory(prefix='vdt-memory-core-') as tmp:
            d = Path(tmp)
            for name, text in texts.items():
                (d / name).write_text(text)
            cc = shlex.split(os.environ.get('CC', 'cc'))
            command = cc + FLAGS + ['-I', str(ROOT)] + [str(d / p) for p in SOURCES]
            command += [str(ROOT / 'tests' / test), '-o', str(d / 'test')]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0,
                             'COMPILE FAILURE (not a killed mutant):\n' + compiled.stdout + compiled.stderr)
            ran = subprocess.run([str(d / 'test')], cwd=d, capture_output=True, text=True, timeout=30)
            if should_pass:
                self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
                print(ran.stdout.strip(), flush=True)
            else:
                self.assertNotEqual(ran.returncode, 0, 'mutant survived behavioral suite')
                self.assertIn('assert', ran.stderr.lower(), 'failure was not an assertion: ' + ran.stderr)
            return ran

    def sources(self):
        return {name: (ROOT / name).read_text() for name in SOURCES}

    def test_memory_production(self):
        self.run_kernel(self.sources(), 'test_memory_policy.c', True)

    def test_jetsam_production(self):
        self.run_kernel(self.sources(), 'test_jetsam_policy.c', True)

    def test_cpp_headers(self):
        cpp = shlex.split(os.environ.get('CXX', 'clang++'))
        if not cpp or not shutil.which(cpp[0]):
            self.skipTest('C++ compiler unavailable; no installation attempted')
        code = '''#include "VDTMemoryPolicy.h"
#include "VDTJetsamPolicy.h"
static_assert(VDT_RESOURCE_POLICY_SCHEMA_VERSION == 1, "schema");
static_assert(VDTPolicyRecordMissing != VDTPolicyRecordDisabled, "presence");
int main() {
    VDTPolicyInteger value = {VDTPolicyInputInteger, -1};
    VDTMemoryLimit memory = {VDTMemoryModeInvalid, 0};
    return static_cast<int>(VDTParseMemoryLimit(value, &memory));
}
'''
        compiled = subprocess.run(cpp + ['-std=c++11', '-Wall', '-Wextra', '-Werror',
                                        '-pedantic', '-fsyntax-only', '-x', 'c++', '-I', str(ROOT), '-'],
                                  input=code, capture_output=True, text=True, timeout=120)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        print('C++11 public headers PASS (syntax only, not Apple link)', flush=True)

    def test_effective_mutants(self):
        memory = 'VDTMemoryPolicy.c'; jetsam = 'VDTJetsamPolicy.c'
        mutations = [
            ('M01 unlimited raw -1 passthrough', memory, 'test_memory_policy.c',
             '''        plan.status = VDTPolicyPlanUnsupported;
        plan.reason = VDTPolicyReasonUnlimitedUnverified;
        return plan;''',
             '''        plan.status = VDTPolicyPlanReady;
        plan.reason = VDTPolicyReasonNone;
        plan.hasCustomPair = true;
        plan.activeMiB = rule->active.mode == VDTMemoryModeUnlimited ? -1 : rule->active.mib;
        plan.inactiveMiB = rule->inactive.mode == VDTMemoryModeUnlimited ? -1 : rule->inactive.mib;
        return plan;'''),
            ('M02 System becomes idle band 0', jetsam, 'test_jetsam_policy.c',
             '''    if (rule->state == VDTPolicyRecordMissing || rule->state == VDTPolicyRecordDisabled ||
        rule->mode == VDTJetsamModeSystem) {''',
             '''    if (rule->state == VDTPolicyRecordEnabled && rule->mode == VDTJetsamModeSystem) {
        plan.status = VDTPolicyPlanReady;
        plan.reason = VDTPolicyReasonNone;
        plan.hasBand = true;
        plan.bandClass = VDTJetsamBandNamedDefined;
        plan.band = 0;
        return plan;
    }
    if (rule->state == VDTPolicyRecordMissing || rule->state == VDTPolicyRecordDisabled) {'''),
            ('M03 mechanical raw division by 10', jetsam, 'test_jetsam_policy.c',
             '        band = rule->rawBand;', '        band = rule->rawBand / 10;'),
            ('M04 ignore raw source version', jetsam, 'test_jetsam_policy.c',
             '        if (rule->rawSourceDarwinMajor != targetDarwinMajor) {',
             '        if (rule->rawSourceDarwinMajor < 0) {'),
            ('M05 unsupported reported Ready', memory, 'test_memory_policy.c',
             '''        plan.status = VDTPolicyPlanUnsupported;
        plan.reason = VDTPolicyReasonUnlimitedUnverified;''',
             '''        plan.status = VDTPolicyPlanReady;
        plan.reason = VDTPolicyReasonUnlimitedUnverified;'''),
            ('M06 explicit off falls back to App', memory, 'test_memory_policy.c',
             '    if (extension != VDTPolicyRecordMissing) {',
             '    if (extension != VDTPolicyRecordMissing && extension != VDTPolicyRecordDisabled) {'),
            ('M07 invalid override falls back to App', memory, 'test_memory_policy.c',
             '    if (extension != VDTPolicyRecordMissing) {',
             '    if (extension != VDTPolicyRecordMissing && extension != VDTPolicyRecordInvalid) {'),
            ('M08 CPU override leaks into memory', memory, 'test_memory_policy.c',
             '    result.memory = VDTSelectResourceRule(extensionIdentityValid, app.memory, extension.memory);',
             '    result.memory = VDTSelectResourceRule(extensionIdentityValid, app.memory, extension.cpu);'),
            ('M09 weaken extension identity gate', memory, 'test_memory_policy.c',
             '    if (!extensionIdentityValid) {',
             '    if (!extensionIdentityValid && extension == VDTPolicyRecordMissing) {'),
            ('M10 discard prior-override evidence', memory, 'test_memory_policy.c',
             '        priorOverride, false, 0, 0};', '        false, false, 0, 0};'),
            ('M11 enable unknown Darwin25', memory, 'test_jetsam_policy.c',
             '    return major == 21 || major == 22 || major == 23 || major == 24;',
             '    return major == 21 || major == 22 || major == 23 || major == 24 || major == 25;'),
            ('M12 accept boolean as integer', memory, 'test_memory_policy.c',
             '    if (input.tag != VDTPolicyInputInteger) return VDTPolicyParseInvalidType;',
             '    if (input.tag != VDTPolicyInputInteger && input.tag != VDTPolicyInputBoolean) return VDTPolicyParseInvalidType;'),
            ('M13 all unnamed gaps are safe bands', jetsam, 'test_jetsam_policy.c',
             '    return VDTJetsamBandUnnamedAdvanced;', '    return VDTJetsamBandNamedDefined;'),
            ('M14 permit internal999', jetsam, 'test_jetsam_policy.c',
             '    if (band == 999) return VDTJetsamBandInternal;',
             '    if (band == 999) return VDTJetsamBandNamedDefined;'),
            ('M15 corrupt modern home mapping', jetsam, 'test_jetsam_policy.c',
             '    {VDTJetsamNamedHome, 16, 160, 21, VDTJetsamBandNamedDefined},',
             '    {VDTJetsamNamedHome, 16, 16, 21, VDTJetsamBandNamedDefined},'),
        ]
        originals = self.sources()
        for label, source, suite, old, new in mutations:
            with self.subTest(mutant=label):
                self.assertEqual(originals[source].count(old), 1, 'ambiguous mutation target: ' + label)
                texts = dict(originals)
                texts[source] = texts[source].replace(old, new, 1)
                ran = self.run_kernel(texts, suite, False)
                assertion = ran.stderr.strip().splitlines()[-1]
                print('KILLED ' + label + ' (compiled; exit ' + str(ran.returncode) + '): ' + assertion,
                      flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
