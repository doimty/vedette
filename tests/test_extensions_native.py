#!/usr/bin/env python3
"""Actual production Foundation execution on macOS; never label iSH as native."""
from pathlib import Path
import argparse,platform,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--require-native',action='store_true');args=p.parse_args()
if platform.system()!='Darwin':
    print('SKIP: real Foundation execution needs macOS; iSH/Linux source/C checks are separate')
    raise SystemExit(1 if args.require_native else 77)
with tempfile.TemporaryDirectory(prefix='vdt-extension-native-') as tmp:
    output=Path(tmp)/'fixture'
    command=['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',
             '-I'+str(ROOT),'-I'+str(ROOT/'tests/extension_stubs'),
             '-DCFNotificationCenterPostNotification=VDTTestPostNotification',
             str(ROOT/'VDTBundleRules.c'),str(ROOT/'VDTBundleIdentity.mm'),str(ROOT/'VDTShared.mm'),
             str(ROOT/'tests/test_extensions_native.mm'),'-framework','Foundation','-o',str(output)]
    # Compile the C source separately to preserve a real C translation unit.
    object_file=Path(tmp)/'rules.o'
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-I'+str(ROOT),
                    '-c',str(ROOT/'VDTBundleRules.c'),'-o',str(object_file)],check=True)
    command[command.index(str(ROOT/'VDTBundleRules.c'))]=str(object_file)
    subprocess.run(command,check=True)
    subprocess.run([str(output)],check=True)
