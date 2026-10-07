"""Execute compiled C against pinned NIST ACVP vectors and independent primitives."""
from pathlib import Path
import sys,json,hashlib,random,ctypes as C,argparse
from build_software import build,ROOT
sys.path.insert(0,str(ROOT/'software/tests'))
from c_api import *
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cc');a=ap.parse_args();path,cc=build(a.cc);lib=load_library(path)
    counts={'keygen_kat':0,'encaps_kat':0,'decaps_kat':0,'key_checks':0,'roundtrips':0,'implicit_rejection':0,'hash_cases':0,'poly_vectors':0,'compress_values':0,'packing_cases':0,'sampling_cases':0,'rng_tests':0,'backend_failure':0}
    rng=random.Random(2032026)
    def ok(code,label):
        if code:raise AssertionError(f'{label}: C returned {code}')
    def ctx(set):
        c=Context();ok(lib.mlkem_init(C.byref(c),set,None),'init');return c
    # Independent hashlib, empty messages and absorb/squeeze boundaries.
    for mode in range(4):
        rate=[72,168,136,136][mode]
        for n in [0,1,7,8,rate-1,rate,rate+1,2*rate,800,4096]:
            data=rng.randbytes(n);sizes=[64] if mode==0 else [32] if mode==3 else [1,7,8,rate-1,rate,rate+1,3*rate+5]
            for size in sizes:
                out=buffer(size);ok(lib.mlkem_sw_hash(None,mode,buffer(data),n,out,size),'hash')
                want=hashlib.sha3_512(data).digest() if mode==0 else hashlib.sha3_256(data).digest() if mode==3 else (hashlib.shake_128(data) if mode==1 else hashlib.shake_256(data)).digest(size)
                assert bytes(out)==want;counts['hash_cases']+=1
    manifest=json.loads((ROOT/'tb/vectors/manifest.json').read_text())
    def words(name):
        arr=[int(x,16) for x in (ROOT/'tb/vectors'/name).read_text().split()]
        return coeffs([x for w in arr for x in (w&4095,w>>12)])
    for case in manifest['cases']:
        i=case['index'];aa,bb,ac,want=[words(f'case_{i:03}_{suffix}.hex') for suffix in ('a','b','c','expected')];out=coeffs([0]*256)
        ok(lib.mlkem_sw_poly(None,case['cmd'],out,aa,bb,ac),'poly');assert list(out)==list(want);counts['poly_vectors']+=1
    for d in [1,4,5,10,11]:
        for x in range(3329):assert lib.mlkem_compress(x,d)==((2*x*(1<<d)+3329)//(2*3329))%(1<<d);counts['compress_values']+=1
        for x in range(1<<d):assert lib.mlkem_decompress(x,d)==(x*3329+(1<<(d-1)))>>d;counts['compress_values']+=1
    for d in [1,4,5,10,11,12]:
        p=[rng.randrange(1<<d) for _ in range(256)];inp=coeffs(p);enc=buffer(32*d);got=coeffs([0]*256)
        lib.mlkem_encode(enc,inp,d);want=sum(x<<(d*i) for i,x in enumerate(p)).to_bytes(32*d,'little');assert bytes(enc)==want
        lib.mlkem_decode(got,enc,d);assert list(got)==[x%3329 if d==12 else x for x in p];counts['packing_cases']+=1
    for eta in [2,3]:
        for _ in range(10):
            data=rng.randbytes(64*eta);bits=int.from_bytes(data,'little');mask=(1<<eta)-1;want=[]
            for i in range(256):v=bits>>(2*i*eta);want.append(((v&mask).bit_count()-((v>>eta)&mask).bit_count())%3329)
            out=coeffs([0]*256);lib.mlkem_cbd(out,buffer(data),eta);assert list(out)==want;counts['sampling_cases']+=1
    for _ in range(10):
        seed=rng.randbytes(32);i,j=rng.randrange(256),rng.randrange(256);stream=hashlib.shake_128(seed+bytes([i,j])).digest(8192);want=[]
        for off in range(0,len(stream)-2,3):v=int.from_bytes(stream[off:off+3],'little');want.extend(x for x in (v&4095,v>>12) if x<3329)
        out=coeffs([0]*256);lib.mlkem_sample_ntt(out,buffer(seed),i,j);assert list(out)==want[:256];counts['sampling_cases']+=1
    source=json.loads((ROOT/'reference/acvp/manifest.json').read_text())
    for name,info in source['files'].items():assert hashlib.sha256((ROOT/'reference/acvp'/name).read_bytes()).hexdigest()==info['sha256']
    kg=json.loads((ROOT/'reference/acvp/keygen.json').read_text())
    ed=json.loads((ROOT/'reference/acvp/encap_decap.json').read_text())
    for group in kg['testGroups']:
        c=ctx(int(group['parameterSet'].split('-')[-1]))
        for t in group['tests']:
            ek,dk=buffer(c.ek_bytes),buffer(c.dk_bytes)
            ok(lib.mlkem_keygen_derand(C.byref(c),ek,len(ek),dk,len(dk),buffer(bytes.fromhex(t['d'])),buffer(bytes.fromhex(t['z']))),f'keygen tc{t["tcId"]}')
            assert bytes(ek)==bytes.fromhex(t['ek']),f'ek tc{t["tcId"]}';assert bytes(dk)==bytes.fromhex(t['dk']),f'dk tc{t["tcId"]}';counts['keygen_kat']+=1
    print(f'PASS NIST keygen: {counts["keygen_kat"]}',flush=True)
    for group in ed['testGroups']:
        c=ctx(int(group['parameterSet'].split('-')[-1]));fn=group['function']
        for t in group['tests']:
            ek,dk=buffer(bytes.fromhex(t['ek'])),buffer(bytes.fromhex(t['dk']))
            if fn=='encapsulation':
                ct,ss=buffer(c.ct_bytes),buffer(32);ok(lib.mlkem_encaps_derand(C.byref(c),ct,len(ct),ss,ek,len(ek),buffer(bytes.fromhex(t['m']))),f'encaps tc{t["tcId"]}')
                assert bytes(ct)==bytes.fromhex(t['c']),f'ct tc{t["tcId"]}';assert bytes(ss)==bytes.fromhex(t['k']);counts['encaps_kat']+=1
            elif fn=='decapsulation':
                ct,ss=buffer(bytes.fromhex(t['c'])),buffer(32);ok(lib.mlkem_decaps(C.byref(c),ss,ct,len(ct),dk,len(dk)),f'decaps tc{t["tcId"]}')
                assert bytes(ss)==bytes.fromhex(t['k']),f'ss tc{t["tcId"]} reason={t["reason"]}';counts['decaps_kat']+=1
            else:
                result=lib.mlkem_check_ek(C.byref(c),ek,len(ek)) if fn=='encapsulationKeyCheck' else lib.mlkem_check_dk(C.byref(c),dk,len(dk))
                assert (result==0)==t['testPassed'],f'keycheck {fn} tc{t["tcId"]}';counts['key_checks']+=1
    print(f'PASS NIST encaps/decaps/checks: {counts["encaps_kat"]}/{counts["decaps_kat"]}/{counts["key_checks"]}',flush=True)
    for set in [512,768,1024]:
        c=ctx(set)
        for _ in range(8):
            ek,dk,ct=buffer(c.ek_bytes),buffer(c.dk_bytes),buffer(c.ct_bytes);s1,s2=buffer(32),buffer(32)
            ok(lib.mlkem_keygen_derand(C.byref(c),ek,len(ek),dk,len(dk),buffer(rng.randbytes(32)),buffer(rng.randbytes(32))),'roundtrip kg')
            ok(lib.mlkem_encaps_derand(C.byref(c),ct,len(ct),s1,ek,len(ek),buffer(rng.randbytes(32))),'roundtrip en')
            ok(lib.mlkem_decaps(C.byref(c),s2,ct,len(ct),dk,len(dk)),'roundtrip de');assert bytes(s1)==bytes(s2);counts['roundtrips']+=1
            ct[rng.randrange(len(ct))]^=1;ok(lib.mlkem_decaps(C.byref(c),s2,ct,len(ct),dk,len(dk)),'implicit rejection')
            assert bytes(s2)==hashlib.shake_256(bytes(dk[-32:])+bytes(ct)).digest(32);counts['implicit_rejection']+=1
        bad_ek=buffer(bytes(ek));bad_ek[0]=255;bad_ek[1]|=15;assert lib.mlkem_check_ek(C.byref(c),bad_ek,len(bad_ek))==-1
        assert lib.mlkem_decaps(C.byref(c),s2,ct,len(ct)-1,dk,len(dk))==-1
        dk[-64]^=1;assert lib.mlkem_decaps(C.byref(c),s2,ct,len(ct),dk,len(dk))==-1
        @RNG
        def fill(user,p,n):C.memmove(p,rng.randbytes(n),n);return 0
        ok(lib.mlkem_keygen(C.byref(c),ek,len(ek),dk,len(dk),fill,None),'rng kg');ok(lib.mlkem_encaps(C.byref(c),ct,len(ct),s1,ek,len(ek),fill,None),'rng en')
        ok(lib.mlkem_decaps(C.byref(c),s2,ct,len(ct),dk,len(dk)),'rng de');assert bytes(s1)==bytes(s2);counts['rng_tests']+=1
        @RNG
        def fail_rng(user,p,n):return -1
        assert lib.mlkem_keygen(C.byref(c),ek,len(ek),dk,len(dk),fail_rng,None)==-3;counts['rng_tests']+=1
    @HASH
    def fail_hash(user,mode,inp,n,out,count):return -2
    backend=Backend(None,C.cast(fail_hash,VP),None);c=Context();ok(lib.mlkem_init(C.byref(c),512,C.byref(backend)),'backend init')
    ek,dk=buffer(c.ek_bytes),buffer(c.dk_bytes);assert lib.mlkem_keygen_derand(C.byref(c),ek,len(ek),dk,len(dk),buffer(32),buffer(32))==-2;assert not any(ek) and not any(dk);counts['backend_failure']+=1
    # Test the same selectable callback used by the HPS application.
    rng_selector=C.c_int.in_dll(lib,'mlkem_keygen_rng_source');saved_source=rng_selector.value
    selector_checks=0
    try:
        rng_selector.value=0;c=ctx(512);seeds=rng.randbytes(64);calls=[]
        @RNG
        def cpu_seeds(user,p,n):
            calls.append(n)
            if n!=64:return -1
            C.memmove(p,seeds,n);return 0
        config=SeedRng();lib.mlkem_seed_rng_init(C.byref(config),None,cpu_seeds,None)
        ek,dk=buffer(c.ek_bytes),buffer(c.dk_bytes);ref_ek,ref_dk=buffer(c.ek_bytes),buffer(c.dk_bytes)
        ok(lib.mlkem_keygen(C.byref(c),ek,len(ek),dk,len(dk),C.cast(lib.mlkem_seed_random,RNG),C.byref(config)),'selected CPU KeyGen')
        ok(lib.mlkem_keygen_derand(C.byref(c),ref_ek,len(ref_ek),ref_dk,len(ref_dk),buffer(seeds[:32]),buffer(seeds[32:])),'CPU seed reference')
        assert bytes(ek)==bytes(ref_ek) and bytes(dk)==bytes(ref_dk) and calls==[64];selector_checks+=1
        rng_selector.value=1;out=buffer(bytes([255])*64)
        assert lib.mlkem_seed_random(C.byref(config),out,64)==-3 and not any(out) and calls==[64];selector_checks+=1
        rng_selector.value=2;out=buffer(bytes([255])*64)
        assert lib.mlkem_seed_random(C.byref(config),out,64)==-3 and not any(out);selector_checks+=1
        rng_selector.value=0;lib.mlkem_seed_rng_init(C.byref(config),None,fail_rng,None);out=buffer(bytes([255])*64)
        assert lib.mlkem_seed_random(C.byref(config),out,64)==-3 and not any(out);selector_checks+=1
    finally:rng_selector.value=saved_source
    counts['seed_selector']=selector_checks
    summary={'status':'PASS','compiler':cc,'counts':counts,'nist_commit':source['commit'],'arm_executed':False,'board_executed':False}
    (ROOT/'results/c_summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2));print('ALL C TESTS PASS')
if __name__=='__main__':main()
