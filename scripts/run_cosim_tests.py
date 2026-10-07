"""Compiled C -> driver -> Avalon transactions -> actual mlkem_top RTL.

Unlike a software MMIO mock, all results are calculated by the HDL simulator.
"""
import sys,subprocess,ctypes as C,json,hashlib,time,argparse,shutil,csv
from collections import Counter
from build_software import ROOT,build
sys.path.insert(0,str(ROOT/'software/tests'))
from c_api import *
class Simulator:
    def __init__(self,artifact_dir,wave=False,trace=False,image='build/rpc.vvp',seed_log=False):
        self.artifact_dir=artifact_dir;self.log=(artifact_dir/'simulator.log').open('w',encoding='utf-8')
        self.trace=(artifact_dir/'mmio.csv').open('w',encoding='utf-8',newline='') if trace else None
        self.csv=csv.writer(self.trace) if trace else None
        if self.csv:self.csv.writerow(['simulation_time_ps','phase','operation','address_hex','data_hex'])
        self.phase=0;self.phase_times={};self.last_time_ps=0
        args=[shutil.which('vvp'),image]
        if wave:args.append('+WAVE_FILE='+str((artifact_dir/'wave.vcd').relative_to(ROOT).as_posix()))
        if seed_log:args.append('+SEED_LOG='+str((artifact_dir/'rtl_seeds.txt').relative_to(ROOT).as_posix()))
        self.p=subprocess.Popen(args,cwd=ROOT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        self.counts=Counter();self.commands=Counter();self.errors=[]
        if self.response()!='READY':raise RuntimeError('RPC simulator did not start')
        @READ
        def rd(user,addr,out):
            try:out[0]=self.request(0,addr,0);self.counts['reads']+=1;return 0
            except Exception as e:self.errors.append(str(e));return -1
        @WRITE
        def wr(user,addr,value):
            try:
                self.request(1,addr,value);self.counts['writes']+=1
                if addr==12:self.commands[f'cmd{value&15}']+=1
                return 0
            except Exception as e:self.errors.append(str(e));return -1
        self.rd,self.wr=rd,wr
    def response(self):
        while True:
            line=self.p.stdout.readline().strip()
            if line.startswith('VCD info:') or line.startswith('VCD warning:'):
                self.log.write(line+'\n');continue
            return line
    def request(self,op,addr,value):
        self.p.stdin.write(f'{op} {addr:x} {value:x}\n');self.p.stdin.flush()
        line=self.response();parts=line.split()
        if op==0 and len(parts)==3 and parts[0]=='R':
            got=int(parts[1],16);self.last_time_ps=int(parts[2])
            if self.csv:self.csv.writerow([self.last_time_ps,self.phase,'read',f'{addr:04x}',f'{got:08x}'])
            return got
        if op in (1,2) and len(parts)==2 and parts[0]=='W':
            self.last_time_ps=int(parts[1])
            if self.csv:self.csv.writerow([self.last_time_ps,self.phase,'write' if op==1 else 'wait',f'{addr:04x}',f'{value:08x}'])
            return 0
        if op==4 and len(parts)==2 and parts[0]=='M':return int(parts[1])
        raise RuntimeError(f'RTL RPC failed: {line}')
    def mark(self,phase,tc_id=0):
        self.phase=phase;self.phase_times[str(phase)]=self.request(4,phase,tc_id)
        self.log.write(f'PHASE {phase}, tcId={tc_id}, time_ps={self.phase_times[str(phase)]}\n');self.log.flush()
    def close(self):
        try:
            if self.p.poll() is None:
                self.p.stdin.write('3 0 0\n');self.p.stdin.flush()
                rest=self.p.communicate(timeout=20)[0];self.log.write(rest)
                if self.p.returncode or 'BYE' not in rest:raise RuntimeError(rest)
        finally:
            self.log.close()
            if self.trace:self.trace.close()
        if self.errors:raise RuntimeError(self.errors)

def export_values(directory,parameter,values,sim):
    """Write exact software inputs and DUT-backed C outputs, separate by fixture."""
    values.update(parameter_set=f'ML-KEM-{parameter}',status='PASS',byte_order='hex bytes in array order, first byte on the left',
        phase_start_ps=sim.phase_times,
        note='KeyGen and Encaps use different NIST fixtures. d/z are software test inputs; command 9/TRNG is not used.')
    (directory/'values.json').write_text(json.dumps(values,indent=2),encoding='utf-8')
    lines=[f'ML-KEM-{parameter} CO-SIMULATION: PASS',values['note'],'']
    for phase,record in values.items():
        if not isinstance(record,dict) or 'inputs' not in record:continue
        lines.extend([f'[{phase}]',f"NIST tcId: {record.get('tc_id','derived rejection test')}",f"Comparison: {record.get('comparison','PASS')}"])
        for group in ['inputs','actual','expected']:
            lines.append(group.upper())
            for name,hex_value in record[group].items():
                raw=bytes.fromhex(hex_value);lines.append(f'{name}: {len(raw)} bytes')
                for i in range(0,len(raw),16):lines.append(f'  {i:04x}: '+raw[i:i+16].hex(' '))
                (directory/f'{phase}_{group}_{name}.hex').write_text(''.join(f'{b:02x}\n' for b in raw),encoding='ascii')
        lines.append('')
    (directory/'values.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cc');ap.add_argument('--sets',nargs='+',type=int,choices=[512,768,1024],default=[512,768,1024]);ap.add_argument('--wave',action='store_true',help='save focused RTL VCD and timestamped MMIO CSV');ap.add_argument('--trace',action='store_true',help='save timestamped MMIO CSV without VCD');a=ap.parse_args()
    path,cc=build(a.cc);lib=load_library(path);iv=shutil.which('iverilog')
    application_seed_source=lib.mlkem_seed_source()
    # Official primary regression always uses CPU-supplied d/z fixtures.
    # The deployed C application follows the initializer in mlkem_rng.c.
    C.c_int.in_dll(lib,'mlkem_keygen_rng_source').value=0
    p=subprocess.run([iv,'-g2012','-DTRNG_SIM','-s','tb_mlkem_rpc','-o','build/rpc.vvp','-f','rtl/files_avalon.f','tb/tb_mlkem_rpc.sv'],cwd=ROOT,capture_output=True,text=True)
    (ROOT/'results/cosim_compile.log').write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    kg=json.loads((ROOT/'reference/acvp/keygen.json').read_text())
    ed=json.loads((ROOT/'reference/acvp/encap_decap.json').read_text())
    results=[];started=time.monotonic()
    for parameter in a.sets:
        artifact_dir=ROOT/'results/cosim'/f'mlkem_{parameter}';artifact_dir.mkdir(parents=True,exist_ok=True)
        sim=Simulator(artifact_dir,a.wave,a.trace or a.wave);hw=Accel();backend=Backend();ctx=Context();values={}
        def ok(rc,label):
            if rc:raise RuntimeError(f'{label}: rc={rc}, status={hw.last_status:x}, transport={sim.errors}')
        try:
            sim.mark(1)
            ok(lib.mlkem_accel_init(C.byref(hw),None,sim.rd,sim.wr,100000),'accel init')
            if parameter==a.sets[0]:
                # Exercise driver-only paths not reached by KEM's fixed hash sizes.
                for mode,message,count in [(0,b'',64),(3,b'abc',32),(1,b'abc',509),(2,bytes(range(136)),413)]:
                    out=buffer(count);ok(lib.mlkem_accel_hash(C.byref(hw),mode,buffer(message),len(message),out,count),'driver hash boundary')
                    want=hashlib.sha3_512(message).digest() if mode==0 else hashlib.sha3_256(message).digest() if mode==3 else (hashlib.shake_128(message) if mode==1 else hashlib.shake_256(message)).digest(count)
                    assert bytes(out)==want
                assert lib.mlkem_accel_hash(C.byref(hw),0,buffer(0),0,buffer(32),32)==-1
                bad=coeffs([3329]*256);out=coeffs([0]*256)
                assert lib.mlkem_accel_poly(C.byref(hw),0,out,bad,None,None)==-1
                # A real PAU command cannot finish in one polling iteration.
                hw.poll_limit=1;zero=coeffs([0]*256)
                assert lib.mlkem_accel_poly(C.byref(hw),0,out,zero,None,None)==-2
                hw.poll_limit=100000;ok(lib.mlkem_accel_reset(C.byref(hw)),'driver timeout reset recovery')
                ok(lib.mlkem_accel_poly(C.byref(hw),4,out,zero,zero,None),'driver recovery ADD');assert not any(out)
            lib.mlkem_accel_backend(C.byref(backend),C.byref(hw),1);ok(lib.mlkem_init(C.byref(ctx),parameter,C.byref(backend)),'context')
            t=next(g['tests'][0] for g in kg['testGroups'] if g['parameterSet']==f'ML-KEM-{parameter}')
            ek,dk=buffer(ctx.ek_bytes),buffer(ctx.dk_bytes)
            sim.mark(2,t['tcId'])
            cpu_seed_calls=[];cpu_seeds=bytes.fromhex(t['d']+t['z'])
            @RNG
            def cpu_seed_fixture(user,out,n):
                cpu_seed_calls.append(n)
                if n!=64:return -1
                C.memmove(out,cpu_seeds,n);return 0
            seed_rng=SeedRng();lib.mlkem_seed_rng_init(C.byref(seed_rng),C.byref(hw),cpu_seed_fixture,None)
            ok(lib.mlkem_keygen(C.byref(ctx),ek,len(ek),dk,len(dk),C.cast(lib.mlkem_seed_random,RNG),C.byref(seed_rng)),'RTL-backed keygen with CPU d/z')
            assert cpu_seed_calls==[64] and sim.commands['cmd9']==0
            assert bytes(ek)==bytes.fromhex(t['ek']);assert bytes(dk)==bytes.fromhex(t['dk'])
            values['keygen']={'tc_id':t['tcId'],'inputs':{'d':t['d'].lower(),'z':t['z'].lower()},'actual':{'ek':bytes(ek).hex(),'dk':bytes(dk).hex()},'expected':{'ek':t['ek'].lower(),'dk':t['dk'].lower()},'comparison':'all ek/dk bytes match NIST'}
            print(f'PASS co-simulation ML-KEM-{parameter} keygen: complete ek/dk match NIST',flush=True)
            t=next(g['tests'][0] for g in ed['testGroups'] if g['function']=='encapsulation' and g['parameterSet']==f'ML-KEM-{parameter}')
            ek,dk=buffer(bytes.fromhex(t['ek'])),buffer(bytes.fromhex(t['dk']));ct,ss=buffer(ctx.ct_bytes),buffer(32)
            sim.mark(3,t['tcId'])
            ok(lib.mlkem_encaps_derand(C.byref(ctx),ct,len(ct),ss,ek,len(ek),buffer(bytes.fromhex(t['m']))),'RTL-backed encaps')
            assert bytes(ct)==bytes.fromhex(t['c']);assert bytes(ss)==bytes.fromhex(t['k'])
            values['encaps']={'tc_id':t['tcId'],'inputs':{'ek':t['ek'].lower(),'m':t['m'].lower()},'actual':{'ciphertext':bytes(ct).hex(),'shared_secret':bytes(ss).hex()},'expected':{'ciphertext':t['c'].lower(),'shared_secret':t['k'].lower()},'comparison':'all ciphertext/shared-secret bytes match NIST'}
            print(f'PASS co-simulation ML-KEM-{parameter} encaps: ciphertext/shared secret match NIST',flush=True)
            sim.mark(4,t['tcId'])
            ss2=buffer(32);ok(lib.mlkem_decaps(C.byref(ctx),ss2,ct,len(ct),dk,len(dk)),'RTL-backed decaps');assert bytes(ss2)==bytes(ss)
            values['decaps']={'tc_id':t['tcId'],'inputs':{'dk':t['dk'].lower(),'ciphertext':bytes(ct).hex()},'actual':{'shared_secret':bytes(ss2).hex()},'expected':{'shared_secret':t['k'].lower()},'comparison':'shared secret matches Encaps and NIST'}
            sim.mark(5,t['tcId'])
            ct[0]^=1;ok(lib.mlkem_decaps(C.byref(ctx),ss2,ct,len(ct),dk,len(dk)),'RTL-backed implicit rejection')
            assert bytes(ss2)==hashlib.shake_256(bytes(dk[-32:])+bytes(ct)).digest(32)
            values['rejection']={'tc_id':t['tcId'],'inputs':{'z':bytes(dk[-32:]).hex(),'ciphertext':bytes(ct).hex()},'actual':{'shared_secret':bytes(ss2).hex()},'expected':{'shared_secret':hashlib.shake_256(bytes(dk[-32:])+bytes(ct)).digest(32).hex()},'comparison':'matches independent hashlib SHAKE256(z || changed ciphertext)'}
            # Run the driver's transcoder interface too, using canonical input.
            sim.mark(6)
            poly_in=coeffs([(i*17)%3329 for i in range(256)]);poly_out=coeffs([0]*256);enc=buffer(384)
            ok(lib.mlkem_accel_encode(C.byref(hw),poly_in,enc),'driver encode');want=buffer(384);lib.mlkem_encode(want,poly_in,12);assert bytes(enc)==bytes(want)
            ok(lib.mlkem_accel_decode(C.byref(hw),enc,poly_out),'driver decode');assert list(poly_out)==list(poly_in)
            sim.mark(7);export_values(artifact_dir,parameter,values,sim)
            result={'parameter_set':parameter,'status':'PASS','seed_source':'CPU-supplied NIST d/z, no command 9','nist_keygen':1,'nist_encaps':1,'valid_decaps':1,'implicit_rejection':1,'driver_encode_decode':'PASS','driver_boundaries_and_timeout':'PASS' if parameter==a.sets[0] else 'covered by first parameter set','mmio':dict(sim.counts),'rtl_commands':dict(sim.commands),'values':str((artifact_dir/'values.json').relative_to(ROOT).as_posix()),'waveform':str((artifact_dir/'wave.vcd').relative_to(ROOT).as_posix()) if a.wave else None,'mmio_trace':str((artifact_dir/'mmio.csv').relative_to(ROOT).as_posix()) if a.trace or a.wave else None}
            results.append(result);print(f'PASS co-simulation ML-KEM-{parameter}: decaps, implicit rejection, encode/decode; {sum(sim.counts.values())} MMIO transactions',flush=True)
            print(f'Artifacts: {artifact_dir.relative_to(ROOT).as_posix()}/values.txt'+(' + wave.vcd + mmio.csv' if a.wave else ''),flush=True)
        finally:sim.close()
    summary={'status':'PASS','compiler':cc,'application_default_seed_source':'CPU' if application_seed_source==0 else 'TRNG','primary_simulation_seed_source':'CPU (NIST fixtures)','transport':'C driver callbacks to live Icarus Avalon-MM RTL; no software peripheral model','tests':results,'seconds':round(time.monotonic()-started,3),'physical_board_tested':False}
    (ROOT/'results/cosim_summary.json').write_text(json.dumps(summary,indent=2));print('ALL C + RTL CO-SIMULATION TESTS PASS')
if __name__=='__main__':main()
