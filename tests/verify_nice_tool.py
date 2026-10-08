#!/usr/bin/env python3
"""Verify RootHide tool permissions in every actual Mach-O slice, not a source plist."""
import hashlib, math, plistlib, struct
EXPECTED_ENTITLEMENTS = {
    'platform-application': True,
    'com.apple.private.security.no-sandbox': True,
    'com.apple.private.security.storage.AppBundles': True,
    'com.apple.private.security.storage.AppDataContainers': True,
}
ROOT_HIDE_DEPENDENCY = '@loader_path/.jbroot/usr/lib/libroothide.dylib'

def u32(blob, offset):
    assert offset >= 0 and offset + 4 <= len(blob), 'truncated integer'
    return struct.unpack_from('>I', blob, offset)[0]

def verify_signature(data, start, size):
    assert start >= 32 and size >= 12 and start+size <= len(data), 'bad signature range'
    raw=data[start:start+size]
    assert u32(raw,0)==0xfade0cc0, 'missing embedded signature'
    length,count=u32(raw,4),u32(raw,8)
    assert 12+count*8 <= length <= size, 'bad signature index'
    blobs={}; spans=[]
    for i in range(count):
        slot,offset=struct.unpack_from('>II',raw,12+i*8)
        assert slot not in blobs and offset >= 12+count*8, 'bad/duplicate signature slot'
        end=offset+u32(raw,offset+4)
        assert offset+8 <= end <= length, 'bad signature blob'
        assert all(end<=lo or offset>=hi for lo,hi in spans), 'overlapping signature blobs'
        spans.append((offset,end));blobs[slot]=raw[offset:end]
    assert 5 in blobs and u32(blobs[5],0)==0xfade7171, 'tool lacks signed XML entitlements'
    rights=plistlib.loads(blobs[5][8:].rstrip(b'\0'))
    assert isinstance(rights,dict) and set(rights)==set(EXPECTED_ENTITLEMENTS), 'unexpected/missing RootHide permissions'
    assert all(rights[key] is True for key in EXPECTED_ENTITLEMENTS), 'RootHide permission is not true'
    directories=[]
    for slot,cd in blobs.items():
        if u32(cd,0)!=0xfade0c02: continue
        assert slot==0 or 0x1000<=slot<=0x1005, 'unexpected CodeDirectory slot'
        version,flags,hashoff,ident,special,slots,limit=struct.unpack_from('>7I',cd,8)
        hashsize,hashtype,platform,power=struct.unpack_from('4B',cd,36)
        if version>=0x20300 and limit==0xffffffff: limit=struct.unpack_from('>Q',cd,56)[0]
        assert hashtype in (1,2,3,4), 'unsupported signature hash'
        algorithm={1:'sha1',2:'sha256',3:'sha256',4:'sha384'}[hashtype]
        assert hashsize=={1:20,2:32,3:20,4:48}[hashtype], 'bad signature hash length'
        assert power<=20 and 5<=special<=64 and 0<limit<=start, 'bad CodeDirectory coverage'
        page=1<<power if power else limit
        assert slots==math.ceil(limit/page) and 0<=hashoff-special*hashsize, 'bad hash array'
        assert hashoff+slots*hashsize<=len(cd), 'truncated hash array'
        assert cd[hashoff-5*hashsize:hashoff-4*hashsize]==hashlib.new(algorithm,blobs[5]).digest()[:hashsize], 'entitlements not bound to CodeDirectory'
        for n in range(slots):
            expected=hashlib.new(algorithm,data[n*page:min((n+1)*page,limit)]).digest()[:hashsize]
            assert cd[hashoff+n*hashsize:hashoff+(n+1)*hashsize]==expected, 'tool code page hash mismatch'
        directories.append({'slot':slot,'hash':algorithm,'code_pages':slots})
    assert directories and any(d['slot']==0 for d in directories), 'missing primary CodeDirectory'
    return {'entitlements':rights,'directories':directories}

def verify_tool(data):
    assert data[:4]==b'\xca\xfe\xba\xbe' and u32(data,4)==2, 'expected dual-architecture tool'
    result=[]; spans=[]
    for i in range(2):
        cpu,sub,offset,size,align=struct.unpack_from('>5I',data,8+20*i)
        assert cpu==0x100000c and (sub&0xffffff) in (0,2), 'wrong tool architecture'
        assert offset>=48 and size>=32 and offset+size<=len(data), 'bad slice range'
        assert all(offset+size<=lo or offset>=hi for lo,hi in spans), 'overlapping slices'
        spans.append((offset,offset+size));b=data[offset:offset+size]
        magic,cpu2,sub2,kind,count,cmdsize,flags,reserved=struct.unpack_from('<8I',b)
        assert (magic,cpu2,sub2,kind)==(0xfeedfacf,cpu,sub,2), 'not matching MH_EXECUTE'
        pos=32;deps=[];signatures=[]
        for _ in range(count):
            cmd,length=struct.unpack_from('<II',b,pos)
            assert length>=8 and pos+length<=32+cmdsize<=len(b), 'bad load command'
            if cmd in (0xc,0x80000018,0x8000001f):
                stringoff=struct.unpack_from('<I',b,pos+8)[0]
                assert 8<=stringoff<length
                begin=pos+stringoff;end=b.index(b'\0',begin,pos+length)
                deps.append(b[begin:end].decode())
            if cmd==0x1d:
                sigstart,sigsize=struct.unpack_from('<II',b,pos+8)
                signatures.append(verify_signature(b,sigstart,sigsize))
            pos+=length
        assert pos==32+cmdsize and len(signatures)==1, 'missing/duplicate code signature'
        assert ROOT_HIDE_DEPENDENCY in deps, 'standard RootHide dependency changed'
        result.append({'arch':'arm64e' if sub&0xffffff==2 else 'arm64','dependencies':deps,**signatures[0]})
    assert {r['arch'] for r in result}=={'arm64','arm64e'}, 'missing architecture'
    return result
