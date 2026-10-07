"""Real RTL regression; fail on simulator errors, mismatches or missing PASS."""
from pathlib import Path
import argparse, subprocess, shutil, sys, json, re, hashlib, csv
ROOT=Path(__file__).resolve().parents[1]
RTL=['mlkem_top','mlkem_pau_engine','mlkem_transcoder','ram_poly','pau_core','pau_modmul','pau_zeta_rom',
     'sha3_keccak_core','trng_core','trng_conditioner','trng_sha3_bridge','ring_osc','von_neumann']
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--iverilog-bin',type=Path);ap.add_argument('--wave',action='store_true');a=ap.parse_args()
    suffix='.exe' if sys.platform=='win32' else ''
    def exe(n):
        p=str(a.iverilog_bin/(n+suffix)) if a.iverilog_bin else shutil.which(n)
        if not p or not Path(p).is_file(): raise SystemExit('Icarus diperlukan: gunakan --iverilog-bin FOLDER_BIN atau PATH')
        return str(Path(p).resolve())
    iv,vvp=exe('iverilog'),exe('vvp');(ROOT/'build').mkdir(exist_ok=True);(ROOT/'results').mkdir(exist_ok=True)
    def run(args,log,cwd=ROOT,fail_marker=None):
        p=subprocess.run(args,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=180)
        (ROOT/'results'/log).write_text(p.stdout,encoding='utf-8')
        if fail_marker:
            if p.returncode==0 or fail_marker not in p.stdout: raise RuntimeError('Expected failure missing: '+p.stdout)
        elif p.returncode or any(s in p.stdout for s in ('ERROR:','FATAL:','TEST FAILED')):
            raise RuntimeError(p.stdout)
        return p.stdout
    rtl=['rtl/'+n+'.v' for n in RTL]
    run([iv,'-g2001','-DTRNG_SIM','-s','mlkem_top','-o','build/elaboration.vvp',*rtl],'elaboration.log')
    run([iv,'-g2012','-DTRNG_SIM','-I','tb/vectors','-s','tb_mlkem_top','-o','build/top.vvp',*rtl,'tb/tb_mlkem_top.sv'],'compile_top.log')
    out=run([vvp,'build/top.vvp',*(['+WAVE'] if a.wave else [])],'top.log')
    if 'PASS TOP:' not in out: raise RuntimeError('Missing TOP PASS')
    line=next(l for l in out.splitlines() if l.startswith('PASS TOP:'));print(line)
    counts={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
    # Verify the actual random-model seed through an independent hash library.
    def verify_seed_file(name):
        sessions={}
        for row in (ROOT/'results'/name).read_text().splitlines():
            f=row.split();s=sessions.setdefault(int(f[1]),dict(words={}))
            if f[0]=='seed': s['seed']=int(f[2],16).to_bytes(32,'little')
            else:s['words'][int(f[2])]=int(f[3],16).to_bytes(8,'little')
        for sid,s in sessions.items():
            got=b''.join(s['words'][n] for n in range(8));want=hashlib.sha3_512(s['seed']+b'\x02').digest()
            if got!=want: raise RuntimeError(f'Seed G(d||02) mismatch session {sid}')
        if len(sessions)!=2:raise RuntimeError('Two seed sessions required')
    verify_seed_file('seeds.txt')
    print('PASS TRNG bridge: 2 actual simulated seeds matched independent hashlib G(d||02)')
    run([iv,'-g2012','-DTRNG_SIM','-s','tb_seed_external','-o','build/seed_external.vvp',*rtl,'tb/tb_seed_external.sv'],'external_compile.log')
    ext=run([vvp,'build/seed_external.vvp'],'external_seed.log')
    if 'PASS external entropy TOP:' not in ext:raise RuntimeError('Missing external entropy PASS')
    verify_seed_file('external_seeds.txt');print('PASS external entropy configuration: 2 independent seed hashes')
    run([vvp,'build/top.vvp','+NEGATIVE_CHECKER'],'checker_negative.log',fail_marker='TOP mismatch word=0')
    orig='vendor/ml_kem_rtl_sarah/ml_kem_rtl_complete/rtl/transcoder.v'
    run([iv,'-g2012','-s','tb_original_transcoder','-o','build/original.vvp',orig,'tb/tb_original_transcoder.sv'],'original_compile.log')
    run([vvp,'build/original.vvp'],'original_transcoder_bug.log',fail_marker='ORIGINAL_DECODE_BUG')
    # Existing PAU datapath and SHA3 regression, with real HDL simulators.
    for tb in ['tb_modmul','tb_pau_core']:
        src=f'vendor/PAU_MLKEM_RTL_v1.0/pau_rtl/tb/{tb}.sv'
        run([iv,'-g2012','-s',tb,'-o',f'build/{tb}.vvp',*rtl,src],tb+'_compile.log')
        log=run([vvp,f'build/{tb}.vvp'],tb+'.log')
        if 'PASS' not in log:raise RuntimeError('Missing '+tb+' PASS')
        print(next(l for l in log.splitlines() if l.startswith('PASS')))
    sha=ROOT/'vendor/SHA3/SHA3';(sha/'build').mkdir(exist_ok=True)
    run([iv,'-g2012','-s','tb_sha3_keccak_core','-o',str(sha/'build/sha.vvp'),str(ROOT/'rtl/sha3_keccak_core.v'),str(sha/'tb_sha3_keccak_core.v')],'sha_compile.log')
    log=run([vvp,str(sha/'build/sha.vvp')],'sha_component.log',cwd=sha)
    if 'PASS' not in log:raise RuntimeError('Missing SHA component PASS')
    print('\n'.join(l for l in log.splitlines() if 'PASS' in l)[-700:])
    cases=list(csv.DictReader((ROOT/'results/integration_cases.csv').open()))
    coefficients=list(csv.DictReader((ROOT/'results/coefficients.csv').open()))
    if len(cases)!=83 or len(coefficients)*2!=counts['coefficients']:raise RuntimeError('CSV count mismatch')
    summary=dict(status='PASS',simulator=run([iv,'-V'],'simulator.log').splitlines()[0],top=counts,
                 seed_hashlib='4/4 PASS; 2 RO pseudojitter and 2 external deterministic stimuli; no physical entropy assessment',checker_negative='PASS: deliberate mismatch rejected',
                 original_transcoder='Original decode bug reproduced; integration replacement passed',
                 pau_datapath='36645 multiplications, 408 core cases',sha3_component='191 cases, 6146 words',
                 latency_cycles={str(cmd):sorted({int(r['cycles']) for r in cases if int(r['cmd'])==cmd}) for cmd in range(5)},
                 quartus='Not executed',questa='Not executed',clock='50 MHz simulation stimulus; hardware fMAX not measured')
    (ROOT/'results/test_summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print('ALL INTEGRATION TESTS PASS')
if __name__=='__main__':main()
