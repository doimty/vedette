#!/usr/bin/env python3
"""Production Foundation directory cache integration; Linux explicitly SKIP."""
import argparse,platform,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--require-native',action='store_true');p.add_argument('--sdk',type=Path)
a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='vdt-catalog-native-') as tmp:
 out=Path(tmp)
 if platform.system()!='Darwin':
  if a.sdk:
   for arch in ('arm64','arm64e'):
    subprocess.run(['clang++','-target',arch+'-apple-ios15.0','-isysroot',str(a.sdk),'-std=c++17','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-I'+str(ROOT/'tests/native_stubs'),'-I'+str(ROOT),'-fsyntax-only',str(ROOT/'tests/test_list_catalog_native.mm')],check=True)
   print('PASS SDK syntax for catalog fixture both architectures, NOT native execution')
  print('SKIP: production Foundation catalog requires Darwin; not PASS')
  raise SystemExit(1 if a.require_native else 77)
 flags=['-Wall','-Wextra','-Werror','-I'+str(ROOT/'tests/native_stubs'),'-I'+str(ROOT)]
 subprocess.run(['xcrun','clang','-std=c11',*flags,'-c',str(ROOT/'VDTBundleRules.c'),'-o',str(out/'rules.o')],check=True)
 subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks',*flags,'-framework','Foundation',str(ROOT/'tests/test_list_catalog_native.mm'),str(ROOT/'VDTBundleIdentity.mm'),str(out/'rules.o'),'-o',str(out/'baseline')],check=True)
 subprocess.run([str(out/'baseline')],check=True)
 print('PASS real catalog Foundation baseline; fake LS/executor, no UIKit/kernel/device')
