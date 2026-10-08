from pathlib import Path
import hashlib, json, math, struct

def be32(data,off): return struct.unpack_from('>I',data,off)[0]
def cstr(data,off):
    assert 0 <= off < len(data)
    end=data.index(0,off)
    return data[off:end].decode('utf-8')
def version(n): return f'{n>>16}.{(n>>8)&255}.{n&255}'
def signature(slice_data,offset,size):
    b=slice_data[offset:offset+size]
    assert len(b)==size and be32(b,0)==0xfade0cc0
    length,count=be32(b,4),be32(b,8)
    assert 12+count*8<=length<=size
    blobs={}
    for i in range(count):
        slot,start=struct.unpack_from('>II',b,12+i*8)
        assert slot not in blobs and start+8<=length
        end=start+be32(b,start+4); assert end<=length
        blobs[slot]=b[start:end]
    cds=[]
    for slot,cd in blobs.items():
        if be32(cd,0)!=0xfade0c02: continue
        ver,flags,hash_off,ident_off,special,slots,limit=struct.unpack_from('>7I',cd,8)
        hash_size,hash_type,platform,page_pow=struct.unpack_from('4B',cd,36)
        if ver>=0x20300 and limit==0xffffffff: limit=struct.unpack_from('>Q',cd,56)[0]
        algorithm={1:'sha1',2:'sha256',3:'sha256',4:'sha384'}[hash_type]
        assert hash_size in (20,32,48) and page_pow<=20
        page=(1<<page_pow) if page_pow else max(limit,1)
        assert 0<limit<=offset and slots==math.ceil(limit/page)
        assert hash_off-special*hash_size>=0 and hash_off+slots*hash_size<=len(cd)
        for n in range(slots):
            raw=slice_data[n*page:min((n+1)*page,limit)]
            expected=hashlib.new(algorithm,raw).digest()[:hash_size]
            assert cd[hash_off+n*hash_size:hash_off+(n+1)*hash_size]==expected,('code hash',slot,n)
        checked=[];external=[]
        for n in range(1,special+1):
            expected=cd[hash_off-n*hash_size:hash_off-(n-1)*hash_size]
            if expected==bytes(hash_size): continue
            if n in blobs:
                assert hashlib.new(algorithm,blobs[n]).digest()[:hash_size]==expected,('special hash',n)
                checked.append(n)
            else: external.append(n)
        cds.append({'slot':slot,'identifier':cstr(cd,ident_off),'flags':flags,'hash':algorithm,
            'code_pages':slots,'code_pages_verified':True,'special_slots_verified':checked,'external_special_slots':external})
    assert cds,'missing CodeDirectory'
    return cds

def inspect(path, scheme='roothide'):
    assert scheme in ('rootless','roothide')
    path=Path(path);data=path.read_bytes()
    assert data[:4]==b'\xca\xfe\xba\xbe','expected FAT Mach-O'
    count=be32(data,4);assert count==2
    result=[]
    for i in range(count):
        cpu,sub,offset,size,align=struct.unpack_from('>5I',data,8+20*i)
        assert cpu==0x100000c and (sub&0xffffff) in (0,2) and offset+size<=len(data)
        b=data[offset:offset+size]
        magic,c,s,kind,n,cmdsize,flags,reserved=struct.unpack_from('<8I',b)
        expected_kind=(2,) if path.name=='vedette-nicectl' else (6,8)
        assert magic==0xfeedfacf and c==cpu and s==sub and kind in expected_kind
        pos=32;commands=[];deps=[];ids=[];rpaths=[];versions=[];sig=None;symbols=[];uuid=None
        for _ in range(n):
            cmd,length=struct.unpack_from('<II',b,pos)
            assert length>=8 and pos+length<=32+cmdsize<=len(b)
            block=b[pos:pos+length];commands.append(cmd)
            if cmd in (0xc,0xd,0x80000018,0x8000001f,0x80000023,0x8000001c):
                start=struct.unpack_from('<I',block,8)[0];name=cstr(block,start)
                (ids if cmd==0xd else rpaths if cmd==0x8000001c else deps).append(name)
            if cmd==0x32:
                platform,minimum,sdk,tools=struct.unpack_from('<4I',block,8)
                assert platform==2 and minimum==0xf0000 and sdk==0x110500
                versions.append({'minimum':version(minimum),'sdk':version(sdk),'platform':platform})
            if cmd==0x1d:
                start,sz=struct.unpack_from('<II',block,8); assert start+sz<=len(b)
                sig=signature(b,start,sz)
            if cmd==0x1b: uuid=block[8:24].hex()
            if cmd==0x2c: assert struct.unpack_from('<I',block,16)[0]==0
            if cmd==0x2:
                symoff,nsym,stroff,strsize=struct.unpack_from('<4I',block,8)
                assert symoff+nsym*16<=len(b) and stroff+strsize<=len(b)
                strings=b[stroff:stroff+strsize]
                for k in range(nsym):
                    strx,typ,sect,desc,val=struct.unpack_from('<IBBHQ',b,symoff+k*16)
                    if strx and not typ&0xe0 and typ&0x0e==0: symbols.append(cstr(strings,strx))
            pos+=length
        assert pos==32+cmdsize and len(versions)==1 and sig and uuid
        assert 0x80000034 in commands and 0x80000022 not in commands
        assert all(not cd['external_special_slots'] for cd in sig), 'unverified external signature slot'
        if scheme=='roothide':
            assert not any('/var/jb' in x for x in deps+ids+rpaths)
            assert '@loader_path/.jbroot/usr/lib/libroothide.dylib' in deps
        else:
            assert not any('libroothide' in x for x in deps), 'rootless links RootHide runtime'
            assert '/var/jb/usr/lib' in rpaths, 'missing rootless runtime search path'
        if path.name=='Vedette.dylib':
            assert ids==(['@rpath/Vedette.dylib'] if scheme=='rootless' else ['@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/Vedette.dylib'])
            assert {'_getpriority','_setpriority'}<=set(symbols)
        elif path.name=='VedettePrefs':
            assert ids==[('/var/jb' if scheme=='rootless' else '')+'/Library/PreferenceBundles/VedettePrefs.bundle/VedettePrefs']
            assert '@rpath/AltList.framework/AltList' in deps and '@loader_path/../../Frameworks' in rpaths
            assert '_setpriority' not in symbols
        else:
            assert path.name=='vedette-nicectl' and not ids
            assert '_setpriority' not in symbols and '_getpriority' not in symbols
        result.append({'arch':'arm64e' if sub&0xffffff==2 else 'arm64','subtype':sub,'kind':kind,'uuid':uuid,
            **versions[0],'dependencies':deps,'id':ids,'rpaths':rpaths,'signatures':sig,'chained_fixups':True,
            'nice_imports':sorted(set(symbols)&{'_getpriority','_setpriority'})})
    assert {r['arch'] for r in result}=={'arm64','arm64e'}
    return {'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'slices':result}
