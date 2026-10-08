#!/usr/bin/env python3
from pathlib import Path
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[1]
class DiagnosticExpansion(unittest.TestCase):
    def test_dictionary_payload_is_one_debug_argument_and_absent_in_release(self):
        path=ROOT/'tests/diagnostic_objc_preprocess.m'
        args=['clang','-E','-P','-x','objective-c']
        debug=subprocess.check_output(args+['-DVDT_DIAGNOSTICS_ENABLED=1','-I',str(ROOT),str(path)],text=True)
        release=subprocess.check_output(args+['-DVDT_DIAGNOSTICS_ENABLED=0','-I',str(ROOT),str(path)],text=True)
        self.assertIn('(VDTProbeRecordImpl)((',debug)
        self.assertIn('@"a":@(x), @"b":@(x)',debug)
        self.assertIn('do { (void)0; } while (0)',release)
        self.assertNotIn('VDTProbeRecordImpl',release)
        self.assertNotIn('@{',release)
if __name__=='__main__':unittest.main(verbosity=2)
