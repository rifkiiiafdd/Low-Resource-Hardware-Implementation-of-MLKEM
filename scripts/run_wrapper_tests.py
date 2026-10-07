"""Compile and execute the real Avalon wrapper, with independent TOP fixtures."""
from pathlib import Path
import subprocess, shutil, hashlib, json
ROOT=Path(__file__).resolve().parents[1]
def main():
    (ROOT/'build').mkdir(exist_ok=True)
    def run(cmd,name):
        p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=240)
        (ROOT/'results'/name).write_text(p.stdout+p.stderr,encoding='utf-8')
        if p.returncode: raise RuntimeError(p.stdout+p.stderr)
        return p.stdout+p.stderr
    iv=shutil.which('iverilog');vvp=shutil.which('vvp')
    if not iv or not vvp: raise SystemExit('iverilog/vvp required in PATH')
    # Physical LCELL primitives are provided by Quartus. Generic elaboration
    # uses a black box; executable tests use TRNG_SIM or external raw entropy.
    run([iv,'-g2001','-s','mlkem_avalon_wrapper','-o','build/avalon_elaboration.vvp','-f','rtl/files_avalon.f','scripts/lcell_blackbox.v'],'avalon_elaboration.log')
    run([iv,'-g2012','-DTRNG_SIM','-I','tb/vectors','-s','tb_mlkem_avalon','-o','build/avalon.vvp','-f','rtl/files_avalon.f','tb/tb_mlkem_avalon.sv'],'avalon_compile.log')
    out=run([vvp,'build/avalon.vvp'],'avalon.log')
    if 'PASS Avalon:' not in out:raise RuntimeError('Missing PASS')
    words={};seed=None
    for line in (ROOT/'results/avalon_seed.txt').read_text().splitlines():
        f=line.split()
        if f[0]=='seed':seed=int(f[2],16).to_bytes(32,'little')
        else:words[int(f[2])]=int(f[3],16).to_bytes(8,'little')
    assert b''.join(words[i] for i in range(8))==hashlib.sha3_512(seed+b'\x02').digest()
    summary={'status':'PASS','simulator':'Icarus Verilog','seed_hashlib':'PASS','log':out.strip(),'hardware_board_tested':False}
    (ROOT/'results/avalon_summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(out.strip());print('PASS Avalon seed: independent hashlib')
if __name__=='__main__':main()
