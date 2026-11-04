#!/usr/bin/env python3
"""Contract tests for ci/stage_symbols.py and ci/verify_symbols.py.

The point of these tools is that a symbols problem can never silently ship a
false "ok" and never cost the installable deb, so the tests pin exactly that:
images are read but never modified, a missing dsymutil is a skip unless the
caller demands symbols, an empty DWARF bundle is not counted as success, and the
verifier rejects a bundle whose functions do not resolve.

dsymutil cannot run on a non-Darwin host, so every test drives the tool through
a stub whose success/failure is scripted per image name.
"""
from pathlib import Path
import hashlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / 'ci/stage_symbols.py'
VERIFY = ROOT / 'ci/verify_symbols.py'

STUB_DSYMUTIL = r'''
import os, sys
image, flag, out = sys.argv[1], sys.argv[2], sys.argv[3]
name = os.path.basename(image)
mode = os.environ.get('STUB_MODE', 'ok')
fail = os.environ.get('STUB_FAIL', '')
if fail and fail in name:
    sys.stderr.write('error: no debug map in ' + name + '\n')
    sys.exit(1)
dwarf = os.path.join(out, 'Contents/Resources/DWARF')
os.makedirs(dwarf, exist_ok=True)
payload = os.path.join(dwarf, name)
if mode != 'empty':
    with open(payload, 'wb') as handle:
        handle.write(b'\xcf\xfa\xed\xfe' + b'\x00' * 4092)
'''

STUB_DWARFDUMP = r'''
import os, sys
mode = os.environ.get('STUB_DWARFDUMP', 'ok')
args = [a for a in sys.argv[1:]]
if '--uuid' in args:
    if mode == 'noid':
        sys.exit(0)
    print('UUID: 0123ABCD-4567-89AB-CDEF-0123456789AB (arm64e) ' + args[-1])
    sys.exit(0)
if '--lookup' in args:
    symbol = args[args.index('--lookup') + 1]
    if mode == 'unknown' and symbol == '_main':
        print('Looking up ' + symbol)
        sys.exit(0)
    print('Looking up ' + symbol)
    print('  DW_TAG_subprogram')
    print('    DW_AT_name ("' + symbol + '")')
    sys.exit(0)
sys.exit(2)
'''


class StageSymbols(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.writes = []

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, body):
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding='utf-8')
        self.writes.append(path)
        return path

    def run_stage(self, objects, out, extra=(), env=None):
        command = [sys.executable, '-B', str(STAGE), '--out', str(out)]
        for root in objects:
            command += ['--objects', str(root)]
        command += list(extra)
        merged = dict(os.environ)
        merged.update(env or {})
        return subprocess.run(command, capture_output=True, text=True, env=merged)

    def image_tree(self):
        obj = self.tmp / 'obj'
        self.write('obj/Vedette.dylib', 'linked image')
        self.write('obj/VedettePrefs.bundle/VedettePrefs', 'bundle image')
        self.write('obj/vedette-nicectl', 'tool image')
        return obj

    def test_stages_one_bundle_per_product_and_never_touches_the_images(self):
        obj = self.image_tree()
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.writes}
        stub = self.write('dsymutil.py', STUB_DSYMUTIL)
        out = self.tmp / 'symbols'
        result = self.run_stage([obj], out, ['--dsymutil', '%s %s' % (sys.executable, stub)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        produced = sorted(p.name for p in out.glob('*.dSYM'))
        self.assertEqual(produced, ['Vedette.dylib.dSYM', 'VedettePrefs.dSYM', 'vedette-nicectl.dSYM'])
        after = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.writes if p.name != 'dsymutil.py'}
        self.assertEqual(before, {k: v for k, v in after.items() if k in before})

    def test_empty_dwarf_is_not_success_and_require_makes_it_fatal(self):
        obj = self.image_tree()
        stub = self.write('dsymutil.py', STUB_DSYMUTIL)
        out = self.tmp / 'symbols'
        env = {'STUB_MODE': 'empty'}
        soft = self.run_stage([obj], out, ['--dsymutil', '%s %s' % (sys.executable, stub)], env)
        self.assertEqual(soft.returncode, 0, soft.stdout + soft.stderr)
        self.assertIn('0/3 image(s) have symbols', soft.stdout)
        self.assertEqual(list(out.glob('*.dSYM')), [])
        hard = self.run_stage([obj], out, ['--dsymutil', '%s %s' % (sys.executable, stub),
                                           '--require'], env)
        self.assertEqual(hard.returncode, 1)

    def test_missing_dsymutil_skips_without_failing_the_package(self):
        obj = self.image_tree()
        out = self.tmp / 'symbols'
        merged = {'PATH': '', 'SystemRoot': os.environ.get('SystemRoot', '')}
        soft = self.run_stage([obj], out, env=merged)
        self.assertEqual(soft.returncode, 0, soft.stdout + soft.stderr)
        self.assertIn('dsymutil not available', soft.stdout)
        hard = self.run_stage([obj], out, ['--require'], env=merged)
        self.assertEqual(hard.returncode, 1)

    def test_one_failed_image_does_not_hide_the_others(self):
        obj = self.image_tree()
        stub = self.write('dsymutil.py', STUB_DSYMUTIL)
        out = self.tmp / 'symbols'
        result = self.run_stage([obj], out, ['--dsymutil', '%s %s' % (sys.executable, stub)],
                                {'STUB_FAIL': 'nicectl'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('2/3 image(s) have symbols', result.stdout)
        self.assertIn('skipped', result.stdout)
        self.assertFalse((out / 'vedette-nicectl.dSYM').exists())

    def test_no_images_is_reported_not_guessed(self):
        empty = self.tmp / 'obj'
        empty.mkdir()
        result = self.run_stage([empty], self.tmp / 'symbols')
        self.assertEqual(result.returncode, 0)
        self.assertIn('no packaged image', result.stdout)


class VerifySymbols(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stub = self.tmp / 'dwarfdump.py'
        self.stub.write_text(STUB_DWARFDUMP, encoding='utf-8')

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def bundle(self, name, size=64):
        dwarf = self.tmp / 'symbols' / name / 'Contents/Resources/DWARF'
        dwarf.mkdir(parents=True, exist_ok=True)
        (dwarf / name.replace('.dSYM', '')).write_bytes(b'\x00' * size)

    def run_verify(self, env=None):
        merged = dict(os.environ)
        merged['DWARFDUMP'] = '%s %s' % (sys.executable, self.stub)
        merged.update(env or {})
        return subprocess.run([sys.executable, '-B', str(VERIFY), str(self.tmp / 'symbols')],
                              capture_output=True, text=True, env=merged)

    def test_accepts_bundles_that_name_the_crash_probe(self):
        self.bundle('Vedette.dylib.dSYM')
        self.bundle('vedette-nicectl.dSYM')
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('2 bundle(s) verified', result.stdout)
        self.assertIn('resolved _VDTReadExtensionBundleInfo', result.stdout)

    def test_rejects_bundle_without_uuid_or_with_unresolved_function(self):
        self.bundle('Vedette.dylib.dSYM')
        missing = self.run_verify({'STUB_DWARFDUMP': 'unknown'})
        self.assertEqual(missing.returncode, 0, 'prefs bundle is optional')

        self.bundle('vedette-nicectl.dSYM')
        unknown = self.run_verify({'STUB_DWARFDUMP': 'unknown'})
        self.assertEqual(unknown.returncode, 1)
        self.assertIn('does not resolve to a function', unknown.stdout)

        no_uuid = self.run_verify({'STUB_DWARFDUMP': 'noid'})
        self.assertEqual(no_uuid.returncode, 1)
        self.assertIn('no UUID', no_uuid.stdout)

    def test_empty_directory_fails(self):
        (self.tmp / 'symbols').mkdir()
        result = self.run_verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn('no .dSYM', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
