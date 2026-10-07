"""Package offline sources/results; validate paths, checksums and ZIP CRC."""
from pathlib import Path
import re, json, hashlib, zipfile, html
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT.parent/'MLKEM_TOP_RTL_Integrasi_Tim_v1.0.zip'
def excluded(p):
    parts=p.relative_to(ROOT).parts
    return any(x in ('build','__pycache__','db','output_files','incremental_db') for x in parts) or p.suffix in ('.pyc','.bak','.vvp')
def main():
    linked=0
    for p in [ROOT/'BUKA_HASIL.html',ROOT/'README.md']:
        txt=p.read_text(encoding='utf-8')
        urls=(re.findall(r'(?:href|src)="([^"]+)"',txt) if p.suffix=='.html' else re.findall(r'\]\(([^)]+)\)',txt))
        for u in urls:
            u=html.unescape(u)
            if re.match(r'https?://|#',u):continue
            target=(p.parent/u).resolve()
            if not target.is_relative_to(ROOT) or not target.is_file():raise RuntimeError(f'Broken local link {p.name}: {u}')
            linked+=1
    files=[p for p in ROOT.rglob('*') if p.is_file() and not excluded(p) and p.name!='release_manifest.json']
    manifest=dict(package=OUT.name,files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(files)])
    mp=ROOT/'release_manifest.json';mp.write_text(json.dumps(manifest,indent=2),encoding='utf-8');files.append(mp)
    with zipfile.ZipFile(OUT,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=7) as z:
        for p in sorted(files):z.write(p,'mlkem_top_rtl/'+p.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(OUT) as z:
        if z.testzip():raise RuntimeError('ZIP CRC failure')
        for f in manifest['files']:
            if hashlib.sha256(z.read('mlkem_top_rtl/'+f['path'])).hexdigest()!=f['sha256']:raise RuntimeError('ZIP checksum failure')
    digest=hashlib.sha256(OUT.read_bytes()).hexdigest();OUT.with_suffix('.sha256').write_text(digest+'  '+OUT.name+'\n',encoding='ascii')
    print(json.dumps(dict(zip=str(OUT),bytes=OUT.stat().st_size,files=len(files),local_links_checked=linked,sha256=digest),indent=2))
if __name__=='__main__':main()
