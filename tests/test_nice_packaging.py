#!/usr/bin/env python3
"""Real dpkg repack fixtures with wrong numeric UID/GID and unchanged bytes."""
import gzip,io,struct,subprocess,tarfile,tempfile,unittest
from pathlib import Path
from canonicalize_nice_deb import canonicalize,records

def tar_blob(entries):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w') as archive:
        for name,data,mode,kind in entries:
            entry=tarfile.TarInfo(name);entry.uid=501;entry.gid=20;entry.uname='root';entry.gname='wheel';entry.mode=mode;entry.type=kind
            entry.size=len(data) if kind==tarfile.REGTYPE else 0
            if kind==tarfile.SYMTYPE:entry.linkname='/tmp/not-a-package-target'
            archive.addfile(entry,io.BytesIO(data) if kind==tarfile.REGTYPE else None)
    return gzip.compress(out.getvalue(),mtime=0)
def fixture(path,bad_link=False):
    control=b'Package: com.doimty.vedette\nVersion: 1.1.11-1+nice1\nArchitecture: all\nMaintainer: Fixture <test@example.invalid>\nDescription: isolated packaging fixture\n'
    body=b'fake Mach-O bytes; never execute this fixture\x00\xff'
    dirs=[('./',b'',0o755,tarfile.DIRTYPE),('./usr',b'',0o755,tarfile.DIRTYPE),('./usr/libexec',b'',0o755,tarfile.DIRTYPE)]
    data=dirs+[('./usr/libexec/vedette-nicectl',body,0o755,tarfile.SYMTYPE if bad_link else tarfile.REGTYPE)]
    ctl=[('./',b'',0o755,tarfile.DIRTYPE),('./control',control,0o644,tarfile.REGTYPE),
         ('./postinst',b'#!/bin/sh\nexit 17\n',0o755,tarfile.REGTYPE),('./prerm',b'#!/bin/sh\nexit 18\n',0o755,tarfile.REGTYPE)]
    result=bytearray(b'!<arch>\n')
    for name,blob in [('debian-binary',b'2.0\n'),('control.tar.gz',tar_blob(ctl)),('data.tar.gz',tar_blob(data))]:
        header=f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(blob):<10}`\n'.encode()
        assert len(header)==60
        result.extend(header);result.extend(blob)
        if len(blob)&1:result.extend(b'\n')
    path.write_bytes(result)

class CanonicalPackage(unittest.TestCase):
    def test_numeric_root_without_payload_or_control_changes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'fixture.deb';fixture(p)
            before={a:records(p,a) for a in ('fsys','ctrl')}
            with self.assertRaises(ValueError):records(p,'fsys',require_root=True)
            canonicalize(p)
            after={a:records(p,a,require_root=True) for a in ('fsys','ctrl')}
            self.assertEqual(before,after)
            self.assertEqual(after['fsys']['usr/libexec/vedette-nicectl'][0],0o755)
            self.assertEqual(after['ctrl']['postinst'][0],0o755)
    def test_special_records_rejected_before_extract(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'unsafe.deb';fixture(p,True);original=p.read_bytes()
            with self.assertRaises(ValueError):canonicalize(p)
            self.assertEqual(p.read_bytes(),original)

if __name__=='__main__':unittest.main(verbosity=2)
