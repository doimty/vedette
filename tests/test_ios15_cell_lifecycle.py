#!/usr/bin/env python3
"""Regression for device-proven iOS15 optional-delegate super-send crash.
Source contract only; actual UIKit behaviour still requires device verification.
"""
from pathlib import Path
import re,subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
FILES=['VDTRootListController.m','VDTProcessConfiguration.m','VDTAboutListController.m']
BAD='tableView:willDisplayCell:forRowAtIndexPath:'
BASE='3b2182c824ad1c0f7cfda968f30d68f765d9043c'

def assert_safe(source):
    assert not re.search(r'\[super\s+tableView:[^\]]*willDisplayCell:',source), 'optional delegate super call'
    signature='- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath'
    start=source.find(signature)
    assert start>=0,'style not attached to inherited cell creation'
    end=source.index('\n}',start)
    body=source[start:end]
    assert 'UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];' in body
    assert body.index('VDTStyleCell(cell);')<body.index('return cell;')

class IOS15CellLifecycle(unittest.TestCase):
    def test_current_controllers_use_required_data_source_method(self):
        for file in FILES:
            with self.subTest(file=file):assert_safe((ROOT/'vedetteprefs'/file).read_text())
    def test_actual_crashing_sources_rejected(self):
        for file in FILES:
            source=subprocess.check_output(['git','show',BASE+':vedetteprefs/'+file],cwd=ROOT,text=True)
            with self.subTest(file=file),self.assertRaises(AssertionError):assert_safe(source)

if __name__=='__main__':unittest.main(verbosity=2)
