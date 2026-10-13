#!/usr/bin/env python3
"""Production C retry policy and compiler-accepted runtime mutant rejection."""
import os,resource,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class NiceAttemptTests(unittest.TestCase):
 def test_production_and_mutants(self):
  header=(ROOT/'VDTNiceAttempt.h').read_text()
  changes={
   'unbounded':('enum { VDTNiceAttemptLimit = 3 };','enum { VDTNiceAttemptLimit = 300 };'),
   'ignore_deadline':('now >= state.due','now >= 0'),
   'retry_conflict':('if (outcome == VDTNiceIdentityUnavailable','if (outcome == VDTNiceConflict || outcome == VDTNiceIdentityUnavailable'),
   'retry_permission':('return error == EINTR','return error == EPERM || error == EINTR')}
  def no_core(): resource.setrlimit(resource.RLIMIT_CORE,(0,0))
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);cases={'production':header}
   for name,(old,new) in changes.items():
    self.assertEqual(header.count(old),1);cases[name]=header.replace(old,new,1)
   for name,text in cases.items():
    with self.subTest(case=name):
     (p/'VDTNiceAttempt.h').write_text(text)
     (p/'test.c').write_bytes((ROOT/'tests/test_nice_attempt.c').read_bytes())
     exe=p/name
     subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(p),'-I'+str(ROOT),str(p/'test.c'),'-o',str(exe)],check=True,capture_output=True)
     run=subprocess.run([str(exe)],capture_output=True,preexec_fn=no_core)
     if name=='production': self.assertEqual(run.returncode,0,run.stderr)
     else:
      self.assertNotEqual(run.returncode,0,'mutant survived');self.assertIn(b'Assertion',run.stderr)
 def test_production_wiring(self):
  r=(ROOT/'VDTNiceRuntime.mm').read_text();l=(ROOT/'Vedette.xm').read_text()
  self.assertIn('VDTNiceAttemptAllowed(attempt, now)',r)
  self.assertIn('VDTNiceAttemptFinished(attempt, [self retryClock], result.outcome, result.error)',r)
  self.assertIn('[attemptStates removeAllObjects]',r)
  self.assertNotIn('row[@"checkedAt"] = @(NSDate.date.timeIntervalSince1970)',r)
  block=l[l.index('static void schedule_nice_retry_sync'):l.index('static void apply_nice_targets_sync')]
  for illegal in ('vdt_apply_target','reloadPrefsSync','vdt_nice_resolve_targets','getPrefs('): self.assertNotIn(illegal,block)
  self.assertIn('generation != nice_retry_generation',block)
  self.assertIn('vdt_nice_reconcile()',block)
  self.assertIn('MAX(0.05, delay)',block)
if __name__=='__main__':unittest.main(verbosity=2)
