#!/usr/bin/env python3
"""Exact visual/history projections and negative cases; not UIKit/device proof."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import comfort_delta
from comfort_delta import COMFORT_BASE, COMFORT_PATHS, comfort_baseline, without_comfort_rules
from extension_projection import RELEASE_BASE, assert_release_freeze, released_bytes
import formal_delta
from formal_delta import FORMAL_BASE, FORMAL_PATHS, FORMAL_VERSION, formal_baseline, without_formal_rules
import visual_delta
from visual_delta import (ROOT, VISUAL_BASE, VISUAL_PATHS, VISUAL_WHITESPACE_ADDITION,
                          parse_visual_regions, visual_baseline, visual_regions, without_visual_rules)
from verify_release_layout import VERSION as VERIFIED_VERSION

EXPECTED_PATHS = frozenset({
    'vedetteprefs/VDTCheckDetailsController.m', 'vedetteprefs/VDTCheckFieldCell.m',
    'vedetteprefs/VDTCheckResultCell.m', 'vedetteprefs/VDTCheckResultModel.m',
    'vedetteprefs/VDTApplicationListSubcontrollerController.m',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
    'control', '.github/workflows/roothide-build.yml', 'ci/stage_release.py',
    'ci/run_host_tests.sh', 'Makefile.tests', '.gitattributes',
})
SYNTHETIC_PATH = 'control'
FIELD_CELL = 'vedetteprefs/VDTCheckFieldCell.m'
MARKER = b'\\ No newline at end of file\n'


def fixture(body=b' anchor\n-old\n+new\n', header=b'@@ -1,2 +1,2 @@\n', path=SYNTHETIC_PATH):
    name = path.encode('utf-8')
    return (b'diff --git a/' + name + b' b/' + name + b'\n'
            b'index 0000000..1111111 100644\n--- a/' + name + b'\n+++ b/' + name + b'\n'
            + header + body)


class VisualProjection(unittest.TestCase):
    def test_candidate_version_is_consistent_across_package_gates(self):
        self.assertEqual(VERIFIED_VERSION, '1.1.14-9')
        fields = {
            'control': b'Version: 1.1.14-9\n',
            '.github/workflows/roothide-build.yml': b'      PACKAGE_VERSION: 1.1.14-9\n',
            'ci/stage_release.py': b"fields.get('Version','').strip()!='1.1.14-9'",
        }
        for path, expected in fields.items():
            with self.subTest(path=path):
                self.assertEqual((ROOT / path).read_bytes().count(expected), 1)

    def test_fixed_base_and_narrow_existing_scope(self):
        self.assertEqual(VISUAL_BASE, '7cef39b6058f699e2c5bd7f17a1562f37a6aeb4c')
        subprocess.run(['git', 'merge-base', '--is-ancestor', VISUAL_BASE, 'HEAD'], cwd=ROOT, check=True)
        self.assertEqual(VISUAL_PATHS, EXPECTED_PATHS)
        self.assertEqual(len(VISUAL_PATHS), 13)
        regions = visual_regions()
        self.assertLessEqual(set(regions), EXPECTED_PATHS)
        changed = {path for path in VISUAL_PATHS if (ROOT / path).read_bytes() != visual_baseline(path)}
        self.assertEqual(set(regions), changed)
        for path in VISUAL_PATHS:
            with self.subTest(path=path):
                subprocess.run(['git', 'cat-file', '-e', VISUAL_BASE + ':' + path], cwd=ROOT, check=True)
        for path in ('VDTCPUState.c', 'VDTNicePolicy.c', 'VDTNiceStore.c', 'VDTShared.mm',
                     'vedetteprefs/VDTProcessConfiguration.m', 'vedetteprefs/VDTCheckPresentation.m',
                     'tests/visual_delta.py', 'tests/fixtures/visual-11146-inverse.patch'):
            self.assertNotIn(path, VISUAL_PATHS)

    def test_all_current_files_restore_complete_fixed_bytes_and_preserve_types(self):
        for path in sorted(VISUAL_PATHS):
            actual = (ROOT / path).read_bytes()
            base = visual_baseline(path)
            with self.subTest(path=path):
                self.assertEqual(without_visual_rules(path, actual), base)
                self.assertEqual(without_visual_rules(path, actual.decode('utf-8')), base.decode('utf-8'))
                self.assertIs(without_visual_rules(path, base), base)
                text = base.decode('utf-8')
                self.assertIs(without_visual_rules(path, text), text)

    def test_unknown_append_or_in_hunk_mutation_rejected(self):
        regions = visual_regions()
        for path in sorted(VISUAL_PATHS):
            actual = (ROOT / path).read_bytes()
            with self.subTest(path=path, mutation='extra-bytes'):
                with self.assertRaises(AssertionError):
                    without_visual_rules(path, actual + b'\nunknown-visual-bytes\n')
                with self.assertRaises(AssertionError):
                    without_formal_rules(path, actual + b'\nunknown-visual-bytes\n')
            for previous, current in regions.get(path, ()):
                position = len(current) // 2
                mutated = current[:position] + bytes([current[position] ^ 1]) + current[position + 1:]
                with self.subTest(path=path, mutation='hunk'):
                    self.assertEqual(actual.count(current), 1)
                    with self.assertRaises(AssertionError):
                        without_visual_rules(path, actual.replace(current, mutated, 1))
                    with self.assertRaises(AssertionError):
                        without_visual_rules(path, actual + current)
                    with mock.patch.object(visual_delta, 'visual_regions', return_value={path: ((previous, mutated),)}):
                        with self.assertRaises(AssertionError):
                            without_visual_rules(path, actual)
                    with mock.patch.object(visual_delta, 'visual_regions', return_value={path: ((previous + b'x', current),)}):
                        with self.assertRaises(AssertionError):
                            without_visual_rules(path, actual)

    def test_layered_inputs_and_direct_field_cell_caller(self):
        self.assertEqual(COMFORT_BASE, '2a3108cc797da453599086a7f4cbbf13bb32a162')
        self.assertEqual(FORMAL_BASE, '1dfce93bd54b83292b1547d6a608a180fb4cd8b4')
        self.assertEqual(FORMAL_VERSION, '1.1.14-4')
        for path in sorted(VISUAL_PATHS & COMFORT_PATHS):
            current = (ROOT / path).read_bytes()
            visual_base = visual_baseline(path)
            comfort_base = comfort_baseline(path)
            with self.subTest(path=path):
                self.assertEqual(without_visual_rules(path, current), visual_base)
                self.assertEqual(without_comfort_rules(path, current), comfort_base)
                self.assertEqual(without_comfort_rules(path, visual_base), comfort_base)
                self.assertIs(without_comfort_rules(path, comfort_base), comfort_base)
                if path in FORMAL_PATHS:
                    formal_base = formal_baseline(path)
                    self.assertEqual(without_formal_rules(path, current), formal_base)
                    self.assertEqual(without_formal_rules(path, visual_base), formal_base)
                    self.assertEqual(without_formal_rules(path, comfort_base), formal_base)
        self.assertNotIn(FIELD_CELL, COMFORT_PATHS)
        self.assertNotIn(FIELD_CELL, FORMAL_PATHS)
        prior = subprocess.check_output(['git', 'show', COMFORT_BASE + ':' + FIELD_CELL], cwd=ROOT)
        self.assertEqual(prior, visual_baseline(FIELD_CELL))
        self.assertEqual(without_formal_rules(FIELD_CELL, (ROOT / FIELD_CELL).read_bytes()), prior)
        self.assertEqual(without_formal_rules(FIELD_CELL, prior), prior)
        self.assertEqual(released_bytes(FIELD_CELL, (ROOT / FIELD_CELL).read_bytes()), prior)
        with self.assertRaises(AssertionError):
            without_formal_rules(FIELD_CELL, prior + b'\nunknown-field-change\n')
        with self.assertRaises(AssertionError):
            released_bytes(FIELD_CELL, (ROOT / FIELD_CELL).read_bytes() + b'\nunknown-field-change\n')
        missing = subprocess.run(['git', 'cat-file', '-e', FORMAL_BASE + ':' + FIELD_CELL],
                                 cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertNotEqual(missing.returncode, 0)

    def test_whitespace_exception_is_exactly_one_fixture_line(self):
        path = '.gitattributes'
        base = visual_baseline(path)
        actual = (ROOT / path).read_bytes()
        self.assertEqual(actual, base + VISUAL_WHITESPACE_ADDITION)
        self.assertEqual(without_visual_rules(path, actual), base)
        for expanded in (b'*', b'*.m', b'*.mm', b'tests/*', b'tests/fixtures/*'):
            changed = actual.replace(b'tests/fixtures/visual-11146-inverse.patch', expanded, 1)
            with self.subTest(expanded=expanded), self.assertRaises(AssertionError):
                without_visual_rules(path, changed)
        with self.assertRaises(AssertionError):
            without_visual_rules(path, actual + b'*.c -whitespace\n')

    def test_old_fixture_bytes_are_never_regenerated(self):
        for name in ('tests/fixtures/comfort-1114-inverse.patch',
                     'tests/fixtures/formal-1113-inverse.patch',
                     'tests/fixtures/appex-ui21-inverse.patch'):
            with self.subTest(path=name):
                expected = subprocess.check_output(['git', 'show', VISUAL_BASE + ':' + name], cwd=ROOT)
                self.assertEqual((ROOT / name).read_bytes(), expected)

    def test_cpu_nice_storage_and_configuration_freezes_remain_effective(self):
        for path in ('VDTCPUState.c', 'VDTProcessIdentity.c', 'VDTNicePolicy.c',
                     'VDTNiceStore.c', 'VDTShared.mm', 'vedetteprefs/VDTProcessConfiguration.m',
                     'nicectl/main.mm'):
            self.assertNotIn(path, VISUAL_PATHS)
            with self.subTest(path=path):
                with self.assertRaises(AssertionError):
                    without_visual_rules(path, b'unreviewed-core-bytes')
                if not (ROOT / path).is_file():
                    exists_at_visual_base = subprocess.run(
                        ['git', 'cat-file', '-e', VISUAL_BASE + ':' + path], cwd=ROOT,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                    self.assertFalse(exists_at_visual_base, 'fixed-base core file missing: ' + path)
                    continue
                actual = (ROOT / path).read_bytes()
                exists = subprocess.run(['git', 'cat-file', '-e', RELEASE_BASE + ':' + path], cwd=ROOT,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if exists:
                    assert_release_freeze(path, actual)
                    with self.assertRaises(AssertionError):
                        assert_release_freeze(path, actual + b'\nunknown-core-change\n')

    def test_import_performs_no_git_calls_or_file_io(self):
        spec = importlib.util.spec_from_file_location('visual_import_contract', ROOT / 'tests/visual_delta.py')
        module = importlib.util.module_from_spec(spec)
        with mock.patch.object(subprocess, 'check_output', side_effect=AssertionError('git on import')), \
             mock.patch.object(subprocess, 'run', side_effect=AssertionError('process on import')), \
             mock.patch.object(subprocess, 'Popen', side_effect=AssertionError('process on import')), \
             mock.patch.object(Path, 'open', side_effect=AssertionError('file on import')):
            spec.loader.exec_module(module)
        self.assertEqual(module.VISUAL_BASE, VISUAL_BASE)


class VisualFixtureParsing(unittest.TestCase):
    def parse(self, patch, base=b'anchor\nold\n'):
        with mock.patch.object(visual_delta, 'visual_baseline', return_value=base):
            return parse_visual_regions(patch)

    def test_invalid_paths_aliases_and_cross_file_hunks_rejected(self):
        for path in ('VDTCPUState.c', 'VDTNicePolicy.c', 'VDTShared.mm', 'tests/visual_delta.py',
                     'vedetteprefs/VDTCheckPresentation.m', './control', 'ci/../control',
                     'ci\\stage_release.py', '/control', 'control/'):
            with self.subTest(path=path):
                with self.assertRaises(AssertionError):
                    parse_visual_regions(fixture(path=path))
                with self.assertRaises(AssertionError):
                    visual_baseline(path)
                with self.assertRaises(AssertionError):
                    without_visual_rules(path, b'unknown')
        changed = fixture().replace(b'b/control', b'b/ci/stage_release.py', 1)
        with self.assertRaises(AssertionError):
            self.parse(changed)
        other = fixture(path='ci/stage_release.py')
        with mock.patch.object(visual_delta, 'visual_baseline', side_effect=lambda p: {
                'control': b'anchor\nold\n', 'ci/stage_release.py': b'different\nold\n'}[p]):
            with self.assertRaises(AssertionError):
                parse_visual_regions(fixture() + other)

    def test_old_context_count_positions_and_unique_new_context(self):
        for patch, base in ((fixture().replace(b'-old\n', b'-wrong\n'), b'anchor\nold\n'),
                            (fixture(), b'anchor\nold\nanchor\nold\n'),
                            (fixture(), b'anchor\nold\nanchor\nnew\n'),
                            (fixture(header=b'@@ -1,3 +1,2 @@\n'), b'anchor\nold\n'),
                            (fixture(header=b'@@ -2,2 +2,2 @@\n'), b'anchor\nold\n'),
                            (fixture(header=b'@@ -1,2 +2,2 @@\n'), b'anchor\nold\n'),
                            (fixture(body=b' anchor\n old\n'), b'anchor\nold\n')):
            with self.subTest(patch=patch, base=base), self.assertRaises(AssertionError):
                self.parse(patch, base)

    def test_reordered_or_overlapping_hunks_and_regions_rejected(self):
        base = b'anchor\nold\nseparator\nother\nold2\n'
        first = b'@@ -1,2 +1,2 @@\n anchor\n-old\n+new\n'
        second = b'@@ -4,2 +4,2 @@\n other\n-old2\n+new2\n'
        header = fixture(body=b'', header=b'')
        patch = header + first + second
        regions = self.parse(patch, base)
        for changed in (header + second + first, patch + first):
            with self.assertRaises(AssertionError):
                self.parse(changed, base)
        actual = b'anchor\nnew\nseparator\nother\nnew2\n'
        reordered = b'other\nnew2\nseparator\nanchor\nnew\n'
        with mock.patch.object(visual_delta, 'visual_baseline', return_value=base), \
             mock.patch.object(visual_delta, 'visual_regions', return_value=regions):
            self.assertEqual(without_visual_rules(SYNTHETIC_PATH, actual), base)
            with self.assertRaises(AssertionError):
                without_visual_rules(SYNTHETIC_PATH, reordered)
            with self.assertRaises(AssertionError):
                without_visual_rules(SYNTHETIC_PATH, actual.replace(b'separator\n', b'separator\nextra\n'))

    def test_changed_fixture_new_side_cannot_consume_original_source(self):
        base, actual = b'anchor\nold\n', b'anchor\nnew\n'
        altered = fixture().replace(b'+new\n', b'+other\n')
        regions = self.parse(altered, base)
        with mock.patch.object(visual_delta, 'visual_baseline', return_value=base), \
             mock.patch.object(visual_delta, 'visual_regions', return_value=regions), \
             self.assertRaises(AssertionError):
            without_visual_rules(SYNTHETIC_PATH, actual)

    def test_attribute_fixture_rule_cannot_expand_even_with_matching_hunk(self):
        base = b'anchor\n'
        body = b' anchor\n+' + VISUAL_WHITESPACE_ADDITION
        patch = fixture(body=body, header=b'@@ -1 +1,2 @@\n', path='.gitattributes')
        self.parse(patch, base)
        for expanded in (b'*', b'*.m', b'*.mm', b'tests/*', b'tests/fixtures/*'):
            changed = patch.replace(b'tests/fixtures/visual-11146-inverse.patch', expanded, 1)
            with self.subTest(expanded=expanded), self.assertRaises(AssertionError):
                self.parse(changed, base)
        extra = patch.replace(b'@@ -1 +1,2 @@', b'@@ -1 +1,3 @@') + b'+*.c -whitespace\n'
        with self.assertRaises(AssertionError):
            self.parse(extra, base)

    def test_metadata_truncation_and_unsupported_records_rejected(self):
        original = fixture()
        for changed in (b'', original[:-1], original + original,
                        original.replace(b'--- a/control', b'--- a/ci/stage_release.py'),
                        original.replace(b'+++ b/control', b'+++ /dev/null'),
                        original.replace(b'index 0000000..1111111 100644', b'new file mode 100644'),
                        original.replace(b'index 0000000..1111111 100644', b'old mode 100644\nnew mode 100755'),
                        original.replace(b'+new\n', b'unknown hunk record\n'),
                        fixture(body=b'+new\n', header=b'@@ -0,0 +1 @@\n')):
            with self.subTest(patch=changed), self.assertRaises(AssertionError):
                self.parse(changed)

    def test_index_hashes_are_never_used_as_an_oracle(self):
        original = fixture()
        changed = original.replace(b'0000000..1111111', b'2222222..3333333')
        self.assertEqual(self.parse(original), self.parse(changed))

    def test_no_newline_markers_and_crlf_are_exact_bytes(self):
        cases = (
            (b'anchor\nold', b'anchor\nnew', b' anchor\n-old\n' + MARKER + b'+new\n' + MARKER),
            (b'anchor\nold', b'anchor\nnew\n', b' anchor\n-old\n' + MARKER + b'+new\n'),
            (b'anchor\nold\n', b'anchor\nnew', b' anchor\n-old\n+new\n' + MARKER),
            (b'anchor\r\nold\r\n', b'anchor\r\nnew\r\n', b' anchor\r\n-old\r\n+new\r\n'),
        )
        for base, actual, body in cases:
            regions = self.parse(fixture(body=body), base)
            with self.subTest(base=base), \
                 mock.patch.object(visual_delta, 'visual_baseline', return_value=base), \
                 mock.patch.object(visual_delta, 'visual_regions', return_value=regions):
                self.assertEqual(without_visual_rules(SYNTHETIC_PATH, actual), base)
                with self.assertRaises(AssertionError):
                    without_visual_rules(SYNTHETIC_PATH, actual + b'\nunknown\n')
                if b'\r\n' in actual:
                    with self.assertRaises(AssertionError):
                        without_visual_rules(SYNTHETIC_PATH, actual.replace(b'\r\n', b'\n'))
        with self.assertRaises(AssertionError):
            self.parse(fixture().replace(b'\n', b'\r\n'))
        for body in (MARKER + b' anchor\n-old\n+new\n',
                     b' anchor\n-old\n' + MARKER + MARKER + b'+new\n',
                     b' anchor\n' + MARKER + b'-old\n+new\n'):
            with self.assertRaises(AssertionError):
                self.parse(fixture(body=body))

    def test_comfort_baseline_passthrough_precedes_visual_validation(self):
        base = b'exact-comfort-base\n'
        with mock.patch.object(comfort_delta, 'comfort_baseline', return_value=base), \
             mock.patch.object(visual_delta, 'without_visual_rules', side_effect=AssertionError('visual invoked')) as visual:
            self.assertIs(without_comfort_rules(SYNTHETIC_PATH, base), base)
            visual.assert_not_called()
            with self.assertRaisesRegex(AssertionError, 'visual invoked'):
                without_comfort_rules(SYNTHETIC_PATH, base + b'unknown\n')
            visual.assert_called_once()

    def test_formal_direct_caller_applies_visual_freeze_to_field_cell(self):
        base, actual = b'anchor\nold\n', b'anchor\nnew\n'
        regions = self.parse(fixture(path=FIELD_CELL), base)
        with mock.patch.object(visual_delta, 'visual_baseline', return_value=base), \
             mock.patch.object(visual_delta, 'visual_regions', return_value=regions), \
             mock.patch.object(formal_delta, 'formal_regions', return_value={}):
            self.assertEqual(without_formal_rules(FIELD_CELL, actual), base)
            self.assertEqual(without_formal_rules(FIELD_CELL, base), base)
            with self.assertRaises(AssertionError):
                without_formal_rules(FIELD_CELL, actual + b'unknown\n')

    def test_baseline_passthrough_without_fixture_and_unchanged_path_strictness(self):
        base = b'unchanged\n'
        with mock.patch.object(visual_delta, 'visual_baseline', return_value=base), \
             mock.patch.object(visual_delta, 'visual_regions', return_value={}):
            self.assertIs(without_visual_rules(SYNTHETIC_PATH, base), base)
            with self.assertRaises(AssertionError):
                without_visual_rules(SYNTHETIC_PATH, base + b'unknown\n')
            with self.assertRaises(AssertionError):
                without_visual_rules(SYNTHETIC_PATH, bytearray(base))


if __name__ == '__main__':
    unittest.main(verbosity=2)
