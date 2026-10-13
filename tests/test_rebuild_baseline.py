#!/usr/bin/env python3
"""Complete released baseline audit; source evidence, not device/UI execution."""
import subprocess
import unittest
from pathlib import Path
from extension_projection import (ROOT, RELEASE_BASE, CI_PATH,
                                  baseline_bytes, assert_release_freeze, released_bytes)
from formal_delta import FORMAL_VERSION as CANDIDATE_VERSION
from test_resource_preferences_native import detail_contract, NICE_GUARD
from ci_contract import workflow_test_source

OLD_CANDIDATE = 'bb211c0dbbf21819d487c88f6030d9f071022025'


def preserved_paths():
    paths = subprocess.check_output(['git','ls-tree','-r','--name-only',RELEASE_BASE], cwd=ROOT, text=True).splitlines()
    return [p for p in paths if p.startswith(('VDTNice', 'nicectl/', 'vedetteprefs/VDTNice',
                    'layout/', 'layout-rootless/'))] + ['VDTSpringBoardIdentity.h', 'Makefile']


def nice_file_contract(path, data):
    assert released_bytes(path, data) == baseline_bytes(path, RELEASE_BASE), 'released nice/lifecycle changed: ' + path


def build_contract(flow, control, stage, main, prefs):
    assert 'Version: ' + CANDIDATE_VERSION + '\n' in control
    assert '      PACKAGE_VERSION: ' + CANDIDATE_VERSION + '\n' in flow
    assert "fields.get('Version','').strip()!='" + CANDIDATE_VERSION + "'" in stage
    for token in ('- scheme: rootless', '- scheme: roothide',
                  'for binary in "$dylib" "$prefs_binary" "$nicectl"; do',
                  'test_resource_preferences_native.py --require-native',
                  'test_extensions_native.py --require-native',
                  'sudo bash tests/run_nice_native_tests.sh',
                  'sudo bash tests/run_springboard_native_tests.sh',
                  'test_rebuild_baseline.py'):
        assert token in flow, 'missing complete build gate: ' + token
    assert 'SUBPROJECTS += vedetteprefs nicectl' in main
    for token in ('../VDTNiceShared.mm', '../VDTNiceStore.c', '../VDTBundleIdentity.mm', '../VDTBundleRules.c'):
        assert token in prefs, 'missing linked old/new preferences implementation: ' + token


class RebuildBaseline(unittest.TestCase):
    def test_released_ancestor_and_wrong_old_branch_rejected(self):
        good = subprocess.run(['git','merge-base','--is-ancestor',RELEASE_BASE,'HEAD'],cwd=ROOT)
        self.assertEqual(good.returncode,0,'complete released baseline is not an ancestor')
        old = subprocess.run(['git','merge-base','--is-ancestor',RELEASE_BASE,OLD_CANDIDATE],cwd=ROOT)
        self.assertEqual(old.returncode,1,'old UI21 branch must not masquerade as released baseline')

    def test_complete_nice_and_recovery_bytes_preserved(self):
        paths = preserved_paths()
        self.assertEqual(len(paths),22)
        for path in paths:
            with self.subTest(file=path): nice_file_contract(path,(ROOT/path).read_bytes())
        assert_release_freeze('ci/stage_release.py')

    def test_missing_or_changed_nice_layer_rejected(self):
        for path in ('VDTNiceRuntime.mm','VDTNiceShared.mm','VDTNiceStore.c',
                     'nicectl/main.mm','nicectl/Entitlements.plist',
                     'vedetteprefs/VDTNicePreferences.m','layout/DEBIAN/prerm'):
            raw = (ROOT/path).read_bytes()
            with self.subTest(file=path):
                with self.assertRaises(AssertionError): nice_file_contract(path,b'')
                with self.assertRaises(AssertionError): nice_file_contract(path,raw+b'\nchanged\n')

    def test_old_getter_and_missing_nice_editor_rejected(self):
        source=(ROOT/'vedetteprefs/VDTProcessConfiguration.m').read_text()
        detail_contract(source)
        old=source.replace('get:@selector(readResourceRuleValue:)',
                           'get:@selector(readResourceRuleValue:specifier:)',1)
        self.assertNotEqual(old,source)
        with self.assertRaises(AssertionError):detail_contract(old)
        changed=source.replace(NICE_GUARD,'',1)
        self.assertNotEqual(changed,source)
        with self.assertRaises(AssertionError):detail_contract(changed)

    def test_complete_double_scheme_build_and_version(self):
        args=[workflow_test_source()]+[(ROOT/path).read_text() for path in ('control','ci/stage_release.py','Makefile','vedetteprefs/Makefile')]
        build_contract(*args)
        for token in ('- scheme: rootless','sudo bash tests/run_nice_native_tests.sh',
                      'test_resource_preferences_native.py --require-native',
                      'for binary in "$dylib" "$prefs_binary" "$nicectl"; do'):
            changed=list(args);changed[0]=changed[0].replace(token,'removed',1)
            with self.subTest(token=token):
                with self.assertRaises(AssertionError):build_contract(*changed)
        bad=list(args);bad[2]=bad[2].replace(CANDIDATE_VERSION,'1.1.12-3',1)
        with self.assertRaises(AssertionError):build_contract(*bad)

    def test_literal_fixture_exception_cannot_expand_to_code(self):
        raw=(ROOT/'.gitattributes').read_bytes()
        assert_release_freeze('.gitattributes',raw)
        changed=raw.replace(b'tests/fixtures/appex-ui21-inverse.patch',b'*.mm',1)
        self.assertNotEqual(raw,changed)
        with self.assertRaises(AssertionError):assert_release_freeze('.gitattributes',changed)
        with self.assertRaises(AssertionError):assert_release_freeze('.gitattributes',raw+b'\n*.c -whitespace\n')

    def test_release_freeze_rejects_unknown_build_and_version_changes(self):
        for path in (CI_PATH,'control','ci/stage_release.py'):
            raw=(ROOT/path).read_bytes();assert_release_freeze(path,raw)
            with self.subTest(file=path):
                with self.assertRaises(AssertionError):assert_release_freeze(path,raw+b'\nunknown\n')
                changed=raw.replace(CANDIDATE_VERSION.encode(),b'1.1.99',1)
                self.assertNotEqual(changed,raw)
                with self.assertRaises(AssertionError):assert_release_freeze(path,changed)


if __name__=='__main__':unittest.main(verbosity=2)
