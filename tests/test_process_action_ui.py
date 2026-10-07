#!/usr/bin/env python3
"""Source-level native selector wiring and unchanged persistence regression.
Does not execute UIKit; device rendering/selection must be tested after build.
"""
from pathlib import Path
import subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
REL='vedetteprefs/VDTProcessConfiguration.m'
BASE='cd0b34807c031d2e179f1ae397ea8c6847be35e3'

def layout_is_compact(source):
    assert 'cell:PSSegmentCell' not in source
    assert 'detail:[PSListItemsController class] cell:PSLinkListCell' in source
    assert 'violationPolicyGroupSpec' not in source
    group=source.index('[rootSpecifiers addObject:maxCPUUsageGroupSpec];')
    action=source.index('[rootSpecifiers addObject:violationPolicySelectionSpec];')
    value=source.index('[rootSpecifiers addObject:maxCPUUsageSpec];')
    interval=source.index('[rootSpecifiers addObject:intervalSpec];')
    assert group < action < value < interval
    assert source.count('[rootSpecifiers addObject:maxCPUUsageGroupSpec];')==1

class ProcessActionPresentation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.current=(ROOT/REL).read_text()
        cls.base=subprocess.check_output(['git','show',BASE+':'+REL],cwd=ROOT,text=True)
    def test_native_selector_in_parameter_group(self):
        layout_is_compact(self.current)
    def test_original_large_button_rejected(self):
        with self.assertRaises(AssertionError):layout_is_compact(self.base)
    def test_persistence_and_interval_updates_exactly_unchanged(self):
        marker='- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier*)specifier'
        self.assertEqual(self.current[self.current.index(marker):],self.base[self.base.index(marker):])
    def test_native_values_defaults_and_callbacks_preserved(self):
        start='        [violationPolicySelectionSpec setValues:'
        end='        [rootSpecifiers addObject:violationPolicySelectionSpec];'
        a=self.current[self.current.index(start):self.current.index(end)+len(end)]
        b=self.base[self.base.index(start):self.base.index(end)+len(end)]
        self.assertEqual(a,b)
        line=next(l for l in self.current.splitlines() if 'PSSpecifier *violationPolicySelectionSpec =' in l)
        self.assertIn('set:@selector(setProcessConfigValue:specifier:)',line)
        self.assertIn('get:@selector(readProcessConfigValue:)',line)
    def test_help_and_localization_not_dropped(self):
        self.assertIn('NSString *actionHelp = VDTLoc',self.current)
        self.assertIn('NSString *parameterHelp = VDTLoc',self.current)
        self.assertIn('actionHelp, parameterHelp] forKey:@"footerText"',self.current)
        self.assertIn('@"%@\\n%@"',self.current)

if __name__=='__main__':unittest.main(verbosity=2)
