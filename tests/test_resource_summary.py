#!/usr/bin/env python3
"""Execute actual portable confirmation/restore selection C; no device/native claims."""
from pathlib import Path
import os, subprocess, tempfile, unittest
import test_pid_snapshot as compiler
ROOT = Path(__file__).resolve().parents[1]

class ResourceSummaryKernel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = compiler.compiler_command('CC', ('cc', 'clang', 'gcc'))
        if cls.cc is None:
            if compiler.REQUIRE_COMPILER:
                raise AssertionError('C compiler required but unavailable')
            raise unittest.SkipTest('C compiler unavailable; not validated')
        cls.header = (ROOT/'VDTResourceSummary.h').read_text(encoding='utf-8')
        cls.fixture = (ROOT/'tests/test_resource_summary.c').read_bytes()

    def execute(self, text, good):
        with tempfile.TemporaryDirectory(prefix='vdt-summary-') as name:
            path = Path(name)
            (path/'VDTResourceSummary.h').write_text(text, encoding='utf-8')
            (path/'fixture.c').write_bytes(self.fixture)
            target = path/('fixture.exe' if os.name == 'nt' else 'fixture')
            result = subprocess.run(self.cc + compiler.FLAGS + ['-I',str(path),str(path/'fixture.c'),'-o',str(target)],
                cwd=path,capture_output=True,text=True,errors='replace',timeout=120)
            self.assertEqual(result.returncode,0,'COMPILE FAILURE, not a mutant kill:\n'+result.stderr)
            result = subprocess.run([str(target)],cwd=path,capture_output=True,text=True,errors='replace',timeout=30)
            if good:
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('PASS production resource summary',result.stdout)
                print(result.stdout.strip(),flush=True)
            else:
                self.assertNotEqual(result.returncode,0,'behavioral mutant survived')
                self.assertIn('assert',result.stderr.lower(),result.stderr)
            return result

    def test_production_counts_and_authority(self):
        self.execute(self.header,True)

    def test_compiled_targeted_mutants(self):
        changes = [
            ('multi-always-partial','if (confirmed == value.total)',
             'if (value.total > 1u && confirmed == value.total) return VDTResourceSummaryPartial;\n    if (confirmed == value.total)'),
            ('ignore-count-sum','sum == value.total','(sum == value.total || true)'),
            ('invent-confirmed-count','? value.applied + value.restored : 0','? value.total : 0'),
            ('unknown-as-confirmed','if (value.unknown) return VDTResourceSummaryUnknown;',
             'if (value.unknown) return VDTResourceSummaryConfirmed;'),
            ('restore-without-revocation','authorizedGlobalRevocation || memory == VDTResourceIntentRevoke',
             'authorizedGlobalRevocation || memory == VDTResourceIntentRevoke || true'),
            ('revoke-other-resource','authorizedGlobalRevocation || priority == VDTResourceIntentRevoke',
             'authorizedGlobalRevocation || memory == VDTResourceIntentRevoke || priority == VDTResourceIntentRevoke')]
        for label,old,new in changes:
            with self.subTest(mutant=label):
                self.assertEqual(self.header.count(old),1,'ambiguous mutation: '+label)
                result = self.execute(self.header.replace(old,new,1),False)
                print('KILLED compiled summary mutant:',label,'exit',result.returncode,flush=True)

if __name__ == '__main__': unittest.main(verbosity=2)
