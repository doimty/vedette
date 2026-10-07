#!/usr/bin/env python3
"""Compact layout source/scope checks + actual shared metric C execution.
Not an iOS UIKit runtime test.
"""
from pathlib import Path
import subprocess,tempfile,unittest,re
ROOT=Path(__file__).resolve().parents[1]
BASE='cd0b34807c031d2e179f1ae397ea8c6847be35e3'
CONTROLLERS=['VDTRootListController.m','VDTProcessConfiguration.m','VDTAboutListController.m','VDTApplicationListSubcontrollerController.m','ChoicyPreferences/CHPListController.m']
ALLOWED={'vedetteprefs/'+f for f in CONTROLLERS}|{'vedetteprefs/VDTStyle.m','vedetteprefs/VDTStyle.h','vedetteprefs/VDTHeaderCell.m'}
# Release metadata is strictly checked by test_preferences_ui.py; new binary
# markers are checked against the actual package by verify_preferences_resources.
RELEASE_GATES={'control','.github/workflows/roothide-build.yml',
               'tests/test_preferences_ui.py','tests/verify_preferences_resources.py'}

class CompactUI(unittest.TestCase):
    def test_actual_metric_minimum_and_scaling(self):
        source=r'''
#include "vedetteprefs/VDTCompactMetrics.h"
#include <assert.h>
int main(void) {
    double v[]={NAN,INFINITY,-INFINITY,-1,0,30,43.5,44,44.01,55.2,100,200};
    double want[]={44,44,44,44,44,44,44,44,45,56,100,200};
    for(unsigned i=0;i<sizeof(v)/sizeof(v[0]);i++) assert(VDTCompactRowMetric(v[i])==want[i]);
    double last=44;
    for(int i=1;i<=5000;i++) { double h=VDTCompactRowMetric(i/10.0); assert(h>=44 && h>=last);last=h; }
}
'''
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'test.c').write_text(source)
            for cc in ('cc','clang'):
                subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT),str(p/'test.c'),'-lm','-o',str(p/'test')],check=True)
                subprocess.run([str(p/'test')],check=True)

    def test_other_source_exactly_frozen(self):
        paths=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE],cwd=ROOT,text=True).splitlines()
        for path in paths:
            if path not in ALLOWED | RELEASE_GATES:
                self.assertEqual((ROOT/path).read_bytes(),subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT),path)

    def test_real_delegates_not_only_estimated_height(self):
        for path in CONTROLLERS:
            s=(ROOT/'vedetteprefs'/path).read_text()
            self.assertIn('return VDTCompactRowHeight(tableView);',s,path)
            self.assertIn('return VDTCompactSectionHeight(self, section, NO);',s,path)
            self.assertIn('return VDTCompactSectionHeight(self, section, YES);',s,path)
            self.assertIn('return VDTCompactSectionView(self, tableView, section, NO);',s,path)
            self.assertIn('return VDTCompactSectionView(self, tableView, section, YES);',s,path)
            self.assertNotRegex(s,r'\[super\s+tableView:[^\]]*(?:willDisplayCell|heightForHeaderInSection|heightForFooterInSection|viewForHeaderInSection|viewForFooterInSection):')

    def test_header_constraints_and_special_controls(self):
        h=(ROOT/'vedetteprefs/VDTHeaderCell.m').read_text()
        self.assertIn('systemFontOfSize:20',h)
        self.assertEqual(h.count('constraintEqualToConstant:40'),2)
        self.assertIn('topAnchor constant:12',h)
        self.assertIn('bottomAnchor constant:-12',h)
        self.assertIn('label.numberOfLines = 0',h)
        for p in CONTROLLERS[:2]:
            self.assertIn('return UITableViewAutomaticDimension;', (ROOT/'vedetteprefs'/p).read_text())
        detail=(ROOT/'vedetteprefs/VDTProcessConfiguration.m').read_text()
        self.assertIn('specifier.cellType == PSSwitchCell',detail)
        self.assertIn('[super tableView:tableView heightForRowAtIndexPath:indexPath]',detail)

    def test_multiline_sections_preserve_text(self):
        s=(ROOT/'vedetteprefs/VDTStyle.m').read_text()
        self.assertIn('self.caption.numberOfLines = 0',s)
        self.assertIn('self.caption.bottomAnchor',s)
        self.assertIn('view.caption.text = text',s)
        self.assertIn('return UITableViewAutomaticDimension',s)
        self.assertIn('scaledValueForValue:44 compatibleWithTraitCollection:',s)
        self.assertIn('NSLineBreakByTruncatingTail',s)
        self.assertNotIn('contentInset =',s)
        self.assertNotIn('appearance]',s)
        self.assertNotIn('getPrefs(',s)
        self.assertNotIn('writeToFile:',s)

    def test_old_density_does_not_satisfy_new_contract(self):
        old=subprocess.check_output(['git','show',BASE+':vedetteprefs/VDTHeaderCell.m'],cwd=ROOT,text=True)
        self.assertIn('topAnchor constant:20',old)
        self.assertNotIn('topAnchor constant:12',old)
        old_root=subprocess.check_output(['git','show',BASE+':vedetteprefs/VDTRootListController.m'],cwd=ROOT,text=True)
        self.assertNotIn('return VDTCompactRowHeight(tableView);',old_root)

if __name__=='__main__':unittest.main(verbosity=2)
