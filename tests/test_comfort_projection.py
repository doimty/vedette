#!/usr/bin/env python3
"""Exact comfort/formal source projections and negatives; NOT runtime/SDK proof."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import comfort_delta
from comfort_delta import (ROOT, COMFORT_BASE, COMFORT_PATHS,
                           COMFORT_WHITESPACE_ADDITION, comfort_baseline,
                           comfort_regions, parse_comfort_regions, without_comfort_rules)
from formal_delta import (FORMAL_BASE, FORMAL_VERSION, FORMAL_PATHS,
                          formal_baseline, formal_regions, without_formal_rules)
from extension_projection import assert_release_freeze

EXPECTED_PATHS = frozenset({
    'VDTProcessManager.h', 'VDTProcessManager.mm',
    'VDTResourceRuntime.h', 'VDTResourceRuntime.mm',
    'VDTResourceShared.h', 'VDTResourceShared.mm',
    'libproc/libproc_internal.h', 'Vedette.xm',
    'vedetteprefs/VDTCheckResultModel.m', 'vedetteprefs/VDTCheckResultReader.m',
    'vedetteprefs/VDTCheckResultsPreferences.m',
    'vedetteprefs/VDTCheckResultCell.h', 'vedetteprefs/VDTCheckResultCell.m',
    'vedetteprefs/VDTCheckDetailsController.h', 'vedetteprefs/VDTCheckDetailsController.m',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
    'control', '.github/workflows/roothide-build.yml', 'ci/stage_release.py',
    'ci/run_host_tests.sh', 'Makefile.tests', '.gitattributes',
})
SYNTHETIC_PATH = 'VDTResourceRuntime.h'
MARKER = b'\\ No newline at end of file\n'


def fixture(body=b' anchor\n-old\n+new\n', header=b'@@ -1,2 +1,2 @@\n', path=SYNTHETIC_PATH):
    name = path.encode('utf-8')
    return (b'diff --git a/' + name + b' b/' + name + b'\n'
            b'index 0000000..1111111 100644\n--- a/' + name + b'\n+++ b/' + name + b'\n'
            + header + body)


class ComfortProjection(unittest.TestCase):
    def test_fixed_base_and_bounded_existing_scope(self):
        self.assertEqual(COMFORT_BASE, '2a3108cc797da453599086a7f4cbbf13bb32a162')
        self.assertEqual(COMFORT_PATHS, EXPECTED_PATHS)
        self.assertEqual(len(COMFORT_PATHS), 23)
        regions = comfort_regions()
        self.assertTrue(regions)
        self.assertLessEqual(set(regions), EXPECTED_PATHS)
        for path, hunks in regions.items():
            self.assertTrue(hunks, path)
            base = comfort_baseline(path)
            actual = (ROOT / path).read_bytes()
            for previous, current in hunks:
                with self.subTest(path=path):
                    self.assertTrue(previous and current)
                    self.assertNotEqual(previous, current)
                    self.assertEqual(base.count(previous), 1)
                    self.assertEqual(actual.count(current), 1)
        for path in ('VDTPIDSnapshot.h', 'VDTResourceSummary.h', 'tests/comfort_delta.py',
                     'tests/test_comfort_projection.py', 'tests/fixtures/comfort-1114-inverse.patch'):
            self.assertNotIn(path, COMFORT_PATHS)
            self.assertNotIn(path, FORMAL_PATHS)

    def test_every_allowlisted_current_file_returns_exact_fixed_base_bytes_and_str(self):
        for path in sorted(COMFORT_PATHS):
            actual = (ROOT / path).read_bytes()
            base = comfort_baseline(path)
            with self.subTest(path=path):
                self.assertEqual(without_comfort_rules(path, actual), base)
                self.assertEqual(without_comfort_rules(path, actual.decode('utf-8')), base.decode('utf-8'))

    def test_exact_base_is_safe_for_historical_callers(self):
        for path in COMFORT_PATHS:
            base = comfort_baseline(path)
            text = base.decode('utf-8')
            with self.subTest(path=path):
                self.assertIs(without_comfort_rules(path, base), base)
                self.assertIs(without_comfort_rules(path, text), text)
                with self.assertRaises(AssertionError):
                    without_comfort_rules(path, base + b'\nunknown-base-change\n')

    def test_combined_inverse_preserves_every_original_formal_path(self):
        self.assertEqual(FORMAL_BASE, '1dfce93bd54b83292b1547d6a608a180fb4cd8b4')
        self.assertEqual(FORMAL_VERSION, '1.1.14-4')
        for path in sorted(FORMAL_PATHS):
            actual = (ROOT / path).read_bytes()
            with self.subTest(path=path):
                self.assertEqual(without_formal_rules(path, actual), formal_baseline(path))
                if path in COMFORT_PATHS:
                    self.assertEqual(without_formal_rules(path, comfort_baseline(path)), formal_baseline(path))

    def test_original_history_fixtures_are_unchanged_bytes(self):
        for path in ('tests/fixtures/formal-1113-inverse.patch', 'tests/fixtures/appex-ui21-inverse.patch'):
            with self.subTest(path=path):
                expected = subprocess.check_output(['git', 'show', COMFORT_BASE + ':' + path], cwd=ROOT)
                self.assertEqual((ROOT / path).read_bytes(), expected)

    def test_unknown_append_rejected_for_every_allowlisted_path(self):
        for path in COMFORT_PATHS:
            actual = (ROOT / path).read_bytes()
            for source in (actual + b'\nunauthorized-comfort-append\n',
                           actual.decode('utf-8') + '\nunauthorized-comfort-append\n'):
                with self.subTest(path=path, kind=type(source).__name__):
                    with self.assertRaises(AssertionError):
                        without_comfort_rules(path, source)

    def test_in_hunk_byte_mutations_and_duplicates_never_normalize(self):
        for path, hunks in comfort_regions().items():
            actual = (ROOT / path).read_bytes()
            for previous, current in hunks:
                position = len(current) // 2
                mutated = current[:position] + bytes([current[position] ^ 1]) + current[position + 1:]
                with self.subTest(path=path, position=position):
                    with self.assertRaises(AssertionError):
                        without_comfort_rules(path, actual.replace(current, mutated, 1))
                    with self.assertRaises(AssertionError):
                        without_comfort_rules(path, actual + current)
                    # Even a changed fixture new side cannot silently consume the
                    # actual source. Old sides still refer to the fixed Git blob.
                    with mock.patch.object(comfort_delta, 'comfort_regions', return_value={path: ((previous, mutated),)}):
                        with self.assertRaises(AssertionError):
                            without_comfort_rules(path, actual)

    def test_reordered_regions_rejected(self):
        path = 'VDTProcessManager.mm'
        actual = (ROOT / path).read_bytes()
        first, second = [current for _, current in comfort_regions()[path]][:2]
        left, right = actual.index(first), actual.index(second)
        self.assertLessEqual(left + len(first), right)
        changed = (actual[:left] + second + actual[left + len(first):right]
                   + first + actual[right + len(second):])
        with self.assertRaises(AssertionError):
            without_comfort_rules(path, changed)

    def test_cpu_nice_and_list_whole_source_freezes_remain_effective(self):
        for path in ('VDTCPUState.c', 'VDTProcessIdentity.c', 'VDTNiceRuntime.mm',
                     'VDTNicePolicy.c', 'VDTNiceStore.c', 'nicectl/main.mm',
                     'vedetteprefs/VDTExtensionListController.m',
                     'vedetteprefs/ChoicyPreferences/CHPDaemonListController.m'):
            if not (ROOT / path).exists():
                continue
            with self.subTest(path=path):
                self.assertNotIn(path, COMFORT_PATHS)
                actual = (ROOT / path).read_bytes()
                # Release freeze only applies to paths present in that release.
                in_release = subprocess.run(
                    ['git', 'cat-file', '-e', '788f43bcb17a2c3890ed8bdeea3f1a97660e13c7:' + path],
                    cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if in_release:
                    assert_release_freeze(path, actual)
                    with self.assertRaises(AssertionError):
                        assert_release_freeze(path, actual + b'\nunknown-frozen-core-change\n')
        # Mutations in old formal regions still fail AFTER exact comfort removal.
        for path, hunks in formal_regions().items():
            source = (ROOT / path).read_bytes()
            if path in COMFORT_PATHS:
                source = without_comfort_rules(path, source)
            previous, current = hunks[0]
            current = current.encode('utf-8')
            self.assertEqual(source.count(current), 1, path)
            with self.subTest(formal_path=path):
                with self.assertRaises(AssertionError):
                    without_formal_rules(path, source.replace(current, current + b'unknown-formal-change', 1))

    def test_whitespace_allowance_is_only_the_one_exact_fixture(self):
        path = '.gitattributes'
        base = comfort_baseline(path)
        actual = (ROOT / path).read_bytes()
        self.assertIn(actual, (base, base + COMFORT_WHITESPACE_ADDITION))
        self.assertEqual(without_comfort_rules(path, actual), base)
        if actual != base:
            for expanded in (b'*', b'*.mm', b'tests/*', b'tests/fixtures/*'):
                changed = actual.replace(b'tests/fixtures/comfort-1114-inverse.patch', expanded, 1)
                with self.subTest(expanded=expanded):
                    with self.assertRaises(AssertionError):
                        without_comfort_rules(path, changed)

    def test_import_performs_no_git_calls_or_file_io(self):
        spec = importlib.util.spec_from_file_location('comfort_import_contract', ROOT / 'tests/comfort_delta.py')
        module = importlib.util.module_from_spec(spec)
        with mock.patch.object(subprocess, 'check_output', side_effect=AssertionError('git on import')), \
             mock.patch.object(subprocess, 'run', side_effect=AssertionError('process on import')), \
             mock.patch.object(subprocess, 'Popen', side_effect=AssertionError('process on import')), \
             mock.patch.object(Path, 'open', side_effect=AssertionError('file on import')), \
             mock.patch.object(Path, 'write_bytes', side_effect=AssertionError('write on import')), \
             mock.patch.object(Path, 'write_text', side_effect=AssertionError('write on import')):
            spec.loader.exec_module(module)
        self.assertEqual(module.COMFORT_BASE, COMFORT_BASE)


class ComfortFixtureParsing(unittest.TestCase):
    def parse(self, patch, base=b'anchor\nold\n'):
        with mock.patch.object(comfort_delta, 'comfort_baseline', return_value=base):
            return parse_comfort_regions(patch)

    def test_unsupported_paths_and_aliases_rejected_by_all_comfort_apis(self):
        for path in ('VDTCPUState.c', 'VDTPIDSnapshot.h', 'tests/comfort_delta.py',
                     './Vedette.xm', 'vedetteprefs/../Vedette.xm', 'Vedette.xm/',
                     'libproc\\libproc_internal.h', '/Vedette.xm', 'control-alias'):
            with self.subTest(path=path):
                with self.assertRaises(AssertionError):
                    parse_comfort_regions(fixture(path=path))
                with self.assertRaises(AssertionError):
                    comfort_baseline(path)
                with self.assertRaises(AssertionError):
                    without_comfort_rules(path, b'unknown bytes')

    def test_unchanged_allowlisted_file_without_hunks_stays_exact(self):
        base = b'unchanged\n'
        with mock.patch.object(comfort_delta, 'comfort_regions', return_value={}), \
             mock.patch.object(comfort_delta, 'comfort_baseline', return_value=base):
            for source in (base, base.decode('utf-8')):
                self.assertEqual(without_comfort_rules(SYNTHETIC_PATH, source), source)
            with self.assertRaises(AssertionError):
                without_comfort_rules(SYNTHETIC_PATH, base + b'unknown\n')
            with self.assertRaises(AssertionError):
                without_comfort_rules(SYNTHETIC_PATH, bytearray(base))

    def test_old_context_wrong_or_nonunique_rejected(self):
        with self.assertRaises(AssertionError):
            self.parse(fixture().replace(b'-old\n', b'-wrong\n'))
        with self.assertRaises(AssertionError):
            self.parse(fixture(), b'anchor\nold\nanchor\nold\n')

    def test_new_context_nonunique_rejected(self):
        with self.assertRaises(AssertionError):
            self.parse(fixture(), b'anchor\nold\nanchor\nnew\n')

    def test_hunk_counts_positions_overlap_and_empty_sides_rejected(self):
        for changed in (fixture(header=b'@@ -1,3 +1,2 @@\n'),
                        fixture(header=b'@@ -2,2 +2,2 @@\n'),
                        fixture(header=b'@@ -1,2 +2,2 @@\n'),
                        fixture(body=b'+new\n', header=b'@@ -0,0 +1 @@\n'),
                        fixture(body=b'-old\n', header=b'@@ -1 +0,0 @@\n'),
                        fixture(body=b' anchor\n old\n'),
                        fixture() + b'@@ -1,2 +1,2 @@\n anchor\n-old\n+new\n'):
            with self.subTest(patch=changed):
                with self.assertRaises(AssertionError):
                    self.parse(changed)

    def test_file_metadata_scope_and_truncation_rejected(self):
        original = fixture()
        for changed in (b'', original[:-1], original + original,
                        original.replace(b'b/' + SYNTHETIC_PATH.encode(), b'b/control', 1),
                        original.replace(b'--- a/' + SYNTHETIC_PATH.encode(), b'--- a/control'),
                        original.replace(b'+++ b/' + SYNTHETIC_PATH.encode(), b'+++ /dev/null'),
                        original.replace(b'index 0000000..1111111 100644', b'new file mode 100644'),
                        original.replace(b'index 0000000..1111111 100644', b'old mode 100644\nnew mode 100755'),
                        original.replace(b'+new\n', b'unknown hunk record\n')):
            with self.subTest(patch=changed):
                with self.assertRaises(AssertionError):
                    self.parse(changed)

    def test_index_metadata_is_not_a_current_hash_oracle(self):
        original = fixture()
        changed = original.replace(b'0000000..1111111', b'2222222..3333333')
        self.assertEqual(self.parse(original), self.parse(changed))

    def test_no_newline_markers_preserve_both_sides_exactly(self):
        cases = (
            (b'anchor\nold', b'anchor\nnew', b' anchor\n-old\n' + MARKER + b'+new\n' + MARKER),
            (b'anchor\nold', b'anchor\nnew\n', b' anchor\n-old\n' + MARKER + b'+new\n'),
            (b'anchor\nold\n', b'anchor\nnew', b' anchor\n-old\n+new\n' + MARKER),
            (b'old\nanchor', b'new\nanchor', b'-old\n+new\n anchor\n' + MARKER),
        )
        for base, actual, body in cases:
            with self.subTest(base=base, actual=actual):
                regions = self.parse(fixture(body=body), base)
                with mock.patch.object(comfort_delta, 'comfort_regions', return_value=regions), \
                     mock.patch.object(comfort_delta, 'comfort_baseline', return_value=base):
                    self.assertEqual(without_comfort_rules(SYNTHETIC_PATH, actual), base)
                    self.assertEqual(without_comfort_rules(SYNTHETIC_PATH, actual.decode('utf-8')), base.decode('utf-8'))
                    with self.assertRaises(AssertionError):
                        without_comfort_rules(SYNTHETIC_PATH, actual + b'\nunknown\n')

    def test_orphan_duplicate_and_nonterminal_no_newline_markers_rejected(self):
        for changed in (fixture(body=MARKER + b' anchor\n-old\n+new\n'),
                        fixture(body=b' anchor\n-old\n' + MARKER + MARKER + b'+new\n'),
                        fixture(body=b' anchor\n' + MARKER + b'-old\n+new\n'),
                        fixture(body=b' anchor\n-old\n+new\n' + MARKER, header=b'@@ -1,2 +1,2 @@\n')):
            with self.subTest(patch=changed):
                with self.assertRaises(AssertionError):
                    self.parse(changed, b'anchor\nold\ntail\n')

    def test_crlf_source_bytes_never_silently_normalize(self):
        base, actual = b'anchor\r\nold\r\n', b'anchor\r\nnew\r\n'
        patch = fixture(body=b' anchor\r\n-old\r\n+new\r\n')
        regions = self.parse(patch, base)
        with mock.patch.object(comfort_delta, 'comfort_regions', return_value=regions), \
             mock.patch.object(comfort_delta, 'comfort_baseline', return_value=base):
            self.assertEqual(without_comfort_rules(SYNTHETIC_PATH, actual), base)
            with self.assertRaises(AssertionError):
                without_comfort_rules(SYNTHETIC_PATH, actual.replace(b'\r\n', b'\n'))
        with self.assertRaises(AssertionError):
            self.parse(fixture().replace(b'\n', b'\r\n'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
