#!/usr/bin/env python3
"""Own distribution IDs without migrating or resetting legacy rule storage."""
from pathlib import Path
import plistlib,subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
BASE='4ac149755d093995ce2b14f7971d8299d4df41ce'

def parse(text):
    return dict((k,v.strip()) for k,v in (l.split(':',1) for l in text.splitlines() if ':' in l))
def require_ids(control,info):
    assert control['Package']=='com.doimty.vedette'
    assert control['Conflicts']=='com.udevs.vedette'
    assert control['Replaces']=='com.udevs.vedette'
    assert control['Maintainer']=='doimty'
    assert control['Author']=='udevs'
    assert info['CFBundleIdentifier']=='com.doimty.vedetteprefs'
    assert info['CFBundleExecutable']=='VedettePrefs'
    assert info['NSPrincipalClass']=='VDTRootListController'

class OwnIdentifiers(unittest.TestCase):
    def test_package_and_bundle_ids(self):
        require_ids(parse((ROOT/'control').read_text()),plistlib.loads((ROOT/'vedetteprefs/Resources/Info.plist').read_bytes()))
    def test_old_identity_and_missing_replacement_rejected(self):
        old=parse(subprocess.check_output(['git','show',BASE+':control'],cwd=ROOT,text=True))
        info=plistlib.loads((ROOT/'vedetteprefs/Resources/Info.plist').read_bytes())
        with self.assertRaises((AssertionError,KeyError)):require_ids(old,info)
        for field in ('Conflicts','Replaces'):
            broken=parse((ROOT/'control').read_text());del broken[field]
            with self.assertRaises((AssertionError,KeyError)):require_ids(broken,info)
    def test_legacy_configuration_channel_and_loader_paths_preserved(self):
        for file in ('Common.h','VDTShared.h','VDTShared.mm','Vedette.xm','VDTProbe.mm',
                     'Makefile','vedetteprefs/Makefile','layout/DEBIAN/postinst','layout/DEBIAN/postrm'):
            with self.subTest(file=file):
                self.assertEqual((ROOT/file).read_bytes(),subprocess.check_output(['git','show',BASE+':'+file],cwd=ROOT))

if __name__=='__main__':unittest.main(verbosity=2)
