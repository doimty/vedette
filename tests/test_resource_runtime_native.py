#!/usr/bin/env python3
"""Actual Foundation coordinator harness. iSH: SDK syntax only, explicit 77.
Darwin: root-owned temp storage, fake kernel; never run memorystatus on device.
"""
import argparse, os, platform, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
C=['VDTResourceApply.c','VDTMemoryPolicy.c','VDTJetsamPolicy.c','VDTProcessIdentity.c','VDTNiceStore.c','VDTBundleRules.c']
MM=['VDTShared.mm','VDTNiceShared.mm','VDTResourceShared.mm','VDTBundleIdentity.mm','tests/test_resource_runtime_native.mm']
def run(args):
    print('+',' '.join(map(str,args)),flush=True)
    subprocess.run(list(map(str,args)),check=True,cwd=ROOT)
def main():
    source=(ROOT/'VDTResourceRuntime.mm').read_text()
    mutants=[
        ('skip-write-ahead', 'if (!resourcePersist()) { detail[name] = @"store-error"; return NO; }',
         'if (false && !resourcePersist()) { detail[name] = @"store-error"; return NO; }', 'writes==0 && resourceStoreError==EIO'),
        ('overwrite-original', '    id wanted = restore ? side[@"original"]',
         '    side[@"original"] = current;\n    id wanted = restore ? side[@"original"]', 'original'),
        ('ignore-drift', 'if (!atLast && !atWanted) {', 'if (false && !atLast && !atWanted) {', 'kernelPair.active==333'),
        ('ignore-optin', 'resourceWrites = VDTResourceWriteEnabled(prefs);', 'resourceWrites = YES;', 'writes==0'),
        ('repeat-unverified', 'if (!restore && ![current isEqual:wanted] &&', 'if (false && !restore && ![current isEqual:wanted] &&', 'priorityWrites==1'),
        ('retain-reused-pid', 'if (resourceGone(target)) {', 'if (false && resourceGone(target)) {', 'resourceRecords.count==0'),
        ('forget-failed-restore', '    if (!current) {\n        if (count < 3)',
         '    if (!current) {\n        if (restore) [resourceRecords removeObjectForKey:instance];\n        if (count < 3)', 'resourceRecords.count==1'),
        ('erase-control-lock', 'resourceStoreError || resourceControlError)', 'resourceStoreError)', 'resourceControlError==EINVAL'),
        ('repin-darwin21', 'if (!capabilities.restoreWriteback) {',
         'if (!capabilities.restoreWriteback || darwinMajor != 21) {', 'kernelPriority==150'),
        ('modern-journal-rejected', 'if (!resourceValueValid(side[@"original"], memory) ||',
         'if ((!memory && ([side[@"original"] intValue] > 21 || [side[@"last"] intValue] > 21)) || !resourceValueValid(side[@"original"], memory) ||', '!resourceStoreError && resourceRecords.count==1'),
        ('ignore-journal-generation', '[savedMajor intValue] != resourceDarwin', 'false', 'resourceStoreError==EINVAL && priorityWrites==1')]
    for label,old,new,expected in mutants:
        assert source.count(old)==1, 'mutation anchor not unique: '+label
    p=argparse.ArgumentParser();p.add_argument('--sdk',type=Path);p.add_argument('--require-native',action='store_true');a=p.parse_args()
    if platform.system()!='Darwin':
        if a.sdk:
            with tempfile.TemporaryDirectory(prefix='vdt-runtime-sdk-') as tmp:
                variants=[('baseline',None)]
                for label,old,new,expected in mutants:
                    path=Path(tmp)/(label+'.mm');path.write_text(source.replace(old,new,1));variants.append((label,path))
                for arch in ('arm64','arm64e'):
                    for label,path in variants:
                        define=[] if path is None else ['-DVDT_RESOURCE_RUNTIME_FILE="'+str(path)+'"']
                        run(['clang++','-std=gnu++98','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-fsyntax-only',
                            '-target',arch+'-apple-ios15.0','-isysroot',a.sdk,'-Itests/native_stubs','-I.',*define,MM[-1]])
                        print('SDK syntax only:',arch,label,flush=True)
            print(f'PASS resource fixture + {len(mutants)} mutants SDK syntax only; no Apple link/execute')
        print('SKIP native Foundation resource runtime: needs Darwin root; NOT device validation')
        return 1 if a.require_native else 77
    if os.geteuid()!=0:
        print('ERROR native fixture needs root-owned isolated store; invoke explicitly with sudo',file=sys.stderr);return 1
    with tempfile.TemporaryDirectory(prefix='vdt-resource-native-') as tmp:
        tmp=Path(tmp);objects=[]
        for index,name in enumerate(C):
            obj=tmp/(str(index)+'.o');run(['xcrun','clang','-std=c11','-O1','-Wall','-Wextra','-Werror','-I.', '-c',ROOT/name,'-o',obj]);objects.append(obj)
        env={**os.environ,'VDT_RESOURCE_RUNTIME_TEST_ROOT':str(tmp)}
        def compile_fixture(path=None):
            define=[] if path is None else ['-DVDT_RESOURCE_RUNTIME_FILE="'+str(path)+'"']
            run(['xcrun','clang++','-std=gnu++98','-fobjc-arc','-fblocks','-O1','-Wall','-Wextra','-Werror','-Itests/native_stubs','-I.',
                *define,*[ROOT/n for n in MM],*objects,'-framework','Foundation','-framework','CoreFoundation','-o',tmp/'fixture'])
        compile_fixture()
        subprocess.run([str(tmp/'fixture')],env=env,cwd=ROOT,check=True)
        import resource
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        for label,old,new,expected in mutants:
            assert source.count(old)==1, 'mutation anchor not unique: '+label
            path=tmp/(label+'.mm');path.write_text(source.replace(old,new,1))
            compile_fixture(path) # compile failure is failure, never a kill
            result=subprocess.run([str(tmp/'fixture')],env=env,cwd=ROOT,capture_output=True,text=True)
            assert result.returncode!=0 and 'assert' in result.stderr.lower() and expected in result.stderr, \
                'native mutant survived or failed off-target: '+label+'\n'+result.stderr
            print('KILLED native production coordinator:',label,flush=True)

    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except subprocess.CalledProcessError as e:sys.exit(e.returncode or 1)
