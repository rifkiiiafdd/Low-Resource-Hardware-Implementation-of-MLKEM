"""Separate hardware RNG test; primary NIST simulation keeps CPU d/z.

Seeds are collected by the real RTL TRNG_SIM model, not supplied by the C test.
Physical entropy qualification requires the actual board.
"""
import argparse,ctypes as C,json,subprocess,shutil,hashlib
from build_software import ROOT,build
from run_cosim_tests import Simulator
from c_api import *

def compile_rpc(image,external):
    args=[shutil.which('iverilog'),'-g2012','-DTRNG_SIM','-s','tb_mlkem_rpc',
          f'-Ptb_mlkem_rpc.USE_EXTERNAL_ENTROPY={external}','-o',image,
          '-f','rtl/files_avalon.f','tb/tb_mlkem_rpc.sv']
    p=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=120)
    (ROOT/'results'/('trng_rng_external_compile.log' if external else 'trng_rng_compile.log')).write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)

def read_seeds(directory):
    seeds=[]
    for line in (directory/'rtl_seeds.txt').read_text().splitlines():
        kind,index,ps,word=line.split();assert kind=='seed' and int(index)==len(seeds)
        seeds.append({'time_ps':int(ps),'bytes':int(word,16).to_bytes(32,'little')})
    return seeds

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cc');ap.add_argument('--wave',action='store_true');a=ap.parse_args()
    path,cc=build(a.cc);lib=load_library(path);compile_rpc('build/rpc_trng.vvp',0);compile_rpc('build/rpc_trng_stalled.vvp',1)
    selector=C.c_int.in_dll(lib,'mlkem_keygen_rng_source');saved=selector.value
    selector.value=1;results=[]
    try:
        for parameter in [512,768,1024]:
            directory=ROOT/'results/trng_rng'/f'mlkem_{parameter}';directory.mkdir(parents=True,exist_ok=True)
            sim=Simulator(directory,a.wave,a.wave,image='build/rpc_trng.vvp',seed_log=True)
            hw=Accel();backend=Backend();ctx=Context();config=SeedRng();cpu_calls=[]
            @RNG
            def forbidden_cpu(user,out,n):cpu_calls.append(n);return -1
            def ok(rc,label):
                if rc:raise AssertionError(f'{label}: rc={rc}, status={hw.last_status:x}, errors={sim.errors}')
            try:
                ok(lib.mlkem_accel_init(C.byref(hw),None,sim.rd,sim.wr,100000),'TRNG accelerator init')
                lib.mlkem_accel_backend(C.byref(backend),C.byref(hw),1);ok(lib.mlkem_init(C.byref(ctx),parameter,C.byref(backend)),'context')
                lib.mlkem_seed_rng_init(C.byref(config),C.byref(hw),forbidden_cpu,None)
                ek,dk=buffer(ctx.ek_bytes),buffer(ctx.dk_bytes);sim.mark(2)
                ok(lib.mlkem_keygen(C.byref(ctx),ek,len(ek),dk,len(dk),C.cast(lib.mlkem_seed_random,RNG),C.byref(config)),'TRNG-selected KeyGen')
                sessions=read_seeds(directory);assert len(sessions)==2 and sim.commands['cmd9']==2 and cpu_calls==[]
                d,z=[s['bytes'] for s in sessions];assert d!=z
                assert bytes(dk[-32:])==z
                sw=Context();ok(lib.mlkem_init(C.byref(sw),parameter,None),'software reference context')
                ref_ek,ref_dk=buffer(ctx.ek_bytes),buffer(ctx.dk_bytes)
                ok(lib.mlkem_keygen_derand(C.byref(sw),ref_ek,len(ref_ek),ref_dk,len(ref_dk),buffer(d),buffer(z)),'reference from actual RTL seeds')
                assert bytes(ek)==bytes(ref_ek) and bytes(dk)==bytes(ref_dk)
                # Run a complete valid KEM exchange using the generated hardware keys.
                m=hashlib.sha3_256(b'TRNG RNG co-simulation '+str(parameter).encode()).digest()
                ct,ss1,ss2=buffer(ctx.ct_bytes),buffer(32),buffer(32);sim.mark(3)
                ok(lib.mlkem_encaps_derand(C.byref(ctx),ct,len(ct),ss1,ek,len(ek),buffer(m)),'Encaps with TRNG-derived keys')
                sim.mark(4);ok(lib.mlkem_decaps(C.byref(ctx),ss2,ct,len(ct),dk,len(dk)),'Decaps with TRNG-derived keys');assert bytes(ss1)==bytes(ss2)
                assert len(read_seeds(directory))==2 and cpu_calls==[]
                sim.mark(7)
                values={'status':'PASS','parameter_set':parameter,'source':'actual RTL TRNG_SIM sessions, deterministic pseudojitter; no physical entropy claim',
                        'd':d.hex(),'z':z.hex(),'ek':bytes(ek).hex(),'dk':bytes(dk).hex(),'m':m.hex(),'ciphertext':bytes(ct).hex(),
                        'shared_secret_encaps':bytes(ss1).hex(),'shared_secret_decaps':bytes(ss2).hex(),'cpu_rng_calls':len(cpu_calls),'seed_sessions':len(sessions)}
                (directory/'values.json').write_text(json.dumps(values,indent=2))
                results.append({'parameter_set':parameter,'status':'PASS','fresh_trng_sessions':2,'cpu_rng_calls':0,'full_ek_dk_vs_software':'PASS','kem_roundtrip':'PASS','commands':dict(sim.commands),'values':str((directory/'values.json').relative_to(ROOT).as_posix())})
                print(f'PASS TRNG RNG ML-KEM-{parameter}: 2 actual RTL seeds, no CPU RNG, full ek/dk match, KEM roundtrip',flush=True)
            finally:sim.close()
        # Raw input fixed at zero gives no Von Neumann output: fail, never fallback.
        directory=ROOT/'results/trng_rng/stalled_entropy';directory.mkdir(parents=True,exist_ok=True)
        sim=Simulator(directory,image='build/rpc_trng_stalled.vvp',seed_log=True);hw=Accel();config=SeedRng();cpu_calls=[]
        @RNG
        def fallback(user,out,n):cpu_calls.append(n);C.memset(out,255,n);return 0
        try:
            assert lib.mlkem_accel_init(C.byref(hw),None,sim.rd,sim.wr,30)==0
            lib.mlkem_seed_rng_init(C.byref(config),C.byref(hw),fallback,None)
            out=buffer(bytes([255])*64)
            assert lib.mlkem_seed_random(C.byref(config),out,64)==-3 and not any(out) and cpu_calls==[]
            assert sim.commands['cmd9']==1 and read_seeds(directory)==[]
            assert lib.mlkem_accel_reset(C.byref(hw))==0
            print('PASS stalled entropy: timeout, output zeroed, no CPU fallback, reset recovery',flush=True)
        finally:sim.close()
    finally:selector.value=saved
    summary={'status':'PASS','compiler':cc,'application_default_seed_source':'CPU' if saved==0 else 'TRNG','tests':results,
             'stalled_entropy':'PASS: bounded timeout, no fallback, zeroized output, reset recovery','physical_board_tested':False,'physical_entropy_assessed':False}
    (ROOT/'results/trng_rng_summary.json').write_text(json.dumps(summary,indent=2));print('ALL TRNG RNG TESTS PASS')
if __name__=='__main__':main()
