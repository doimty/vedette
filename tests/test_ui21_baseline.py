#!/usr/bin/env python3
"""ui21 = ui2 visual baseline, own identity, one plain policy-selection row."""
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
UI2='cd0b34807c031d2e179f1ae397ea8c6847be35e3'
UI_FILES=[
 'vedetteprefs/VDTRootListController.m','vedetteprefs/VDTAboutListController.m',
 'vedetteprefs/VDTApplicationListSubcontrollerController.m','vedetteprefs/VDTHeaderCell.h',
 'vedetteprefs/VDTHeaderCell.m','vedetteprefs/VDTStyle.h','vedetteprefs/VDTStyle.m',
 'vedetteprefs/ChoicyPreferences/CHPListController.m',
 'vedetteprefs/ChoicyPreferences/CHPDaemonListController.m']
def base(path):
 return subprocess.check_output(['git','show',UI2+':'+path],cwd=ROOT)

class UI21(unittest.TestCase):
 def test_all_pages_restore_ui2_visual_source(self):
  for path in UI_FILES:
   with self.subTest(file=path):
    self.assertEqual((ROOT/path).read_bytes(),base(path))
 def test_policy_row_only_changes_to_native_single_selection(self):
  path='vedetteprefs/VDTProcessConfiguration.m';old=base(path)
  wanted=old.replace(b'#import "VDTHeaderCell.h"\n',b'#import "VDTHeaderCell.h"\n#import "VDTActionListController.h"\n',1)
  wanted=wanted.replace(b'detail:nil cell:PSSegmentCell edit:nil];',b'detail:[VDTActionListController class] cell:PSLinkListCell edit:nil];',1)
  wanted=wanted.replace(b'[rootSpecifiers addObject:violationPolicyGroupSpec];\n        \n        PSSpecifier *violationPolicySelectionSpec',b'[rootSpecifiers addObject:violationPolicyGroupSpec];\n\n        PSSpecifier *violationPolicySelectionSpec',1)
  self.assertEqual((ROOT/path).read_bytes(),wanted)
  self.assertTrue((ROOT/'vedetteprefs/VDTActionListController.m').is_file())
 def test_user_owned_ids_and_legacy_rules(self):
  info=(ROOT/'vedetteprefs/Resources/Info.plist').read_text();control=(ROOT/'control').read_text()
  self.assertIn('com.doimty.vedetteprefs',info);self.assertIn('Package: com.doimty.vedette',control)
  self.assertIn('Conflicts: com.udevs.vedette',control);self.assertIn('Replaces: com.udevs.vedette',control)
  self.assertEqual((ROOT/'Common.h').read_bytes(),base('Common.h'))
 def test_no_ui4_duplicate_sections_and_no_segment_button(self):
  self.assertFalse((ROOT/'vedetteprefs/VDTCompactMetrics.h').exists())
  source='\n'.join((ROOT/path).read_text() for path in UI_FILES)
  for token in ('VDTCompactSectionLabel','VDTCompactSectionView','VDTCompactRowHeight','titleForHeaderInSection:','heightForHeaderInSection:','viewForHeaderInSection:'):
   self.assertNotIn(token,source)
  config=(ROOT/'vedetteprefs/VDTProcessConfiguration.m').read_text()
  self.assertNotIn('PSSegmentCell',config)
  action=(ROOT/'vedetteprefs/VDTActionListController.m').read_text()
  self.assertIn('readProcessConfigValue:specifier',action)
  self.assertIn('setProcessConfigValue:value specifier:specifier',action)
  self.assertIn('[owner setProcessConfigValue:value specifier:specifier]',action)
  self.assertIn('[owner reloadSpecifier:specifier animated:NO]',action)
 def test_enum_defaults_and_mutation_path_unchanged(self):
  path='vedetteprefs/VDTProcessConfiguration.m';now=(ROOT/path).read_text();old=base(path).decode()
  marker='- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier*)specifier'
  self.assertEqual(now[now.index(marker):],old[old.index(marker):])
  self.assertIn('VDTViolationPolicyMonitorAndTerminate',now)
  self.assertIn('VDTViolationPolicyThrottle',now)

if __name__=='__main__':
 unittest.main(verbosity=2)
