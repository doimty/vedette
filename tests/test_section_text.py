#!/usr/bin/env python3
"""ui2 native section chrome prevents the custom-caption duplication seen in ui3."""
from pathlib import Path
import subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
UI2='cd0b34807c031d2e179f1ae397ea8c6847be35e3'
UI3='4ac149755d093995ce2b14f7971d8299d4df41ce'
CONTROLLERS=['VDTRootListController.m','VDTAboutListController.m','VDTApplicationListSubcontrollerController.m','ChoicyPreferences/CHPListController.m']
PROCESS='VDTProcessConfiguration.m'
def show(commit,path):return subprocess.check_output(['git','show',commit+':vedetteprefs/'+path],cwd=ROOT,text=True)
class NativeSectionChrome(unittest.TestCase):
 def test_ui21_uses_exact_ui2_native_section_delegates(self):
  for file in CONTROLLERS:
   with self.subTest(file=file):
    source=(ROOT/'vedetteprefs'/file).read_text()
    base=show(UI2,file)
    self.assertEqual(source,base)
    self.assertNotIn('titleForHeaderInSection:',source)
    self.assertNotIn('viewForHeaderInSection:',source)
 def test_strategy_page_has_no_custom_duplicate_header_delegate(self):
  source=(ROOT/'vedetteprefs'/PROCESS).read_text()
  self.assertIn('PSLinkListCell',source)
  self.assertNotIn('titleForHeaderInSection:',source)
  self.assertNotIn('viewForHeaderInSection:',source)
 def test_ui3_duplicate_text_implementation_is_not_present(self):
  for file in CONTROLLERS:
   with self.subTest(file=file):self.assertNotEqual((ROOT/'vedetteprefs'/file).read_bytes(),show(UI3,file).encode())
  self.assertFalse((ROOT/'vedetteprefs/VDTCompactMetrics.h').exists())
  self.assertNotIn('VDTCompactSectionLabel',(ROOT/'vedetteprefs/VDTStyle.m').read_text())
if __name__=='__main__':unittest.main(verbosity=2)
