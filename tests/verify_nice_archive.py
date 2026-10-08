#!/usr/bin/env python3
"""Check numeric ownership/mode of the new root-run removal handshake files."""
import io, posixpath, subprocess, sys, tarfile
from verify_nice_tool import verify_tool

def validate(data, required):
    found={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
        for entry in archive:
            name=entry.name
            while name.startswith('./'): name=name[2:]
            if not name or name=='.': continue
            if name.startswith('/') or '..' in name.split('/'):
                raise AssertionError('unsafe archive path')
            name=posixpath.normpath(name)
            if name in required:
                assert name not in found, 'duplicate archive entry'
                assert entry.isfile(), 'required entry is not a regular file'
                assert entry.uid==0 and entry.gid==0, 'required entry must have numeric root ownership'
                assert entry.mode & 0o7777 == required[name], 'unexpected executable mode/setuid bit'
                found[name]=True
    assert set(found)==set(required), 'required entries missing'

def main(deb, scheme='roothide'):
    assert scheme in ('rootless','roothide'), 'unsupported scheme'
    toolpath=('var/jb/' if scheme=='rootless' else '')+'usr/libexec/vedette-nicectl'
    expected_arch='iphoneos-arm64' if scheme=='rootless' else 'iphoneos-arm64e'
    assert subprocess.check_output(['dpkg-deb','-f',deb,'Architecture'],text=True).strip()==expected_arch
    data=subprocess.check_output(['dpkg-deb','--fsys-tarfile',deb])
    validate(data,{toolpath:0o755})
    validate(subprocess.check_output(['dpkg-deb','--ctrl-tarfile',deb]),{'prerm':0o755,'postinst':0o755})
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
        matches=[entry for entry in archive if entry.name.removeprefix('./')==toolpath]
        assert len(matches)==1
        slices=verify_tool(archive.extractfile(matches[0]).read(),scheme)
    print('nice tool: both slices have four signed permissions; code and entitlement hashes passed ('+scheme+')')
    print('nice archive: numeric ownership, regular entries, executable modes passed')

if __name__=='__main__':
    if len(sys.argv) not in (2,3): raise SystemExit('usage: verify_nice_archive.py <deb> [roothide|rootless]')
    main(sys.argv[1],sys.argv[2] if len(sys.argv)==3 else 'roothide')
