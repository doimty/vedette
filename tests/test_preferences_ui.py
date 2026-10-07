#!/usr/bin/env python3
"""Host resource/source contracts, NOT UIKit runtime tests.
The C suite separately executes the production ordering kernel.
"""
import json
import plistlib
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
BASELINE = 'd54fc36cb03e75fbe8699099abc747199ae570b6'
DYNAMIC_KEYS = {'Project source', 'Support original developer', 'Twitter', 'Reddit',
                'Enabled Configurations', 'Other', 'No Results', 'No Applications', 'No Daemons'}


def read_strings(path):
    content = path.read_text()
    pattern = r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;'
    pairs = re.findall(pattern, content)
    if re.sub(pattern, '', content).strip():
        raise ValueError('Invalid strings syntax')
    result = {}
    for key, value in pairs:
        key, value = json.loads(key), json.loads(value)
        if key in result:
            raise ValueError('Duplicate key: ' + key)
        result[key] = value
    return result


def validate_keys(required, english, chinese):
    assert set(english) == set(chinese), 'language keys differ'
    assert required <= set(english), 'missing UI translations'
    for key in english:
        assert english[key] == key, 'English fallback differs'
        assert chinese[key], 'empty translation'
        assert re.findall(r'%(?:\d+\$)?(?:@|lu|ld|d|u)', key) == re.findall(
            r'%(?:\d+\$)?(?:@|lu|ld|d|u)', chinese[key]), 'format placeholder mismatch'


class PreferencesUIContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.en = read_strings(PREFS / 'Resources/en.lproj/Localizable.strings')
        cls.zh = read_strings(PREFS / 'Resources/zh-Hans.lproj/Localizable.strings')
        cls.sources = '\n'.join(p.read_text() for p in PREFS.rglob('*.m'))
        cls.required = set(re.findall(r'VDTLoc\([^,]+,\s*@"([^"\n]+)"\)', cls.sources)) | DYNAMIC_KEYS

    def test_localization_keys_and_placeholders(self):
        validate_keys(self.required, self.en, self.zh)

    def test_missing_translation_is_rejected(self):
        broken = dict(self.zh)
        del broken['Enable Vedette']
        with self.assertRaises(AssertionError):
            validate_keys(self.required, self.en, broken)

    def test_broken_format_is_rejected(self):
        broken = dict(self.zh)
        broken['Failed to reset. %@'] = '错误'
        with self.assertRaises(AssertionError):
            validate_keys(self.required, self.en, broken)

    def test_bundle_languages(self):
        info = plistlib.loads((PREFS / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDevelopmentRegion'], 'en')
        self.assertEqual(set(info['CFBundleLocalizations']), {'en', 'zh-Hans'})
        self.assertEqual(info['NSPrincipalClass'], 'VDTRootListController')

    def test_backend_filter_packaging_frozen(self):
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASELINE], cwd=ROOT, text=True).splitlines()
        for name in paths:
            if name.startswith('vedetteprefs/') or name.startswith('tests/'):
                continue
            expected = subprocess.check_output(['git', 'show', BASELINE + ':' + name], cwd=ROOT)
            actual = (ROOT / name).read_bytes()
            if name == 'control':
                wanted = expected.replace(b'Version: 1.1.10\n', b'Version: 1.1.10-1+ui4\n')
                wanted = wanted.replace(b'Package: com.udevs.vedette\n', b'Package: com.doimty.vedette\n')
                wanted = wanted.replace(b'Maintainer: udevs\n', b'Conflicts: com.udevs.vedette\nReplaces: com.udevs.vedette\nMaintainer: doimty\n')
                self.assertEqual(actual, wanted, name)
            elif name == '.github/workflows/roothide-build.yml':
                # Only reviewed build-metadata and added test gates may differ.
                wanted = expected.replace(b'# v4.4.0\n', b'# v4.4.0\n        with:\n          fetch-depth: 0\n', 1)
                wanted = wanted.replace(b'          brew install dpkg ldid make\n',
                    b'          brew_prefix="$(brew --prefix)"\n          if [ -L "$brew_prefix/bin/openssl" ] && [ "$(readlink "$brew_prefix/bin/openssl")" = "$brew_prefix/opt/openssl@1.1/bin/openssl" ]; then\n            unlink "$brew_prefix/bin/openssl"\n          fi\n          brew install dpkg ldid make\n', 1)
                wanted = wanted.replace(b'com.udevs.vedette', b'com.doimty.vedette')
                wanted = wanted.replace(b'1.1.10', b'1.1.10-1+ui4')
                wanted = wanted.replace(b'          python3 tests/check_auto_monitor_path.py\n',
                    b'          python3 tests/check_auto_monitor_path.py\n          sh tests/run_list_order_tests.sh\n          python3 -B tests/test_preferences_ui.py\n          python3 -B tests/test_ios15_cell_lifecycle.py\n          python3 -B tests/test_compact_ui.py\n          python3 -B tests/test_process_action_ui.py\n          python3 -B tests/test_section_text.py\n          python3 -B tests/test_package_identity.py\n', 1)
                wanted = wanted.replace(b'          dpkg-deb -e "$deb" /tmp/vedette-control\n',
                    b'          python3 -B tests/verify_preferences_resources.py /tmp/vedette-package\n          dpkg-deb -e "$deb" /tmp/vedette-control\n', 1)
                self.assertEqual(actual, wanted, name)
            else:
                self.assertEqual(actual, expected, name)
        for name in ['vedetteprefs/Makefile', 'vedetteprefs/ChoicyPreferences/CHPDaemonList.m']:
            expected = subprocess.check_output(['git', 'show', BASELINE + ':' + name], cwd=ROOT)
            self.assertEqual((ROOT / name).read_bytes(), expected, name)

    def test_native_cards_not_global_appearance(self):
        for path in ['VDTRootListController.m', 'VDTProcessConfiguration.m', 'VDTAboutListController.m',
                     'VDTApplicationListSubcontrollerController.m', 'ChoicyPreferences/CHPListController.m']:
            self.assertIn('tableViewStyle { return UITableViewStyleInsetGrouped; }', (PREFS / path).read_text())
        self.assertNotIn(' appearance]', self.sources)
        for name in ['VDTRootListController.m', 'VDTProcessConfiguration.m']:
            source = (PREFS / name).read_text()
            self.assertIn('VDTHeaderSpecifier(', source)
            self.assertIn('return UITableViewAutomaticDimension;', source)
            self.assertNotIn('tableHeaderView', source)
        header = (PREFS / 'VDTHeaderCell.m').read_text()
        self.assertIn('scaledFontForFont:', header)
        self.assertNotIn('tableWidth - 40', header)
        self.assertIn('row.bottomAnchor', header)
        self.assertIn('label.numberOfLines = 0', header)

    def test_list_identity_and_query_wiring(self):
        app = (PREFS / 'VDTApplicationListSubcontrollerController.m').read_text()
        daemon = (PREFS / 'ChoicyPreferences/CHPDaemonListController.m').read_text()
        self.assertIn('VDTGroupedListSpecifiers(filtered, @"applicationIdentifier"', app)
        self.assertIn('VDTGroupedListSpecifiers(rows, @"daemonName"', daemon)
        self.assertNotIn('_allSpecifiers =', app)
        for source in (app, daemon):
            self.assertIn('viewWillAppear:', source)
            self.assertIn('[self reloadSpecifiers]', source)
        helper = (PREFS / 'VDTListPresentation.m').read_text()
        enabled = helper[helper.index('BOOL VDTListConfigurationEnabled'):helper.index('static int VDTCompare')]
        self.assertIn('valueForProcessConfigKeyWithPrefs', enabled)
        self.assertNotIn('valueForKeyWithPrefs', enabled)

    def test_settings_keys_defaults_and_actions_unchanged(self):
        source = (PREFS / 'VDTProcessConfiguration.m').read_text()
        for key in ('enabled', 'percentage', 'interval', 'violationPolicy', 'applicationIdentifier', 'daemonName'):
            self.assertIn('@"' + key + '"', source)
        self.assertIn('setProperty:@NO forKey:@"default"', source)
        self.assertIn('setValueForProcessConfigKey([self validIdentifier], key, value, [self configurationType])', source)
        self.assertIn('@[VDTLoc(self.class, @"Terminate"), VDTLoc(self.class, @"Throttle")]', source)

    def test_no_new_polling_or_network(self):
        new_sources = '\n'.join(p.read_text() for p in PREFS.glob('VDT*.m'))
        for forbidden in ['scheduledTimer', 'dispatch_source_create', 'NSURLSession', 'UIAppearance']:
            self.assertNotIn(forbidden, new_sources)


if __name__ == '__main__':
    unittest.main(verbosity=2)
