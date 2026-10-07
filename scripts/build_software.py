"""Build portable C99 library. --cc or MLKEM_CC overrides compiler discovery."""
from pathlib import Path
import os,sys,shutil,subprocess,argparse
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['keccak','poly','mlkem','mlkem_accel','mlkem_rng']
def compiler(explicit=None):
    candidates=[explicit,os.environ.get('MLKEM_CC'),shutil.which('gcc'),shutil.which('clang'),
        'C:/altera_lite/25.1std/questa_fse/gcc-7.4.0-mingw64vc16/bin/gcc.exe',
        'C:/AMDDesignTools/2026.1/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe']
    for p in candidates:
        if p and Path(p).is_file():return str(Path(p).resolve())
    raise RuntimeError('C compiler required: set MLKEM_CC or use --cc')
def build(explicit=None):
    cc=compiler(explicit);(ROOT/'build').mkdir(exist_ok=True)
    lib=ROOT/'build'/('mlkem.dll' if sys.platform=='win32' else 'libmlkem.so')
    args=[cc,'-std=c99','-O2','-Wall','-Wextra','-Werror','-shared']
    args+=['-Wl,--export-all-symbols'] if sys.platform=='win32' else ['-fPIC']
    args+=['-Isoftware/include',*[f'software/src/{s}.c' for s in SOURCES],'-o',str(lib)]
    p=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=120)
    (ROOT/'results/c_compile.log').write_text(p.stdout+p.stderr,encoding='utf-8')
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    return lib,cc
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--cc');a=ap.parse_args();lib,cc=build(a.cc);print(f'Built {lib} with {cc}')
