#!/usr/bin/env python3
"""Check actual staged/deb preference resources against reviewed source tables."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path
from test_preferences_ui import ROOT, read_strings, validate_keys, DYNAMIC_KEYS


def load_plist(path):
    raw = path.read_bytes()
    if raw.startswith((b'bplist', b'<?xml', b'<plist')):
        return plistlib.loads(raw)
    # .strings may be source text on Linux or compiled plist in Theos output.
    try:
        return read_strings(path)
    except (UnicodeError, ValueError):
        return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def verify(package):
    bundle = package / 'Library/PreferenceBundles/VedettePrefs.bundle'
    assert bundle.is_dir(), 'Missing preference bundle'
    info = load_plist(bundle / 'Info.plist')
    assert info['NSPrincipalClass'] == 'VDTRootListController'
    assert info['CFBundleDevelopmentRegion'] == 'en'
    assert set(info['CFBundleLocalizations']) == {'en', 'zh-Hans'}
    tables = {}
    for locale in ('en', 'zh-Hans'):
        tables[locale] = load_plist(bundle / (locale + '.lproj') / 'Localizable.strings')
        expected = read_strings(ROOT / 'vedetteprefs/Resources' / (locale + '.lproj') / 'Localizable.strings')
        assert tables[locale] == expected, 'Packaged translation differs: ' + locale
    validate_keys(DYNAMIC_KEYS, tables['en'], tables['zh-Hans'])
    binary = (bundle / 'VedettePrefs').read_bytes()
    assert b'tableView:willDisplayCell:forRowAtIndexPath:' not in binary, 'Crashing optional-delegate selector remains in UI binary'
    for symbol in (b'VDTHeaderCell', b'VDTAboutListController', b'VDTApplicationListSubcontrollerController', b'CHPDaemonListController', b'vdtHeader', b'Enabled Configurations', b'VDTCompactSectionLabel', b'PSListItemsController'):
        assert symbol in binary, 'Missing UI implementation marker: ' + repr(symbol)
    assert (bundle / 'Vedette@3x.png').is_file(), 'Missing own icon'
    print('Actual preferences resources: en/zh-Hans', len(tables['en']), 'keys each, bundle info/icon/UI markers passed')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
