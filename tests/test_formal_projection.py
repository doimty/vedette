#!/usr/bin/env python3
"""Formal projection contracts and unknown-change rejection; no native claims."""
import subprocess
import unittest
from formal_delta import (ROOT, FORMAL_BASE, FORMAL_VERSION, FORMAL_PATHS,
                          formal_baseline, formal_regions, without_formal_rules)
from extension_projection import assert_release_freeze, projected_bytes, baseline_bytes


class FormalProjection(unittest.TestCase):
    def test_two_fixed_ancestors_and_formal_upgrade(self):
        for revision in (FORMAL_BASE, '788f43bcb17a2c3890ed8bdeea3f1a97660e13c7'):
            subprocess.run(['git', 'merge-base', '--is-ancestor', revision, 'HEAD'], cwd=ROOT, check=True)
        for previous in ('1.1.13-3', '1.1.13-2', '1.1.13-1+rc1', '1.1.12-3', '1.1.10-1+ui21'):
            subprocess.run(['dpkg', '--compare-versions', FORMAL_VERSION, 'gt', previous], check=True)

    def test_literal_projection_all_layers(self):
        for path in formal_regions():
            with self.subTest(path=path):
                actual = (ROOT / path).read_bytes()
                self.assertEqual(without_formal_rules(path, actual), formal_baseline(path))
                exists_in_release = subprocess.run(
                    ['git', 'cat-file', '-e', '788f43bcb17a2c3890ed8bdeea3f1a97660e13c7:' + path],
                    cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if exists_in_release:
                    assert_release_freeze(path, actual)

    def test_unknown_bytes_rejected_for_every_reviewed_path(self):
        for path in formal_regions():
            actual = (ROOT / path).read_bytes()
            with self.subTest(path=path):
                with self.assertRaises(AssertionError):
                    without_formal_rules(path, actual + b'\nunknown-unauthorized-change\n')

    def test_changed_reviewed_regions_rejected(self):
        for path, hunks in formal_regions().items():
            actual = (ROOT / path).read_text()
            for previous, current in hunks:
                self.assertEqual(actual.count(current), 1)
                changed = actual.replace(current, current + 'unknown-region-change', 1)
                with self.subTest(path=path):
                    with self.assertRaises(AssertionError): without_formal_rules(path, changed)

    def test_cpu_identity_nice_policy_and_lifecycle_stay_frozen(self):
        for path in ('VDTNicePolicy.c', 'VDTNiceStore.c', 'VDTProcessIdentity.c',
                     'VDTCPUState.c', 'VDTSpringBoardIdentity.h', 'nicectl/main.mm',
                     'nicectl/Entitlements.plist', 'layout/DEBIAN/prerm',
                     'layout-rootless/DEBIAN/prerm', 'Makefile'):
            if (ROOT / path).exists():
                self.assertEqual((ROOT / path).read_bytes(),
                    subprocess.check_output(['git', 'show', FORMAL_BASE + ':' + path], cwd=ROOT), path)

    def test_whitespace_exception_cannot_expand(self):
        actual = (ROOT / '.gitattributes').read_text()
        self.assertIn('tests/fixtures/formal-1113-inverse.patch whitespace=-blank-at-eol', actual)
        for altered in ('*.m', '*.mm', 'tests/*', '*'):
            changed = actual.replace('tests/fixtures/formal-1113-inverse.patch', altered, 1)
            with self.assertRaises(AssertionError): without_formal_rules('.gitattributes', changed)


if __name__ == '__main__': unittest.main(verbosity=2)
