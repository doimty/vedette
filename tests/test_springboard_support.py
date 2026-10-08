#!/usr/bin/env python3
"""SpringBoard catalogue/identity regressions. Native resolver tests run in CI."""
from pathlib import Path
import os,subprocess,tempfile,unittest
from springboard_delta import ROOT,BASE,FILES,without_springboard
from release_delta import without_release
class SpringBoardSupport(unittest.TestCase):
    def test_exact_scope_preserves_original_cpu_and_ui_behavior(self):
        for name in FILES:
            data=(ROOT/name).read_bytes()
            self.assertEqual(without_springboard(name,data),subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT))
            with self.assertRaises(AssertionError):without_springboard(name,data+b'\n// unrelated\n')
        for name in ['Vedette.xm','VDTPolicyTransition.c','VDTProcessIdentity.c','VDTNiceRuntime.mm','VDTNicePolicy.c',
                     'VDTNiceShared.mm','VDTNiceStore.c','vedetteprefs/VDTProcessConfiguration.m','vedetteprefs/VDTNicePreferences.m',
                     'vedetteprefs/ChoicyPreferences/CHPDaemonListController.m','layout/DEBIAN/prerm','nicectl/Entitlements.plist']:
            expected=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
            self.assertEqual(without_release(name,(ROOT/name).read_bytes()),expected,name)
    def test_reserved_row_is_unique_and_not_an_enabled_rule(self):
        source=(ROOT/'vedetteprefs/ChoicyPreferences/CHPDaemonList.m').read_text()
        self.assertEqual(source.count('[daemonListM addObject:springBoard]'),1)
        seed=source[source.index('// Known system entry'):source.index('for(NSURL* daemonPlistURL in daemonPlists)')]
        self.assertIn('@VDT_SPRINGBOARD_EXECUTABLE',seed)
        for forbidden in ['@YES','setValueForProcess','writeToFile','getPrefs']:
            self.assertNotIn(forbidden,seed)
        self.assertNotIn('![info.plistIdentifier isEqualToString:@"com.apple.SpringBoard"]',source)
        self.assertIn('if(![self daemonList:daemonListM containsDisplayName:info.displayName])',source)
        for kept in ['hasSuffix:@"Jetsam"','hasSuffix:@"SimulateCrash"','hasSuffix:@"_v2"']:
            self.assertIn(kept,source)
    def test_only_reserved_path_can_skip_app_lookup(self):
        source=(ROOT/'VDTProcessManager.mm').read_text()
        special=source[source.index('// Only the canonical system executable'):source.index('// A verified App identity')]
        self.assertIn('VDTSpringBoardPathMatches(executablePath.UTF8String)',special)
        self.assertIn('VDTSpringBoardRuleMatches(identifier.UTF8String, executablePath.UTF8String)',special)
        self.assertIn('break;',special)
        self.assertIn('if (executablePath && !matched)',source)
        self.assertIn('if (!matched && !resolvedAsApplication && daemonConfigs.count > 0)',source)
        self.assertIn('if (!configured || VDTSpringBoardRuleName(configured)) continue;',source)
        self.assertNotIn('realpath(',special)
    def test_confirmation_and_defaults_are_still_required(self):
        cpu=(ROOT/'vedetteprefs/VDTProcessConfiguration.m').read_text()
        nice=(ROOT/'vedetteprefs/VDTNicePreferences.m').read_text()
        self.assertIn('@"SpringBoard"',cpu)
        self.assertIn('[self shouldAskForConsent:[self validIdentifier]] && [value boolValue]',cpu)
        self.assertIn('@"com.apple.springboard"',nice)
        self.assertIn('enabling && [self isSensitiveTarget]',nice)
        self.assertIn('[enabled setProperty:@NO forKey:@"default"]',nice)
        self.assertIn('[monitorEnabledSpec setProperty:@NO forKey:@"default"]',cpu)
    def test_real_identity_helper_and_unsafe_mutation(self):
        original=(ROOT/'VDTSpringBoardIdentity.h').read_text()
        test=(ROOT/'tests/test_springboard_identity.c').read_text()
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);(root/'tests').mkdir();(root/'tests/test.c').write_text(test)
            header=root/'VDTSpringBoardIdentity.h';binary=root/'test'
            def compile_and_run():
                subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O2','-Wall','-Wextra','-Werror',str(root/'tests/test.c'),'-o',str(binary)],check=True)
                return subprocess.run([str(binary)],capture_output=True,text=True)
            header.write_text(original);positive=compile_and_run();self.assertEqual(positive.returncode,0,positive.stderr)
            self.assertIn('43 checks passed',positive.stdout)
            bad=original.replace('strcmp(path, VDT_SPRINGBOARD_EXECUTABLE) == 0','strstr(path, VDT_SPRINGBOARD_EXECUTABLE) != NULL')
            self.assertNotEqual(original,bad);header.write_text(bad)
            self.assertNotEqual(compile_and_run().returncode,0,'unsafe prefix/rootless mirror matcher passed')
    def test_native_gate_uses_actual_old_resolver_as_negative(self):
        runner=(ROOT/'tests/run_springboard_native_tests.sh').read_text()
        self.assertIn(BASE+':VDTProcessManager.mm',runner)
        self.assertIn("grep -Fq 'targets.count==1'",runner)
        self.assertIn('exit 77',runner)
        self.assertIn('sudo bash tests/run_springboard_native_tests.sh',(ROOT/'.github/workflows/roothide-build.yml').read_text())
        native=(ROOT/'tests/test_springboard_native.mm').read_text()
        for expected in ['#import VDT_RESOLVER_IMPLEMENTATION','#import "../VDTNiceRuntime.mm"','MockStart=101',
                         'MockPath=NULL','nice->records.count==0','CpuCalls==0','LsCalls==0']:
            self.assertIn(expected,native)

if __name__=='__main__':unittest.main(verbosity=2)
