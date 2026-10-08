#!/usr/bin/env python3
"""Additive nice contracts + executable negative controls. Not UIKit proof."""
from pathlib import Path
import io, os, resource, subprocess, tarfile, tempfile, unittest
from nice_delta import BASE, NAMES, ROOT, without_nice
from verify_nice_archive import validate

def source(name): return (ROOT/name).read_text()
def baseline(name): return subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
class NiceContracts(unittest.TestCase):
    def test_legacy_changes_are_exact_additions(self):
        for name in sorted(NAMES):
            data=(ROOT/name).read_bytes()
            self.assertEqual(without_nice(name,data),baseline(name))
            with self.assertRaises(AssertionError): without_nice(name,data+b'\n// unrelated change\n')
    def test_cpu_implementation_is_byte_frozen(self):
        for name in ['VDTProcessManager.mm','VDTProcessManager.h','VDTProcessIdentity.c','VDTProcessIdentity.h',
            'VDTPolicyTransition.c','VDTPolicyTransition.h','Common.h','VDTShared.mm','VDTShared.h',
            'Vedette.plist','vedetteprefs/VDTActionListController.m','layout/DEBIAN/postrm']:
            self.assertEqual(without_nice(name,(ROOT/name).read_bytes()),baseline(name),name)
    def test_nice_is_independent_and_never_spawns_a_service(self):
        runtime=source('VDTNiceRuntime.mm'); shared=source('VDTNiceShared.mm')
        for forbidden in ['vdt_apply_target(', 'proc_setcpu', 'memorystatus_control', 'NSTimer', 'dispatch_source_create', 'fork(', 'posix_spawn', 'system(']:
            self.assertNotIn(forbidden,runtime)
        self.assertNotIn('entry[@"enabled"]',shared)
        self.assertIn('global && requested && valid',shared)
        self.assertIn('cpuEnabled || niceEnabled',source('vedetteprefs/VDTListPresentation.m'))
    def test_native_errno_and_identity_guards(self):
        r=source('VDTNiceRuntime.mm')
        self.assertIn('errno = 0; int n = getpriority',r)
        self.assertIn('if (n == -1 && error) return error;',r)
        self.assertIn('pid <= 1 || pid == getpid()',r)
        self.assertIn('errno == ESRCH ? VDTNiceIdentityGone : VDTNiceIdentityUnavailableValue',r)
        self.assertIn('vdt_target_is_current(target)',r)
        self.assertIn('PRIO_MIN == -20 && PRIO_MAX == 20',r)
    def test_manual_retry_never_reapplies_cpu(self):
        s=source('Vedette.xm'); start=s.index('static void niceRefreshCallback(')
        body=s[start:s.index('static NSString *current_executable_path',start)]
        self.assertIn('nice_refresh_scheduled',body)
        self.assertNotIn('vdt_apply_target',body)
        self.assertNotIn('reloadPrefsSync',body)
        self.assertNotIn('vdt_nice_restore_all',body)
        self.assertIn('vdt_nice_apply(target)',body)
        self.assertEqual(s.count('static void schedule_launch_catch_up_sync()'),1)
    def test_journal_and_receipt_durability(self):
        r=source('VDTNiceRuntime.mm'); s=source('VDTNiceShared.mm')
        self.assertIn('if (!error) records = next;',r)
        self.assertIn('if (records.count) loadError = ENOENT;',r)
        self.assertIn('!receiptDirty',r)
        self.assertIn('records.count == 0',r)
        self.assertIn('VDTNiceMaximumRecords',r)
        self.assertIn('![raw[@"boot"] isEqual:boot]',r)
        self.assertIn('@"value", @"valid", @"revision", @"enabled", @"requestedEnabled"',s)
        self.assertLess(s.index('if (![data writeToFile:PREFS_PATH options:NSDataWritingAtomic error:error]) return NO;'),s.index('notify_post([PREFS_CHANGED_NN UTF8String]);'))
    def test_ui_selection_and_build_reentrancy(self):
        ui=source('vedetteprefs/VDTNicePreferences.m')
        build=ui[ui.index('- (NSArray<PSSpecifier *> *)specifiers'):ui.index('- (id)readPreferenceValue:')]
        self.assertLess(build.index('[self refreshMatchingStatus];'),build.index('_buildingSpecifiers = NO;'))
        self.assertIn('nice <= VDTNiceMaximum',ui)
        self.assertIn('VDTNiceMinimum',ui)
        self.assertIn('detail:[VDTNiceValueListController class] cell:PSLinkListCell',ui)
        self.assertIn('VDTNiceSavePreference(',ui)
        self.assertNotIn('setValueForProcessConfigKey(',ui)
        self.assertIn('notify_cancel(_notifyToken)',ui)
        self.assertIn('__weak VDTNicePreferences',ui)
        self.assertIn('VDTNiceParseValue(value, &parsed) ? @(parsed) : @0',ui)
    def test_removal_is_best_effort_and_does_not_block_package_removal(self):
        cli=source('nicectl/main.mm'); runtime=source('VDTNiceRuntime.mm'); prerm=source('layout/DEBIAN/prerm'); rootless=source('layout-rootless/DEBIAN/prerm')
        self.assertIn('getuid() != 0 || geteuid() != 0',cli)
        self.assertIn('VDT_NICE_REQUEST',cli)
        self.assertIn('receipt[@"restoreNonce"] isEqual:nonce',cli)
        self.assertIn('receipt[@"storeError"] isEqual:@0',cli)
        self.assertIn('now - start >= 8.0',cli)
        self.assertNotIn('setpriority(',cli)
        self.assertIn('paused = YES;',runtime)
        self.assertIn('paused || ![rule[@"enabled"] boolValue]',runtime)
        self.assertIn('"$ctl" restore-for-removal',prerm)
        self.assertIn('"$ctl" restore-for-removal',rootless)
        self.assertNotIn('killall',prerm+rootless)
        for script in (prerm,rootless,source('layout/DEBIAN/postinst'),source('layout-rootless/DEBIAN/postinst')):
            self.assertNotIn('exit 1',script)
            self.assertIn('continuing package',script)
        self.assertIn('continue_after_nice_failure',prerm)
        self.assertIn('continue_after_nice_failure',rootless)
        self.assertIn('never leave dpkg half-configured',source('layout/DEBIAN/postinst'))
    def test_archive_negative_controls(self):
        def fixture(uid=0,mode=0o755,kind=tarfile.REGTYPE,duplicate=False):
            out=io.BytesIO()
            with tarfile.open(fileobj=out,mode='w') as t:
                for _ in range(2 if duplicate else 1):
                    m=tarfile.TarInfo('./usr/libexec/vedette-nicectl');m.uid=uid;m.gid=0;m.mode=mode;m.type=kind
                    t.addfile(m)
            return out.getvalue()
        req={'usr/libexec/vedette-nicectl':0o755}
        validate(fixture(),req)
        for bad in [fixture(uid=501),fixture(mode=0o4755),fixture(kind=tarfile.SYMTYPE),fixture(duplicate=True),b'']:
            with self.assertRaises((AssertionError,tarfile.ReadError)): validate(bad,req)
    def test_executable_policy_mutations_are_rejected(self):
        original=source('VDTNicePolicy.c')
        mutations=[('if (error != 0)', 'if (error < 0)'),
                   ('if (readback != desired)', 'if (false)'),
                   ('if (wasCaptured && !valueIsKnown(record, current))', 'if (false)')]
        def no_core(): resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        with tempfile.TemporaryDirectory() as tmp:
            for i,(old,new) in enumerate(mutations):
                with self.subTest(mutation=old):
                    self.assertIn(old,original)
                    mutant=Path(tmp)/f'mutant{i}.c';binary=Path(tmp)/f'mutant{i}'
                    mutant.write_text(original.replace(old,new,1))
                    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O2','-Wall','-Wextra','-Werror',
                        '-I',str(ROOT),str(mutant),str(ROOT/'tests/test_nice_policy.c'),'-o',str(binary)],check=True)
                    result=subprocess.run([str(binary)],capture_output=True,preexec_fn=no_core)
                    self.assertNotEqual(result.returncode,0,'bad implementation passed real callback tests')
    def test_package_scripts_stop_on_failure_with_all_commands_mocked(self):
        import shutil
        bash=shutil.which('bash'); self.assertIsNotNone(bash)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); tools=root/'tools';tools.mkdir(); libexec=root/'usr/libexec';libexec.mkdir(parents=True)
            scripts={tools/'jbroot':'#!/bin/sh\nprintf "%s\\n" "$NICE_TEST_ROOT"\n',
                     tools/'killall':'#!/bin/sh\necho kill >> "$NICE_TEST_LOG"\n',
                     libexec/'vedette-nicectl':'#!/bin/sh\necho "$1" >> "$NICE_TEST_LOG"\nexit "$NICE_TEST_EXIT"\n'}
            for path,text in scripts.items(): path.write_text(text);path.chmod(0o755)
            log=root/'calls';env={**os.environ,'PATH':str(tools)+os.pathsep+os.environ['PATH'],
                'NICE_TEST_ROOT':str(root),'NICE_TEST_LOG':str(log),'NICE_TEST_EXIT':'0'}
            def run(name,action): return subprocess.run([bash,str(ROOT/'layout/DEBIAN'/name),action],env=env,capture_output=True)
            self.assertEqual(run('prerm','remove').returncode,0)
            self.assertEqual(log.read_text().splitlines(),['restore-for-removal'])
            self.assertEqual(run('prerm','upgrade').returncode,0)
            self.assertEqual(log.read_text().splitlines(),['restore-for-removal'])
            env['NICE_TEST_EXIT']='13';failed_remove=run('prerm','remove');self.assertEqual(failed_remove.returncode,0)
            self.assertIn(b'continuing package removal',failed_remove.stderr)
            self.assertEqual(log.read_text().splitlines(),['restore-for-removal','restore-for-removal'])
            log.unlink()
            # A failing resume must not leave the package half-configured either.
            failed_configure=run('postinst','configure');self.assertEqual(failed_configure.returncode,0)
            self.assertIn(b'continuing package configuration',failed_configure.stderr)
            self.assertEqual(log.read_text().splitlines(),['resume','kill'])
            log.unlink();env['NICE_TEST_EXIT']='0'
            self.assertEqual(run('postinst','configure').returncode,0)
            self.assertEqual(log.read_text().splitlines(),['resume','kill'])
    def test_cloud_native_execution_is_explicit(self):
        w=source('.github/workflows/roothide-build.yml'); runner=source('tests/run_nice_native_tests.sh')
        self.assertIn('sudo bash tests/run_nice_native_tests.sh',w)
        self.assertIn('verify_nice_archive.py',w)
        self.assertIn('exit 77',runner)
        self.assertNotIn('sudo ',runner)
        self.assertIn('fake kernel',source('tests/test_nice_native.mm'))

if __name__=='__main__': unittest.main(verbosity=2)
