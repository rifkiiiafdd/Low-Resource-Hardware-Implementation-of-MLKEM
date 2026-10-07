"""Cross-compile for Cortex-A9 Linux; does not claim physical ARM execution."""
import argparse,os,shutil,subprocess,json
from pathlib import Path
from build_software import ROOT,SOURCES
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cc');a=ap.parse_args()
    candidates=[a.cc,os.environ.get('MLKEM_ARM_CC'),shutil.which('arm-linux-gnueabihf-gcc'),
        'C:/AMDDesignTools/2026.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc.exe']
    cc=next((str(Path(c).resolve()) for c in candidates if c and Path(c).is_file()),None)
    if not cc:raise SystemExit('Set MLKEM_ARM_CC or pass --cc ARM_LINUX_GCC')
    out=ROOT/'build/arm';out.mkdir(parents=True,exist_ok=True)
    args=[cc,'-std=c99','-O2','-Wall','-Wextra','-Werror','-mcpu=cortex-a9','-mfloat-abi=hard','-mfpu=neon',
        '-Isoftware/include',*[f'software/src/{s}.c' for s in SOURCES],'software/examples/hps_linux_demo.c','-o',str(out/'mlkem_hps_demo')]
    p=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=120)
    (ROOT/'results/arm_compile.log').write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    executable=(out/'mlkem_hps_demo').read_bytes();assert executable[:4]==b'\x7fELF' and int.from_bytes(executable[18:20],'little')==40
    summary={'status':'PASS','compiler':cc,'target':'ARM Cortex-A9 Linux hard-float ELF','output':'build/arm/mlkem_hps_demo','execution_on_arm':False}
    (ROOT/'results/arm_build_summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
