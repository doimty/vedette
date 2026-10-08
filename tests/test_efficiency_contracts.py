from pathlib import Path
import re,subprocess,unittest
from nice_delta import without_nice
ROOT=Path(__file__).resolve().parents[1]
BASE='cd0b34807c031d2e179f1ae397ea8c6847be35e3'
CPU_FROZEN=['VDTProcessIdentity.c','VDTProcessIdentity.h','VDTPolicyTransition.c','VDTPolicyTransition.h','VDTShared.mm','VDTShared.h','PrivateHeaders.h','libproc/libproc_internal.h','Vedette.plist','layout/DEBIAN/postinst','layout/DEBIAN/postrm']

class EfficiencyContracts(unittest.TestCase):
    def test_diagnostic_macro_runs_release_and_debug_side_effect_fixtures(self):
        src=ROOT/'tests/test_diagnostics_lazy.c'
        for enabled in ('0','1'):
            with self.subTest(enabled=enabled):
                subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-DVDT_DIAGNOSTICS_ENABLED='+enabled,'-I',str(ROOT),str(src),'-o','/tmp/vedette-diag-test'],check=True)
                subprocess.run(['/tmp/vedette-diag-test'],check=True)
    def test_header_maps_all_probe_sites_to_one_lazier_emitter(self):
        h=(ROOT/'VDTProbe.h').read_text(); impl=(ROOT/'VDTProbe.mm').read_text()
        self.assertIn('VDT_DIAGNOSTIC_CALL(VDTProbeRecordImpl, label, __VA_ARGS__)',h)
        self.assertIn('void VDTProbeRecordImpl(',impl)
        pm=(ROOT/'VDTProcessManager.mm').read_text()
        self.assertIn('#if VDT_DIAGNOSTICS_ENABLED\n    int operationErrno = errno;\n#endif',pm)
        self.assertNotIn('operationErrno = errno;', pm.replace('#if VDT_DIAGNOSTICS_ENABLED\n    int operationErrno = errno;\n#endif',''))
        callsites=[]
        for file in ['Vedette.xm','VDTProcessManager.mm']:
            s=(ROOT/file).read_text();callsites += re.findall(r'VDTProbeRecord\s*\(',s)
            self.assertNotIn('VDTProbeRecordImpl',s)
        self.assertGreaterEqual(len(callsites),6)
    def test_only_reload_publishes_normalized_snapshot(self):
        s=(ROOT/'Vedette.xm').read_text()
        current=s[s.index('static NSArray<NSDictionary *> *current_normalized_configs_sync'):s.index('static NSString *target_instance_key')]
        self.assertIn('if (!normalized_configs_snapshot)',current)
        self.assertIn('vdt_configs_from_prefs(VDTGetPrefs())',current)
        reconcile=s[s.index('static void reconcile_unreported_processes_sync'):s.index('static void schedule_launch_catch_up_sync')]
        handler=s[s.index('static void handle_reported_pid_sync'):s.index('// Core prefs reload logic')]
        self.assertIn('current_normalized_configs_sync()',reconcile)
        self.assertNotIn('vdt_configs_from_prefs',reconcile)
        self.assertIn('current_normalized_configs_sync()',handler)
        self.assertNotIn('VDTGetPrefs',handler)
        reload=s[s.index('static void reloadPrefsSync'):s.index('// Async wrapper')]
        self.assertEqual(reload.count('getPrefs()'),1)
        self.assertEqual(reload.count('vdt_configs_from_prefs(newPrefs)'),1)
        self.assertLess(reload.index('VDTSetPrefs(newPrefs)'),reload.index('normalized_configs_snapshot = [configs copy]'))
        restore=s[s.index('static void restoreAllMonitors'):s.index('static void prefsChangedCallback')]
        self.assertIn('vdt_configs_from_prefs(getTempPrefs())',restore)
        self.assertIn('removeItemAtPath:PREFS_PATH_TMP',restore)
    def test_pid_recheck_recovery_and_two_stage_scan_remain(self):
        s=(ROOT/'Vedette.xm').read_text();pm=(ROOT/'VDTProcessManager.mm').read_text();policy=(ROOT/'VDTPolicyTransition.c').read_text()
        self.assertIn('dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)',s)
        self.assertIn('reconcile_unreported_processes_sync();',s)
        self.assertIn('vdt_target_instance_is_current',s)
        self.assertIn('vdt_target_is_current',s)
        self.assertIn('managed_process_targets()[instanceKey] = target;',s)
        self.assertIn('[managed_process_targets() removeObjectForKey:instanceKey]',s)
        self.assertIn('identityRejected',pm)
        self.assertIn('retirementFailed',pm)
        self.assertIn('identityIsCurrent(pid, operations, &result)',policy)
        self.assertNotIn('CFBundleIdentifier',s[s.index('// Every other injected process self-reports'):])
    def test_errno_snapshot_is_compiled_only_for_diagnostics(self):
        expected=subprocess.check_output(['git','show',BASE+':VDTProcessManager.mm'],cwd=ROOT)
        wanted=expected.replace(b'    int operationErrno = errno;',b'#if VDT_DIAGNOSTICS_ENABLED\n    int operationErrno = errno;\n#endif')
        self.assertNotEqual(wanted,expected)
        self.assertEqual((ROOT/'VDTProcessManager.mm').read_bytes(),wanted)
        source=wanted.decode()
        self.assertEqual(source.count('#if VDT_DIAGNOSTICS_ENABLED\n    int operationErrno = errno;'),1)
        self.assertGreaterEqual(source.count('@"errno": @(operationErrno)'),3)

    def test_cpu_runtime_binary_source_freeze(self):
        for name in CPU_FROZEN:
            with self.subTest(file=name):
                self.assertEqual(without_nice(name,(ROOT/name).read_bytes()),subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT))

if __name__=='__main__':unittest.main(verbosity=2)
