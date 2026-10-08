#!/usr/bin/env python3
"""Native action picker wiring and unchanged process-policy mutation path.
These are source contracts, not a native UIKit runtime test.
"""
from pathlib import Path
import subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
REL='vedetteprefs/VDTProcessConfiguration.m'
BASE='cd0b34807c031d2e179f1ae397ea8c6847be35e3'

def inspect_selector(source):
    assert 'cell:PSSegmentCell' not in source
    assert 'detail:[VDTActionListController class] cell:PSLinkListCell' in source
    assert '[violationPolicyGroupSpec setProperty:VDTLoc(self.class, @"Terminate ends the process when its CPU limit is exceeded. Throttle limits CPU time; setting it too low can cause timeouts.") forKey:@"footerText"]' in source
    line=next(x for x in source.splitlines() if 'PSSpecifier *violationPolicySelectionSpec =' in x)
    assert 'set:@selector(setProcessConfigValue:specifier:)' in line
    assert 'get:@selector(readProcessConfigValue:)' in line
    values='[violationPolicySelectionSpec setValues:@[@(VDTViolationPolicyMonitorAndTerminate), @(VDTViolationPolicyThrottle)] titles:@[VDTLoc(self.class, @"Terminate"), VDTLoc(self.class, @"Throttle")]];'
    assert values in source
    assert source.index('[rootSpecifiers addObject:violationPolicyGroupSpec];') < source.index('[rootSpecifiers addObject:violationPolicySelectionSpec];') < source.index('[rootSpecifiers addObject:maxCPUUsageGroupSpec];')

class ProcessAction(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.current=(ROOT/REL).read_text()
        cls.base=subprocess.check_output(['git','show',BASE+':'+REL],cwd=ROOT,text=True)
    def test_native_single_selection_replaces_segment(self):inspect_selector(self.current)
    def test_ui2_segment_is_rejected_as_negative_control(self):
        with self.assertRaises(AssertionError):inspect_selector(self.base)
    def test_configuration_setter_and_defaults_unchanged(self):
        marker='- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier*)specifier'
        self.assertEqual(self.current[self.current.index(marker):],self.base[self.base.index(marker):])
    def test_child_controller_forwards_only_to_originating_rule(self):
        child=(ROOT/'vedetteprefs/VDTActionListController.m').read_text()
        self.assertIn('self.parentController',child)
        self.assertIn('[owner readProcessConfigValue:specifier]',child)
        self.assertIn('[owner setProcessConfigValue:value specifier:specifier]',child)
        self.assertIn('[owner reloadSpecifier:specifier animated:NO]',child)
        self.assertNotIn('NSUserDefaults',child)
    def test_help_and_saved_parameter_text_remain(self):
        self.assertIn('Terminate ends the process when its CPU limit is exceeded.',self.current)
        self.assertIn('Terminate: 1–100%. Throttle: 1–255%.',self.current)
        self.assertIn('[violationPolicySelectionSpec setProperty:@"violationPolicy" forKey:@"key"]',self.current)

if __name__=='__main__':unittest.main(verbosity=2)
