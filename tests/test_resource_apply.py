#!/usr/bin/env python3
"""Run real production C for the M5 apply engine; every behavioral mutant must
compile, then assert-fail. No source freeze/hash is a behavior oracle. No device
or syscall backend participates; the fake backend models measured device
behaviors only to drive scenarios.

Run directly: python3 -B tests/test_resource_apply.py (no Makefile edits).
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
SOURCES = ('VDTResourceApply.c', 'VDTMemoryPolicy.c', 'VDTJetsamPolicy.c',
           'VDTProcessIdentity.c', 'tests/fake_resource_backend.c')
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class ResourceApply(unittest.TestCase):
    def run_kernel(self, texts, test, should_pass):
        with tempfile.TemporaryDirectory(prefix='vdt-apply-') as tmp:
            d = Path(tmp)
            for name, text in texts.items():
                target = d / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
            cc = shlex.split(os.environ.get('CC', 'cc'))
            command = cc + FLAGS + ['-I', str(ROOT), '-I', str(ROOT / 'tests')]
            command += [str(d / p) for p in SOURCES]
            command += [str(ROOT / 'tests' / test), '-o', str(d / 'test')]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=180)
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

    def test_engine_production(self):
        self.run_kernel(self.sources(), 'test_resource_apply.c', True)

    def test_symbol_audit(self):
        engine = (ROOT / 'VDTResourceApply.c').read_text()
        banned = ['memorystatus_control', 'syscall(', 'malloc(', 'calloc(',
                  'realloc(', 'free(', 'posix_spawn', 'kern.max_task']
        for word in banned:
            self.assertNotIn(word, engine, 'engine must stay backend-free: ' + word)
        with tempfile.TemporaryDirectory(prefix='vdt-apply-sym-') as tmp:
            d = Path(tmp)
            cc = shlex.split(os.environ.get('CC', 'cc'))
            command = cc + FLAGS + ['-I', str(ROOT), '-c', str(ROOT / 'VDTResourceApply.c'),
                                    '-o', str(d / 'engine.o')]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            nm = shutil.which('nm')
            if nm is None:
                self.skipTest('nm unavailable; object compile check only')
            listing = subprocess.run([nm, '-u', str(d / 'engine.o')],
                                     capture_output=True, text=True, timeout=60)
            self.assertEqual(listing.returncode, 0, listing.stderr)
            symbols = {line.split()[-1] for line in listing.stdout.splitlines() if line.strip()}
            # Only intended project-internal imports may appear: the frozen
            # policy cores and the identity comparator. Anything OS-level,
            # syscall-level or allocation-level must be absent.
            allowed = {'memset', 'memcpy', '__stack_chk_fail', '__stack_chk_guard',
                       'VDTPlanMemoryRule', 'VDTPlanJetsamRule', 'VDTProcessInstanceMatches'}
            self.assertLessEqual(symbols, allowed,
                                 'unexpected undefined symbols: ' + str(sorted(symbols - allowed)))

    def test_cpp_headers(self):
        cpp = shlex.split(os.environ.get('CXX', 'clang++'))
        if not cpp or not shutil.which(cpp[0]):
            self.skipTest('C++ compiler unavailable; no installation attempted')
        code = '''#include "VDTResourceApply.h"
#include "VDTResourceBackend.h"
static_assert(VDT_RESOURCE_APPLY_ABI_VERSION == 1, "abi");
static_assert(VDT_APPLY_MAX_OPS == 2, "ops");
int main() {
    VDTApplyCapabilities caps = {false, false, false, false};
    return caps.writeMemoryCustom ? 1 : 0;
}
'''
        compiled = subprocess.run(cpp + ['-std=c++11', '-Wall', '-Wextra', '-Werror',
                                         '-pedantic', '-fsyntax-only', '-x', 'c++', '-I', str(ROOT), '-'],
                                  input=code, capture_output=True, text=True, timeout=120)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)

    def test_mutants(self):
        source = 'VDTResourceApply.c'
        mutations = [
            ('R01 custom capability gate ignored',
             'if (!capabilities.writeMemoryCustom) {', 'if (false) {'),
            ('R02 unlimited limit becomes -1',
             'const int32_t limit = VDT_APPLY_UNLIMITED_LIMIT;', 'const int32_t limit = -1;'),
            ('R03 unlimited attrs become FATAL',
             'const int32_t attrs = VDT_APPLY_UNLIMITED_ATTRS;', 'const int32_t attrs = 1;'),
            ('R04 restore writes zeros',
             'const VDTMemlimitPair expected = restore ? target->priorPair : op->pair;',
             'const VDTMemlimitPair expected = restore ? (VDTMemlimitPair){0, 0, 0, 0} : op->pair;'),
            ('R05 identity match bypass',
             'VDTProcessInstanceMatches(target->expected, token);', 'true;'),
            ('R06 builder order swapped',
             '    if (hasPriority) program.ops[count++] = priorityValue;\n'
             '    if (hasMemory) program.ops[count++] = memoryValue;',
             '    if (hasMemory) program.ops[count++] = memoryValue;\n'
             '    if (hasPriority) program.ops[count++] = priorityValue;'),
            ('R07 abort after priority failure',
             '    for (unsigned i = 0; i < program->opCount; ++i) {',
             '    for (unsigned i = 0; i < program->opCount; ++i) { '
             'if (report.jetsamOutcome == VDTApplyOutcomeFailed) break;'),
            ('R08 partial flag forced false',
             'report.partial = wantsMemory && wantsPriority &&', 'report.partial = false &&'),
            ('R09 unlimited capability gate ignored',
             'if (!capabilities.writeMemoryUnlimited) {', 'if (false) {'),
            ('R10 mixed unlimited side accepted',
             'rule->inactive.mode == VDTMemoryModeUnlimited',
             'rule->inactive.mode != VDTMemoryModeInvalid'),
            ('R11 jetsam capability gate ignored',
             'if (!capabilities.writeJetsamBand) {', 'if (false) {'),
            ('R12 memory pre-read failure ignored',
             'if (!backend->getMemlimit(backendContext, program->pid, &before)) {', 'if (false) {'),
            ('R13 priority pre-read failure ignored',
             'if (!backend->getPriority(backendContext, program->pid, &before)) {', 'if (false) {'),
            ('R14 post identity check bypass',
             'VDTProcessInstanceMatches(target->expected, after);', 'true;'),
            ('R15 verified flag ignored',
             'report.jetsamOutcome = report.jetsamVerified\n'
             '                    ? VDTApplyOutcomeApplied : VDTApplyOutcomeAppliedUnverified;',
             'report.jetsamOutcome = VDTApplyOutcomeApplied;'),
        ]
        originals = self.sources()
        for label, old, new in mutations:
            with self.subTest(mutant=label):
                text = originals[source]
                self.assertEqual(text.count(old), 1, 'ambiguous mutation target: ' + label)
                texts = dict(originals)
                texts[source] = text.replace(old, new, 1)
                ran = self.run_kernel(texts, 'test_resource_apply.c', False)
                assertion = ran.stderr.strip().splitlines()[-1]
                print('KILLED ' + label + ' (compiled; exit ' + str(ran.returncode) + '): ' + assertion,
                      flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
