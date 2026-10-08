#!/usr/bin/env python3
"""Validate actual stable payloads for the selected scheme without running them."""
from pathlib import Path,PurePosixPath
import hashlib,io,json,plistlib,subprocess,sys,tarfile,tempfile
from inspect_release_macho import inspect
from verify_nice_tool import verify_tool
ROOT=Path(__file__).resolve().parents[1]
VERSION='1.1.12-3'
DESCRIPTION='按应用与守护进程独立管理 CPU 限制和 nice 调度优先级'

def read_archive(deb,area):
    data=subprocess.check_output(['dpkg-deb','--'+area+'-tarfile',str(deb)])
    content={};metadata={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
        for m in archive:
            p=PurePosixPath(m.name);n=str(p)
            assert not p.is_absolute() and '..' not in p.parts and n not in metadata, 'unsafe duplicate archive path'
            assert m.uid==0 and m.gid==0,'non-root numeric ownership'
            assert m.isdir() or m.isfile(),'unexpected link/special archive record'
            assert m.size<=16*1024*1024,'oversized archive entry'
            metadata[n]={'mode':oct(m.mode),'size':m.size,'uid':m.uid,'gid':m.gid,'directory':m.isdir()}
            if m.isfile():content[n]=archive.extractfile(m).read()
    return content,metadata

def verify(deb,scheme):
    assert scheme in ('roothide','rootless')
    deb=Path(deb);prefix='var/jb/' if scheme=='rootless' else ''
    fields=dict(line.split(':',1) for line in subprocess.check_output(['dpkg-deb','-f',str(deb)],text=True).splitlines() if ':' in line)
    fields={k:v.strip() for k,v in fields.items()}
    expected={'Package':'com.doimty.vedette','Version':VERSION,'Description':DESCRIPTION,
        'Architecture':'iphoneos-arm64' if scheme=='rootless' else 'iphoneos-arm64e',
        'Maintainer':'doimty','Author':'udevs','Conflicts':'com.udevs.vedette','Replaces':'com.udevs.vedette',
        'Icon':'https://doimty.github.io/icons/com.doimty.vedette.png','Depiction':'https://doimty.github.io/depictions/com.doimty.vedette/'}
    for key,value in expected.items():assert fields[key]==value,(key,fields.get(key))
    deps='firmware (>= 15.0), roothide, preferenceloader, mobilesubstrate (>= 0.9.5000), com.opa334.altlist'
    assert fields['Depends']==(deps.replace('roothide, ','') if scheme=='rootless' else deps)
    files,meta=read_archive(deb,'fsys');control,control_meta=read_archive(deb,'ctrl')
    assert all(n.startswith(prefix) for n in files) if prefix else not any(n.startswith('var/jb/') for n in files)
    tool=prefix+'usr/libexec/vedette-nicectl'
    assert meta[tool]['mode']=='0o755'
    for hook in ('postinst','prerm','postrm'):
        folder='layout-rootless' if scheme=='rootless' and hook!='postrm' else 'layout'
        assert control[hook]==(ROOT/folder/'DEBIAN'/hook).read_bytes(),hook
        assert control_meta[hook]['mode']=='0o755'
    assert plistlib.loads(files[prefix+'Library/MobileSubstrate/DynamicLibraries/Vedette.plist'])=={'Filter':{'Bundles':['com.apple.Security']}}
    names=['Library/MobileSubstrate/DynamicLibraries/Vedette.dylib','Library/PreferenceBundles/VedettePrefs.bundle/VedettePrefs','usr/libexec/vedette-nicectl']
    info={}
    with tempfile.TemporaryDirectory() as td:
        for name in names:
            data=files[prefix+name];p=Path(td)/Path(name).name;p.write_bytes(data)
            info[name]=inspect(p,scheme)
    permissions=verify_tool(files[tool],scheme)
    assert b'VDTProbeRecordImpl' not in files[prefix+names[0]],'Release diagnostic emitter present'
    system_path=b'/System/Library/CoreServices/SpringBoard.app/SpringBoard'
    assert system_path in files[prefix+names[0]],'missing strict system resolver in runtime'
    assert system_path in files[prefix+names[1]],'missing system list entry in preferences'
    return {'scheme':scheme,'version':VERSION,'package':deb.name,'sha256':hashlib.sha256(deb.read_bytes()).hexdigest(),
        'bytes':deb.stat().st_size,'control':fields,'mach_o':info,'tool_signing':permissions,
        'payload_records':meta,'control_records':control_meta,'runtime_installed_or_executed':False}

if __name__=='__main__':
    if len(sys.argv) not in (3,4):raise SystemExit('usage: verify_release_layout.py <deb> <scheme> [report.json]')
    result=verify(sys.argv[1],sys.argv[2])
    if len(sys.argv)==4:Path(sys.argv[3]).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print('Stable package verified: '+result['scheme']+' '+result['version']+'; layouts, dependencies, hooks, six signed slices passed')
