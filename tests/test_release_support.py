#!/usr/bin/env python3
from pathlib import Path
import importlib.util,os,shlex,shutil,subprocess,tempfile,unittest
from release_delta import NAMES,ROOT,BASE,without_release
from canonicalize_nice_deb import canonicalize,records
from test_nice_tool import fat
from verify_nice_tool import verify_tool
spec=importlib.util.spec_from_file_location('stage_release',ROOT/'ci/stage_release.py')
stage_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(stage_module)

def fixture(stage,scheme):
    (stage/'usr/libexec').mkdir(parents=True);(stage/'DEBIAN').mkdir()
    (stage/'usr/libexec/vedette-nicectl').write_bytes(b'not executed test bytes');(stage/'usr/libexec/vedette-nicectl').chmod(0o755)
    arch='iphoneos-arm64' if scheme=='rootless' else 'iphoneos-arm64e'
    text=(ROOT/'control').read_text().replace('Architecture: iphoneos-arm\n','Architecture: '+arch+'\n')+'\n'
    (stage/'DEBIAN/control').write_text(text)
    for name in ('postinst','prerm','postrm'):shutil.copy2(ROOT/'layout/DEBIAN'/name,stage/'DEBIAN'/name)

class ReleaseSupport(unittest.TestCase):
    def test_exact_metadata_changes_and_runtime_freeze(self):
        for name in NAMES:
            now=(ROOT/name).read_bytes();without_release(name,now)
            with self.assertRaises(AssertionError):without_release(name,now+b'\nextra\n')
        old_files=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE],cwd=ROOT,text=True).splitlines()
        for name in old_files:
            if (name.startswith('tests/') or name in NAMES):continue
            if Path(name).suffix in ('.xm','.mm','.m','.c','.h','.plist') or name.startswith('layout/'):
                self.assertEqual(without_release(name,(ROOT/name).read_bytes()),subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT),name)
    def test_two_staged_schemes_keep_arch_and_dependencies_separate(self):
        with tempfile.TemporaryDirectory() as td:
            for scheme in ('roothide','rootless'):
                stage=Path(td)/scheme;fixture(stage,scheme)
                stage_module.stage_release(stage,scheme)
                text=(stage/'DEBIAN/control').read_text()
                self.assertEqual('roothide,' in text,scheme=='roothide')
                self.assertIn('firmware (>= 15.0)',text)
                for hook in ('postinst','prerm'):
                    folder='layout-rootless' if scheme=='rootless' else 'layout'
                    self.assertEqual((stage/'DEBIAN'/hook).read_bytes(),(ROOT/folder/'DEBIAN'/hook).read_bytes())
    def test_mismatched_scheme_or_version_fails_before_replacing_control(self):
        with tempfile.TemporaryDirectory() as td:
            stage=Path(td)/'stage';fixture(stage,'rootless');before=(stage/'DEBIAN/control').read_bytes()
            with self.assertRaises(ValueError):stage_module.stage_release(stage,'roothide')
            self.assertEqual((stage/'DEBIAN/control').read_bytes(),before)
            (stage/'DEBIAN/control').write_bytes(before.replace(b'1.1.12-2',b'1.1.11-1+nice2'))
            with self.assertRaises(ValueError):stage_module.stage_release(stage,'rootless')
    def test_rootless_archive_repack_preserves_bytes_and_modes(self):
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);stage=base/'stage';fixture(stage,'rootless');stage_module.stage_release(stage,'rootless')
            # Theos wraps the prefix AFTER the stage hook, not before it.
            (stage/'var/jb').mkdir(parents=True);shutil.move(stage/'usr',stage/'var/jb/usr')
            package=base/'rootless.deb'
            subprocess.run(['dpkg-deb','-b',str(stage),str(package)],check=True,stdout=subprocess.DEVNULL)
            before={a:records(package,a) for a in ('fsys','ctrl')}
            canonicalize(package,'rootless')
            after={a:records(package,a,True) for a in ('fsys','ctrl')};self.assertEqual(before,after)
            self.assertIn('var/jb/usr/libexec/vedette-nicectl',after['fsys'])
            with self.assertRaises(AssertionError):canonicalize(package,'roothide')
    def test_foreign_runtime_dependency_is_rejected(self):
        rootless=fat(dependency='/usr/lib/libSystem.B.dylib');roothide=fat()
        verify_tool(rootless,'rootless');verify_tool(roothide,'roothide')
        with self.assertRaises(AssertionError):verify_tool(roothide,'rootless')
        with self.assertRaises(AssertionError):verify_tool(rootless,'roothide')
    def test_stable_version_upgrades_all_candidate_versions(self):
        for version in ('1.1.12-1','1.1.10-1+ui21','1.1.11-1+nice1','1.1.11-1+nice2'):
            subprocess.run(['dpkg','--compare-versions','1.1.12-2','gt',version],check=True)
        text=(ROOT/'control').read_text();self.assertIn('CPU 限制和 nice 调度优先级',text)
        self.assertIn('https://doimty.github.io/depictions/com.doimty.vedette/',text)
    def test_rootless_hooks_fail_closed_without_jbroot_command(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);log=root/'log';ctl=root/'ctl';tools=root/'tools';tools.mkdir()
            ctl.write_text('#!/bin/sh\necho "$1" >> "$FIXTURE_LOG"\nexit "$FIXTURE_EXIT"\n');ctl.chmod(0o755)
            kill=tools/'killall';kill.write_text('#!/bin/sh\necho kill >> "$FIXTURE_LOG"\n');kill.chmod(0o755)
            for name in ('postinst','prerm'):
                text=(ROOT/'layout-rootless/DEBIAN'/name).read_text()
                self.assertNotIn('jbroot',text);self.assertNotIn('rm ',text)
                self.assertEqual(text.count('ctl=/var/jb/usr/libexec/vedette-nicectl'),1)
                path=root/name;path.write_text(text.replace('ctl=/var/jb/usr/libexec/vedette-nicectl','ctl='+shlex.quote(str(ctl))))
                for code in ('0','23'):
                    if log.exists():log.unlink()
                    env={**os.environ,'PATH':str(tools)+':'+os.environ['PATH'],'FIXTURE_LOG':str(log),'FIXTURE_EXIT':code}
                    result=subprocess.run(['bash',str(path),'remove'],env=env,capture_output=True)
                    self.assertEqual(result.returncode==0,code=='0')
                    calls=log.read_text().splitlines()
                    self.assertEqual(calls[0],'resume' if name=='postinst' else 'restore-for-removal')
                    self.assertEqual('kill' in calls,name=='postinst' and code=='0')

if __name__=='__main__':unittest.main(verbosity=2)
