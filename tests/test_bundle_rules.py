#!/usr/bin/env python3
"""Execute production C kernel, then prove regressions fail real test cases."""
from pathlib import Path
import os, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class BundleRules(unittest.TestCase):
    def run_kernel(self, source, success):
        with tempfile.TemporaryDirectory(prefix='vdt-bundle-') as tmp:
            d=Path(tmp); (d/'kernel.c').write_text(source)
            cc=os.environ.get('CC','cc')
            subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT),
                            str(d/'kernel.c'),str(ROOT/'tests/test_bundle_rules.c'),'-o',str(d/'test')],check=True)
            r=subprocess.run([str(d/'test')],capture_output=True,text=True)
            self.assertEqual(r.returncode == 0,success,r.stdout+r.stderr)
    def test_production_precedence_and_paths(self):
        self.run_kernel((ROOT/'VDTBundleRules.c').read_text(),True)
    def test_effective_mutants_are_rejected(self):
        source=(ROOT/'VDTBundleRules.c').read_text()
        replacements=[
          ('if (!extensionIdentityValid) return VDTBundleRuleNone;',
           'if (!extensionIdentityValid) return VDTBundleRuleDaemon;'),
          ('if (hasExtensionConfig) return VDTBundleRuleExtension;',
           'if (hasExtensionConfig && hasAppConfig) return VDTBundleRuleExtension;'),
          ('return insideApp && hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleNone;',
           'return insideApp && hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleDaemon;'),
          ('if (insideApp) return hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleNone;',
           'if (insideApp) return hasAppConfig ? VDTBundleRuleApp : VDTBundleRuleDaemon;'),
          ('size_t parentEnd = (size_t)(last - path);','size_t parentEnd = length + (size_t)(last - last);'),
          ('if (!matchedEnd || matchedEnd >= outSize) return false;',
           'if (!matchedEnd || matchedEnd > outSize) return false;'),
          ('strcmp(name, ".") != 0 && strcmp(name, "..") != 0;',
           'strcmp(name, ".") != 0;')]
        for old,new in replacements:
            with self.subTest(mutant=old):
                self.assertEqual(source.count(old),1)
                self.run_kernel(source.replace(old,new,1),False)

if __name__=='__main__': unittest.main(verbosity=2)
