#!/usr/bin/env python3
"""Negative controls for real slice/CodeDirectory entitlement verification."""
from pathlib import Path
import hashlib,plistlib,struct,subprocess,unittest
from verify_nice_tool import EXPECTED_ENTITLEMENTS,ROOT_HIDE_DEPENDENCY,verify_tool
ROOT=Path(__file__).resolve().parents[1]
BASE='430e89c28a6d00493da34b721fdd1580e3f9a1cb'

def thin(sub,rights=None,bound=True,code_good=True):
    if rights is None:rights=EXPECTED_ENTITLEMENTS
    xml=plistlib.dumps(rights,sort_keys=True)
    entitlement=struct.pack('>II',0xfade7171,8+len(xml))+xml
    name=ROOT_HIDE_DEPENDENCY.encode()+b'\0';length=(24+len(name)+7)//8*8
    load=struct.pack('<6I',0xc,length,24,0,0,0)+name+bytes(length-24-len(name))
    ident=b'fixture\0';hashoff=44+len(ident)+5*32;cdlen=hashoff+32
    sigsize=28+cdlen+len(entitlement);start=32+len(load)+16
    header=struct.pack('<8I',0xfeedfacf,0x100000c,sub,2,2,len(load)+16,0,0)
    code=header+load+struct.pack('<4I',0x1d,16,start,sigsize)
    cd=bytearray(struct.pack('>9I4BI',0xfade0c02,cdlen,0x20001,0,hashoff,44,5,1,start,32,2,0,12,0)+ident+bytes(6*32))
    cd[hashoff-160:hashoff-128]=hashlib.sha256(entitlement).digest() if bound else bytes(32)
    cd[hashoff:hashoff+32]=hashlib.sha256(code).digest() if code_good else bytes(32)
    sig=struct.pack('>3I4I',0xfade0cc0,sigsize,2,0,28,5,28+len(cd))+bytes(cd)+entitlement
    return code+sig

def fat(second_rights=None,bound=True,code_good=True):
    slices=[thin(0),thin(0x80000002,second_rights,bound,code_good)]
    first=48;second=first+len(slices[0])
    return (struct.pack('>2I',0xcafebabe,2)+struct.pack('>5I',0x100000c,0,first,len(slices[0]),0)+
        struct.pack('>5I',0x100000c,0x80000002,second,len(slices[1]),0)+b''.join(slices))

class RootHideToolTests(unittest.TestCase):
    def test_all_required_permissions_signed_in_both_slices(self):
        result=verify_tool(fat())
        self.assertEqual({x['arch'] for x in result},{'arm64','arm64e'})
    def test_each_missing_false_or_extra_entitlement_rejected(self):
        for key in EXPECTED_ENTITLEMENTS:
            for mode in ('missing','false','integer'):
                with self.subTest(key=key,mode=mode):
                    r=dict(EXPECTED_ENTITLEMENTS)
                    if mode=='missing':del r[key]
                    else:r[key]=False if mode=='false' else 1
                    with self.assertRaises(AssertionError):verify_tool(fat(r))
        r={**EXPECTED_ENTITLEMENTS,'get-task-allow':True}
        with self.assertRaises(AssertionError):verify_tool(fat(r))
    def test_unbound_permissions_and_bad_code_hash_rejected(self):
        for kw in ({'bound':False},{'code_good':False}):
            with self.assertRaises(AssertionError):verify_tool(fat(**kw))
        for data in (b'',fat()[:-5],thin(0)):
            with self.assertRaises((AssertionError,struct.error)):verify_tool(data)
    def test_tool_signing_configuration_and_runtime_freeze(self):
        rights=plistlib.loads((ROOT/'nicectl/Entitlements.plist').read_bytes())
        self.assertEqual(rights,EXPECTED_ENTITLEMENTS)
        old=subprocess.check_output(['git','show',BASE+':nicectl/Makefile'],cwd=ROOT)
        expected=old.replace(b'vedette-nicectl_FRAMEWORKS = Foundation\n',b'vedette-nicectl_FRAMEWORKS = Foundation\nvedette-nicectl_CODESIGN_FLAGS = -SEntitlements.plist\n')
        self.assertEqual((ROOT/'nicectl/Makefile').read_bytes(),expected)
        frozen=['nicectl/main.mm','VDTNicePolicy.c','VDTNiceRuntime.mm','VDTNiceShared.mm','VDTNiceStore.c',
            'Vedette.xm','VDTProcessManager.mm','VDTPolicyTransition.c','VDTProcessIdentity.c','layout/DEBIAN/postinst','layout/DEBIAN/prerm','layout/DEBIAN/postrm']
        frozen += [str(p.relative_to(ROOT)) for p in (ROOT/'vedetteprefs').rglob('*') if p.is_file()]
        for file in frozen:
            with self.subTest(file=file):self.assertEqual((ROOT/file).read_bytes(),subprocess.check_output(['git','show',BASE+':'+file],cwd=ROOT))

if __name__=='__main__':unittest.main(verbosity=2)
