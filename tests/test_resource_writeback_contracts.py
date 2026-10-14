#!/usr/bin/env python3
"""Source contracts + compiled fixed-transport negatives; NOT Foundation/device."""
from pathlib import Path
import re, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]
class Writeback(unittest.TestCase):
 def test_frozen_cpu_nice_and_lists(self):
  names=['VDTNiceRuntime.mm','VDTNicePolicy.c','VDTNiceStore.c','VDTPolicyTransition.c','VDTProcessIdentity.c',
   'vedetteprefs/VDTExtensionListController.m','vedetteprefs/ChoicyPreferences/CHPDaemonListController.m']
  for name in names:
   self.assertEqual((ROOT/name).read_bytes(),subprocess.check_output(['git','show','4c9af10:'+name],cwd=ROOT),name)
 def test_runtime_write_ahead_and_restore_authority(self):
  t=(ROOT/'VDTResourceRuntime.mm').read_text()
  start=t.index('static BOOL resourceExecuteSide(');end=t.index('static int32_t resourceDarwinMajor',start);body=t[start:end]
  self.assertLess(body.index('if (!resourcePersist()) { detail[name] = @"store-error"; return NO; }'),body.index('VDTApplyExecute('))
  for s in ('@"original": current', 'target->hasLastPair', 'resourceDue'):
   self.assertIn(s,t if s!='target->hasLastPair' else (ROOT/'VDTResourceApply.c').read_text())
  self.assertIn('!resourceWrites || resourcePaused',t)
  self.assertIn('request[@"boot"] isEqual:resourceBoot',t)
  self.assertIn('resourceRestoreNonce = request[@"nonce"]',t)
  self.assertIn('return resourceLoaded && !resourceStoreError && !resourceControlError && resourceRecords.count == 0;',t)
  self.assertNotIn('darwinMajor != 21',t)
  self.assertIn('VDTJetsamMaxBand(resourceDarwin, &maximum)',t)
  self.assertIn('@"darwinMajor": @(resourceDarwin)',t)
  self.assertIn('[savedMajor intValue] != resourceDarwin',t)
  self.assertIn('resourceRecords.count >= 2048',t)
  self.assertIn('resourceGone(target)',t)
  self.assertIn('!restore && ![current isEqual:wanted] && [side[@"phase"] isEqual:@"unverified"]',t)
 def test_opt_in_and_raw_version_are_not_invented(self):
  t=(ROOT/'VDTResourceShared.mm').read_text();m=(ROOT/'VDTProcessManager.mm').read_text()
  self.assertIn('resourceBoolean(prefs[@"enabled"], YES)',t)
  gate=t[t.index('BOOL VDTResourceWriteEnabled'):t.index('NSDictionary *VDTResourceConfiguration')]
  self.assertNotIn('resourceWriteEnabled',gate,'the write gate must not consult the removed opt-in key')
  self.assertNotIn('VDTResourceSetWriteEnabled',t)
  self.assertNotIn('Enable resource writes',(ROOT/'vedetteprefs/VDTRootListController.m').read_text())
  self.assertIn('row[@"sourceDarwinMajor"] = @(major)',t)
  self.assertIn('rawSourceDarwinMajor = resource_policy_integer(rule[@"sourceDarwinMajor"])',m)
  self.assertNotIn('rawSourceDarwinMajor = resource_policy_integer(@(vdt_target_darwin_major()))',m)
 def test_backend_version_and_removal_reachable(self):
  t=(ROOT/'VDTResourceSystemBackend.mm').read_text()
  self.assertIn('bool enabled = supported(NULL);',t)
  self.assertIn('return geteuid() == 0;',t)
  body=t[t.index('static bool supported('):t.index('static bool identity(')]
  self.assertNotIn('sysctlbyname',body)
  for blocked in ('VDTResourceSystemVersionAllowed', 'kern.osversion', 'kern.version', 'hw.machine', '19B81', 'iPhone14,3'):
   self.assertNotIn(blocked,t)
  self.assertIn('!TARGET_OS_SIMULATOR',t)
  for scheme in ('layout','layout-rootless'):
   self.assertIn('"$ctl" resource-restore-for-removal', (ROOT/scheme/'DEBIAN/prerm').read_text())
   self.assertIn('"$ctl" resource-resume',(ROOT/scheme/'DEBIAN/postinst').read_text())
  self.assertIn('sudo python3 -B tests/test_resource_runtime_native.py --require-native',(ROOT/'ci/run_host_tests.sh').read_text())
 def test_transport_and_compiled_negatives(self):
  source=(ROOT/'VDTResourceSystemIO.c').read_text()
  mutations=[('access gate','if (!io->supported(io->opaque)) {','if (false) {'),
   ('reject modern backend','!VDTJetsamMaxBand(io->darwinMajor, maximum)',
    '(!VDTJetsamMaxBand(io->darwinMajor, maximum) || io->darwinMajor != 21)'),
   ('old 21-only readback','value.priority > maximum','value.priority > (maximum > 21 ? 21 : maximum)'),
   ('old 21-only SET','band > maximum','band > (maximum > 21 ? 21 : maximum)'),
   ('identity gate','if (!io->identity(io->opaque, pid)) {','if (false) {'),
   ('userdata','value.userData != 0','false'),
   ('size','length != sizeof(value)','false'),
   ('PID','value.pid != pid','false')]
  with tempfile.TemporaryDirectory(prefix='vdt-resource-io-') as d:
   d=Path(d)
   for label,old,new in [('baseline',None,None)]+mutations:
    text=source
    if old:
     self.assertEqual(text.count(old),1,label);text=text.replace(old,new,1)
    path=d/'io.c';path.write_text(text);out=d/'test'
    c=subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I',str(ROOT),str(path),
      str(ROOT/'VDTProcessIdentity.c'),str(ROOT/'VDTMemoryPolicy.c'),str(ROOT/'VDTJetsamPolicy.c'),
      str(ROOT/'tests/test_resource_system_io.c'),'-o',str(out)],capture_output=True,text=True)
    self.assertEqual(c.returncode,0,'COMPILE FAILURE, not killed: '+label+'\n'+c.stderr)
    r=subprocess.run([str(out)],cwd=d,capture_output=True,text=True)
    if old:
     self.assertNotEqual(r.returncode,0,'SURVIVED '+label);self.assertIn('assert',r.stderr.lower());print('KILLED transport:',label,flush=True)
    else:self.assertEqual(r.returncode,0,r.stderr);print(r.stdout.strip(),flush=True)
if __name__=='__main__':unittest.main(verbosity=2)
