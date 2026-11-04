#!/usr/bin/env python3
"""Contract tests for ci/collect_symbols.py and ci/verify_symbols.py.

Theos generates the dSYMs itself (rules.mk runs dsymutil after linking and
before strip), so the only job here is to archive them faithfully. These tests
pin exactly that: bundles are copied byte-for-byte and the built images are
never touched, the arch directory survives so a per-arch dSYM cannot be mistaken
for a fat one, an empty bundle is not counted as collected, and the verifier
rejects a bundle that cannot name the crash frame.

No dsymutil or dwarfdump is needed: collect only copies, and the verifier is
driven through a stub.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COLLECT = ROOT / 'ci/collect_symbols.py'
VERIFY = ROOT / 'ci/verify_symbols.py'

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
    print('Looking up ' + symbol)
    if mode == 'unknown' and symbol == '_main':
        sys.exit(0)
    print('  DW_TAG_subprogram')
    sys.exit(0)
sys.exit(2)
'''


def bundle_bytes(dsym, payload_size=4096):
    return b'\xcf\xfa\xed\xfe' + b'\x00' * (payload_size - 4)


class CollectSymbols(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.obj = self.tmp / '.theos/obj'
        self.prefs_obj = self.tmp / 'vedetteprefs/.theos/obj'
        self.ctl_obj = self.tmp / 'nicectl/.theos/obj'

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def image(self, root, arch, name, payload_size=4096):
        """A built image plus the dSYM Theos would have made beside it."""
        arch_dir = root / arch
        arch_dir.mkdir(parents=True, exist_ok=True)
        (arch_dir / name).write_bytes(b'\xcf\xfa\xed\xfe' + b'\x11' * 2048)
        dwarf = arch_dir / (name + '.dSYM') / 'Contents/Resources/DWARF'
        dwarf.mkdir(parents=True, exist_ok=True)
        (dwarf / name).write_bytes(bundle_bytes(None, payload_size))
        return arch_dir / name

    def run_collect(self, out='symbols', require=False):
        command = [sys.executable, '-B', str(COLLECT), '--out', str(self.tmp / out),
                   '--objects', str(self.obj), '--objects', str(self.prefs_obj),
                   '--objects', str(self.ctl_obj)]
        if require:
            command.append('--require')
        return subprocess.run(command, capture_output=True, text=True)

    def test_keeps_every_arch_bundle_and_leaves_images_untouched(self):
        images = [
            self.image(self.obj, 'arm64', 'Vedette.dylib'),
            self.image(self.obj, 'arm64e', 'Vedette.dylib'),
            self.image(self.prefs_obj, 'arm64e', 'VedettePrefs'),
            self.image(self.ctl_obj, 'arm64e', 'vedette-nicectl'),
        ]
        before = {i: hashlib.sha256(i.read_bytes()).hexdigest() for i in images}
        result = self.run_collect()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('4/4 bundle(s) collected', result.stdout)

        out = self.tmp / 'symbols'
        self.assertTrue((out / 'arm64/Vedette.dylib.dSYM').is_dir())
        self.assertTrue((out / 'arm64e/Vedette.dylib.dSYM').is_dir())
        self.assertTrue((out / 'arm64e/VedettePrefs.dSYM').is_dir())
        self.assertTrue((out / 'arm64e/vedette-nicectl.dSYM').is_dir())
        self.assertEqual(before, {i: hashlib.sha256(i.read_bytes()).hexdigest() for i in images})

        copied = out / 'arm64e/Vedette.dylib.dSYM/Contents/Resources/DWARF/Vedette.dylib'
        original = self.obj / 'arm64e/Vedette.dylib.dSYM/Contents/Resources/DWARF/Vedette.dylib'
        self.assertEqual(copied.read_bytes(), original.read_bytes())

    def test_arch_directory_survives_so_slices_stay_distinguishable(self):
        self.image(self.obj, 'arm64', 'Vedette.dylib', payload_size=4096)
        self.image(self.obj, 'arm64e', 'Vedette.dylib', payload_size=8192)
        self.assertEqual(self.run_collect().returncode, 0)
        slim = self.tmp / 'symbols/arm64/Vedette.dylib.dSYM/Contents/Resources/DWARF/Vedette.dylib'
        fat = self.tmp / 'symbols/arm64e/Vedette.dylib.dSYM/Contents/Resources/DWARF/Vedette.dylib'
        self.assertNotEqual(slim.stat().st_size, fat.stat().st_size)

    def test_empty_bundle_is_not_collected_and_require_fails_when_nothing_is(self):
        arch_dir = self.obj / 'arm64e'
        arch_dir.mkdir(parents=True)
        dwarf = arch_dir / 'Vedette.dylib.dSYM/Contents/Resources/DWARF'
        dwarf.mkdir(parents=True)
        (dwarf / 'Vedette.dylib').write_bytes(b'\xcf\xfa\xed\xfe')  # stripped-input stub

        soft = self.run_collect()
        self.assertEqual(soft.returncode, 0, soft.stdout + soft.stderr)
        self.assertIn('0/1 bundle(s) collected', soft.stdout)
        self.assertIn('no DWARF payload', soft.stdout)
        self.assertFalse((self.tmp / 'symbols/arm64e/Vedette.dylib.dSYM').exists())

        hard = self.run_collect(require=True)
        self.assertEqual(hard.returncode, 1)

    def test_never_recollects_its_own_output(self):
        self.image(self.obj, 'arm64e', 'Vedette.dylib')
        first = self.run_collect()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        # A second pass scans the project root, which now contains symbols/.
        again = subprocess.run([sys.executable, '-B', str(COLLECT), '--out', str(self.tmp / 'symbols'),
                                '--objects', str(self.tmp)],
                               capture_output=True, text=True)
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn('1/1 bundle(s) collected', again.stdout)
        self.assertNotIn('symbols/arm64e/Vedette.dylib.dSYM', again.stdout.replace(' -> ', ' ').split('1/1')[0])

    def test_no_bundles_is_reported_not_guessed(self):
        for root in (self.obj, self.prefs_obj, self.ctl_obj):
            root.mkdir(parents=True)
        result = self.run_collect()
        self.assertEqual(result.returncode, 0)
        self.assertIn('no .dSYM', result.stdout)
        self.assertEqual(self.run_collect(require=True).returncode, 1)


class VerifySymbols(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stub = self.tmp / 'dwarfdump.py'
        self.stub.write_text(STUB_DWARFDUMP, encoding='utf-8')

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def bundle(self, arch, name, size=4096):
        dwarf = self.tmp / 'symbols' / arch / name / 'Contents/Resources/DWARF'
        dwarf.mkdir(parents=True, exist_ok=True)
        (dwarf / name.replace('.dSYM', '')).write_bytes(b'\x00' * size)

    def run_verify(self, env=None):
        merged = dict(os.environ)
        merged['DWARFDUMP'] = '%s %s' % (sys.executable, self.stub)
        merged.update(env or {})
        return subprocess.run([sys.executable, '-B', str(VERIFY), str(self.tmp / 'symbols')],
                              capture_output=True, text=True, env=merged)

    def test_accepts_per_arch_bundles_that_name_the_crash_frame(self):
        self.bundle('arm64', 'Vedette.dylib.dSYM')
        self.bundle('arm64e', 'Vedette.dylib.dSYM')
        self.bundle('arm64e', 'vedette-nicectl.dSYM')
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('3 bundle(s) verified', result.stdout)
        self.assertIn('resolved _VDTReadExtensionBundleInfo', result.stdout)
        self.assertIn('arm64e/Vedette.dylib.dSYM', result.stdout)

    def test_rejects_missing_uuid_and_unresolved_function(self):
        self.bundle('arm64e', 'Vedette.dylib.dSYM')
        self.assertEqual(self.run_verify().returncode, 0)

        self.bundle('arm64e', 'vedette-nicectl.dSYM')
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
