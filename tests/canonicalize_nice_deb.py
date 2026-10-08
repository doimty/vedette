#!/usr/bin/env python3
"""Canonical numeric root ownership; never execute package contents/scripts.
Payload and control bytes, file types and modes must remain unchanged.
"""
from pathlib import Path, PurePosixPath
import hashlib, io, os, subprocess, sys, tarfile, tempfile

def records(package, area, require_root=False):
    blob=subprocess.check_output(['dpkg-deb','--'+area+'-tarfile',str(package)])
    result={}
    with tarfile.open(fileobj=io.BytesIO(blob),mode='r:*') as archive:
        for entry in archive:
            path=PurePosixPath(entry.name); name=str(path)
            if path.is_absolute() or '..' in path.parts or name in result:
                raise ValueError('Unsafe/duplicate archive path')
            if not (entry.isfile() or entry.isdir()): raise ValueError('Unexpected link or special file')
            if require_root and (entry.uid != 0 or entry.gid != 0): raise ValueError('Non-root numeric ownership remains')
            digest=hashlib.sha256(archive.extractfile(entry).read()).hexdigest() if entry.isfile() else None
            result[name]=(entry.mode,entry.type.decode('ascii'),digest)
    return result

def canonicalize(package):
    package=Path(package).resolve()
    before={area:records(package,area) for area in ('fsys','ctrl')}
    with tempfile.TemporaryDirectory(prefix='vedette-repack-',dir=package.parent) as directory:
        root=Path(directory); stage=root/'stage'; rebuilt=root/'rebuilt.deb'
        subprocess.run(['dpkg-deb','--raw-extract',str(package),str(stage)],check=True)
        for area,entries in before.items():
            base=stage if area=='fsys' else stage/'DEBIAN'
            for name,(mode,kind,digest) in entries.items(): os.chmod(base/name,mode)
        tool=stage/'usr/libexec/vedette-nicectl'
        assert tool.is_file() and tool.stat().st_mode&0o7777==0o755, 'Control tool must be non-setuid 0755'
        subprocess.run(['dpkg-deb','--build','--root-owner-group','-Zxz',str(stage),str(rebuilt)],check=True)
        after={area:records(rebuilt,area,require_root=True) for area in ('fsys','ctrl')}
        assert after==before,'Repacking changed file bytes, modes or entries'
        os.replace(rebuilt,package)
    print('Canonical numeric root ownership; payload/control bytes and modes unchanged.')

if __name__=='__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: canonicalize_nice_deb.py <deb>')
    canonicalize(sys.argv[1])
