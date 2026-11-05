#!/usr/bin/env python3
"""Literal delta/integration regressions; not runtime or artifact equivalence."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import launch_symbols_delta as delta
from extension_projection import RELEASE_BASE, assert_release_freeze

ROOT = Path(__file__).resolve().parents[1]
OLD_FIXTURES = (
    'tests/fixtures/appex-ui21-inverse.patch',
    'tests/fixtures/formal-1113-inverse.patch',
    'tests/fixtures/comfort-1114-inverse.patch',
    'tests/fixtures/visual-11146-inverse.patch',
)


class LaunchSymbolsDelta(unittest.TestCase):
    def test_fixed_green_base_and_explicit_scope(self):
        self.assertEqual(delta.BASE, '38d6f44d3fbf24245a0f0d8db1a79fb53105a36c')
        subprocess.run(['git', 'merge-base', '--is-ancestor', delta.BASE, 'HEAD'], cwd=ROOT, check=True)
        self.assertEqual(delta.PATHS, frozenset({'.github/workflows/roothide-build.yml',
                                                '.gitignore', 'Vedette.xm', 'ci/run_host_tests.sh'}))
        self.assertEqual(set(delta.reviewed_regions()), delta.PATHS)

    def test_exact_delta_then_unchanged_history(self):
        for path in sorted(delta.PATHS):
            current = (ROOT / path).read_bytes()
            base = delta.baseline(path)
            with self.subTest(path=path):
                self.assertNotEqual(current, base)
                self.assertEqual(delta.without_launch_symbols(path, current), base)
                self.assertEqual(delta.without_launch_symbols(path, current.decode()), base.decode())
                self.assertIs(delta.without_launch_symbols(path, base), base)
                # Only paths present in the release baseline can be frozen to it;
                # ci/run_host_tests.sh did not exist at that revision.
                present = subprocess.run(
                    ['git', 'cat-file', '-e', RELEASE_BASE + ':' + path], cwd=ROOT,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if present:
                    assert_release_freeze(path, current)

    def test_unknown_edits_fail_closed_every_reviewed_path(self):
        for path, hunks in delta.reviewed_regions().items():
            current = (ROOT / path).read_bytes()
            with self.subTest(path=path):
                for invalid in (current + b'\nunknown-change\n',
                                delta.baseline(path) + b'\nunknown-change\n', b''):
                    with self.assertRaises(AssertionError):
                        delta.without_launch_symbols(path, invalid)
                for _, region in hunks:
                    self.assertEqual(current.count(region), 1)
                    offset = len(region) // 2
                    corrupt = region[:offset] + bytes([region[offset] ^ 1]) + region[offset + 1:]
                    with self.assertRaises(AssertionError):
                        delta.without_launch_symbols(path, current.replace(region, corrupt, 1))
                    with self.assertRaises(AssertionError):
                        delta.without_launch_symbols(path, current + region)

    def test_crlf_is_not_silently_normalized_by_projections(self):
        path = 'Vedette.xm'
        with self.assertRaises(AssertionError):
            delta.without_launch_symbols(path, (ROOT / path).read_bytes().replace(b'\n', b'\r\n'))

    def test_original_fixtures_remain_byte_identical(self):
        for path in OLD_FIXTURES:
            expected = subprocess.check_output(['git', 'show', delta.BASE + ':' + path], cwd=ROOT)
            self.assertEqual((ROOT / path).read_bytes(), expected, path)

    def test_fixture_metadata_counts_old_bytes_and_scope_are_checked(self):
        raw = (ROOT / delta.FIXTURE).read_bytes()
        corruptions = (
            raw[:-1], raw + raw,
            raw.replace(b'diff --git a/.gitignore b/.gitignore', b'diff --git a/./.gitignore b/./.gitignore', 1),
            raw.replace(b'--- a/.gitignore', b'--- a/control', 1),
            raw.replace(b' 100644\n', b' 100755\n', 1),
            raw.replace(b'-symbols/', b'-different/', 1) if b'-symbols/' in raw else raw.replace(b'-*.pyc', b'-*.xxx', 1),
        )
        for changed in corruptions:
            with self.subTest(mutation=changed[:40]):
                self.assertNotEqual(raw, changed)
                with self.assertRaises(AssertionError):
                    delta.parse_regions(changed)
        rows = raw.splitlines(keepends=True)
        h = next(i for i, r in enumerate(rows) if r.startswith(b'@@ '))
        import re
        numbers = list(map(int, re.findall(rb'\d+', rows[h])))
        numbers[1] += 1
        rows[h] = b'@@ -%d,%d +%d,%d @@\n' % tuple(numbers)
        with self.assertRaises(AssertionError):
            delta.parse_regions(b''.join(rows))

    def test_no_file_or_git_observation_on_import(self):
        spec = importlib.util.spec_from_file_location('launch_delta_import_test', ROOT / 'tests/launch_symbols_delta.py')
        module = importlib.util.module_from_spec(spec)
        with mock.patch.object(subprocess, 'check_output', side_effect=AssertionError('git on import')), \
             mock.patch.object(subprocess, 'run', side_effect=AssertionError('process on import')), \
             mock.patch.object(Path, 'open', side_effect=AssertionError('file on import')):
            spec.loader.exec_module(module)
        self.assertEqual(module.BASE, delta.BASE)

    def test_deb_upload_precedes_symbol_collection_and_uuid_validation(self):
        flow = (ROOT / '.github/workflows/roothide-build.yml').read_text()
        self.assertLess(flow.index('- name: Upload deb packages'), flow.index('- name: Collect debug symbols'))
        self.assertLess(flow.index('- name: Collect debug symbols'), flow.index('- name: Verify debug symbols against the package'))
        self.assertLess(flow.index('- name: Verify debug symbols against the package'), flow.index('- name: Upload debug symbols'))
        self.assertIn('--package-root /tmp/vedette-package --package-prefix "$PACKAGE_PREFIX"', flow)
        self.assertIn('--manifest symbols/manifest.json', flow)
        makefile = (ROOT / 'Makefile').read_text()
        self.assertNotIn('collect_symbols', makefile)
        self.assertEqual((ROOT / 'Makefile').read_bytes(),
                         subprocess.check_output(['git', 'show', delta.BASE + ':Makefile'], cwd=ROOT))


if __name__ == '__main__':
    unittest.main(verbosity=2)
