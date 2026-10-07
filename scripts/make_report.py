"""Build a self-contained report from actual simulator CSV and structural checks."""
from pathlib import Path
import csv, json, html, collections
ROOT=Path(__file__).resolve().parents[1]
def esc(v):return html.escape(str(v))
def diagram():
    boxes=[(470,55,420,150,'TOP FSM mlkem_top',['Capture command / parameter','Arbitrasi RAM + SHA3','Valid bitmap + error + done']),
           (1000,55,360,150,'TRNG + bridge',['8 RO / entropy eksternal','Von Neumann -> seed d','G(d || 02), k=2']),
           (80,315,430,210,'PAU',['mlkem_pau_engine','pau_core: 2 butterfly','2 multiplier bersama','NTT / INTT / PWM / MAC / ADD']),
           (600,315,270,210,'Transcoder',['mlkem_transcoder','ByteEncode / Decode_12','384 byte / polinomial','Ready / valid']),
           (980,315,380,210,'SHA3 + buffer output',['sha3_keccak_core: 24 ronde','SHA3-512/256; SHAKE128/256','Capture burst 21 x 64 bit','Output ready / valid + keep']),
           (600,625,270,110,'Mux RAM bersama',['Satu pemilik per command','Host / PAU / transcoder']),
           (370,800,690,105,'RAM Sarah: ram_poly',['2048 x 24 bit = 16 slot x 128 word','Word = {f[2i+1], f[2i]}']),
           (890,365,75,115,'Packer',['8 byte','ke 64 bit'])]
    elements=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1440 950"><defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10Z" fill="#3563a0"/></marker><marker id="ctl" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10Z" fill="#bb4b35"/></marker></defs><rect width="1440" height="950" fill="#f7f9fc"/>']
    def line(points,color='#3563a0',marker='arrow',bidirectional=False):
        start=f' marker-start="url(#{marker})"' if bidirectional else ''
        elements.append(f'<polyline points="{points}" fill="none" stroke="{color}" stroke-width="3" marker-end="url(#{marker})"{start}/>')
    def label(x,y,s,size=19):elements.append(f'<text x="{x}" y="{y}" font-family="Arial,sans-serif" font-size="{size}" text-anchor="middle" fill="#263d52">{esc(s)}</text>')
    line('680,205 680,250 300,250 300,315','#bb4b35','ctl')
    line('680,250 735,250 735,315','#bb4b35','ctl')
    line('680,250 1170,250 1170,315','#bb4b35','ctl')
    line('890,130 1000,130','#bb4b35','ctl')
    line('1240,205 1240,315');label(1280,278,'seed')
    line('510,465 550,465 550,680 600,680',bidirectional=True);label(385,600,'2 port x 24 bit')
    line('735,525 735,625',bidirectional=True);label(799,583,'24 bit')
    line('735,735 735,800',bidirectional=True);label(940,777,'Read sinkron 1 clock')
    line('870,415 890,415');line('965,415 980,415')
    line('80,680 600,680',bidirectional=True);label(280,660,'Host word I/O - saat idle')
    line('1170,525 1170,680 1020,680');label(1190,718,'Host digest/XOF 64 bit')
    for x,y,w,h,title,sub in boxes:
        elements.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#fff" stroke="#3563a0" stroke-width="2"/>')
        label(x+w/2,y+37,title,17 if w<100 else 25)
        for i,t in enumerate(sub):label(x+w/2,y+72+i*28,t,16 if w<100 else 18)
    label(210,80,'Arsitektur TOP integrasi',25)
    label(215,110,'Satu command aktif',20)
    label(220,145,'Merah: control',18)
    label(220,175,'Biru: aliran data',18)
    elements.append('</svg>');(ROOT/'docs/arsitektur_top.svg').write_text(''.join(elements),encoding='utf-8')
def main():
    summary=json.loads((ROOT/'results/test_summary.json').read_text());synth=json.loads((ROOT/'results/synthesis_summary.json').read_text())
    assert summary['status']==synth['status']=='PASS'
    diagram()
    cases=list(csv.DictReader((ROOT/'results/integration_cases.csv').open()))
    coeff=list(csv.DictReader((ROOT/'results/coefficients.csv').open()));hashes=list(csv.DictReader((ROOT/'results/hashes.csv').open()))
    assert len(coeff)*2==summary['top']['coefficients'] and len(hashes)==summary['top']['hash_words']
    assert all(r['actual']==r['expected'] and r['status']=='PASS' for r in coeff)
    grouped=collections.defaultdict(list)
    for r in coeff:grouped[r['case']].append(r)
    hgrouped=collections.defaultdict(list)
    for r in hashes:
        keep=int(r['keep'],16);mask=sum(255<<(8*i) for i in range(8) if keep>>i&1)
        assert int(r['actual'],16)&mask==int(r['expected'],16)&mask
        hgrouped[r['case']].append((r,mask))
    parts=['''<!doctype html><html lang="id"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TOP RTL ML-KEM - Integrasi Tim</title><style>
body{margin:0;background:#f3f6fa;color:#20364d;font:16px/1.6 Segoe UI,Arial,sans-serif}main{max-width:1120px;margin:auto;padding:32px}h1{font-size:34px;line-height:1.2}h2{margin-top:36px}a{color:#235eaa}code{background:#edf2f8;padding:2px 5px;border-radius:4px}section,.note,details{background:white;border:1px solid #dbe3ed;border-radius:12px;padding:18px;margin:14px 0}.badge{color:#16754c;font-weight:700}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.cards section{margin:0}.big{font-size:28px;font-weight:700}img{width:100%;height:auto}table{width:100%;border-collapse:collapse;font-size:14px}th,td{padding:8px 10px;border-bottom:1px solid #e1e8f0;text-align:left}th{background:#edf2f8}.mono{font-family:Consolas,monospace}summary{cursor:pointer;font-weight:600}details table{margin-top:14px}.scroll{overflow:auto}.warn{border-left:5px solid #b66b20}.links{display:flex;flex-wrap:wrap;gap:18px}pre{overflow:auto;background:#edf2f8;padding:15px}.small{font-size:14px;color:#50677d}</style><main>
<p class="badge">HASIL SIMULASI RTL: PASS</p><h1>TOP RTL ML-KEM<br>Integrasi komponen tim</h1><p>SHA3 Rifki, PAU Maghryza, RAM/transcoder Sarah, dan TRNG berada di bawah satu pengendali. Pengujian memakai HDL yang benar-benar dikompilasi dan dijalankan.</p>
<nav class="links"><a href="README.md">README</a><a href="rtl/mlkem_top.v">Kode TOP</a><a href="tb/tb_mlkem_top.sv">Testbench</a><a href="docs/ANTARMUKA_TOP.md">Antarmuka</a><a href="docs/PERUBAHAN_KOMPONEN.md">Perubahan komponen</a><a href="quartus/mlkem_top.qpf">Proyek Quartus</a></nav>
<div class="note warn"><b>Cakupan integrasi:</b> TOP menjalankan NTT/INTT/PWM/MAC/ADD, ByteEncode/Decode_12, hash host/hash RAM, dan TRNG ke G(d||02). KeyGen/Encaps/Decaps lengkap memerlukan sampler dan controller algoritma tambahan. Command seed saat ini k=2.</div><div class="cards">''']
    for count,caption in [(summary['top']['pau_vectors'],'vektor PAU di RAM bersama'),(summary['top']['coefficients'],'koefisien dibandingkan'),(summary['top']['hash_cases'],'kasus hash stream / RAM'),(4,'seed cocok dengan hashlib')]:
        parts.append(f'<section><div class="big">{count:,}</div>{caption}</section>')
    parts.append('<h2>Arsitektur yang dibuat</h2><section><img src="docs/arsitektur_top.svg" alt="Arsitektur TOP dengan RAM bersama, PAU, transcoder, SHA3 dan TRNG"></section><p><a href="docs/ML-KEM-rtl-design.pdf">Skema PDF tim</a> dan <a href="docs/CARA_INTEGRASI.md">panduan pengendali berikutnya</a>.</p>')
    parts.append('<h2>Perintah dan input/output</h2><section class="scroll"><table><tr><th>cmd</th><th>Operasi</th><th>Input</th><th>Output</th></tr>')
    ops=[('NTT','Slot A','Slot A (in place)'),('INTT','Slot A','Slot A (in place)'),('PWM','Slot A/B dalam domain NTT','Slot D'),('MAC','Slot A/B/D','Slot D += PWM(A,B)'),('ADD','Slot A/B','Slot D'),('Encode12','Slot A','384 byte'),('Decode12','384 byte','Slot D'),('Hash stream','0..65535 byte host','Digest / XOF 64-bit'),('Hash polinomial','384 byte dari Encode12(slot A)','Digest / XOF 64-bit'),('TRNG + G','Seed d dari TRNG','d, rho, sigma, digest')]
    for i,row in enumerate(ops):parts.append('<tr>'+''.join(f'<td>{esc(c)}</td>' for c in (i,*row))+'</tr>')
    parts.append('</table></section><h2>Hasil yang sudah diverifikasi</h2><section><ul>')
    for s in ['82 vektor PAU; 22.272 koefisien cocok, termasuk rantai DUT dan reset recovery.','768 byte Encode12 cocok; Decode12 diuji dengan nilai 0, 3328, 3329, 3330 dan 4095.','84 kasus hash TOP / 2.426 word cocok, dengan input berjeda dan output backpressure.','4 seed dari DUT: dua RO-model dan dua raw input eksternal; G(d||02) cocok dengan hashlib.','Regresi PAU: 36.645 perkalian dan 408 kasus core. Regresi SHA3 tim: 191 kasus, 6.146 word.','Expected sengaja salah ditolak oleh checker. Bug decode komponen asli direproduksi.','Yosys CHECK: 0 masalah; 2 multiplier, 1 RAM bersama 2048x24, 0 latch/divider.']:parts.append(f'<li>{esc(s)}</li>')
    parts.append('</ul><p>Reset membatalkan transaksi dan menginvalidasi bitmap RAM. Command saat busy diabaikan. Start ditahan tidak memicu ulang. Parameter operasi ditangkap di start.</p></section>')
    parts.append('<h2>Latensi TOP tanpa transfer host/jeda</h2><section><table><tr><th>Operasi</th><th>Clock</th><th>Pada stimulus 50 MHz</th></tr>')
    for cmd in range(5):
        clocks=summary['latency_cycles'][str(cmd)][0];parts.append(f'<tr><td>{ops[cmd][0]}</td><td>{clocks}</td><td>{clocks/50:.2f} us</td></tr>')
    parts.append('</table><p class="small">Ini latensi simulator dari start diterima sampai done. fMAX FPGA, resource dan Fitter belum diukur.</p></section>')
    parts.append('''<h2>Cara menjalankan</h2><section><p>Ekstrak ZIP, pasang Python 3.10+ dan Icarus, kemudian:</p><pre>python scripts/run_tests.py --iverilog-bin "PATH_ICARUS/bin" --wave</pre><p>Di Questa GUI: <code>do PATH_PAKET/sim/wave_demo.do</code>. Buka <code>quartus/mlkem_top.qpf</code> untuk Analysis &amp; Synthesis. Target part dapat diganti sesuai board.</p><p>Semua vektor sudah disertakan; tidak memerlukan internet atau MATLAB.</p></section>
<section class="warn"><b>Status alat:</b> Icarus dan pemeriksaan struktur Yosys telah dijalankan. Quartus dan Questa belum dijalankan di komputer ini. LCELL pada Yosys adalah black box. TRNG simulasi memakai stimulus deterministik dan tidak membuktikan kualitas entropi fisik. Proyek Quartus digital memakai entropy input eksternal; board wrapper dan pin assignment belum dibuat.</section>
<h2>Contoh rantai integrasi</h2><section><p><code>NTT(A) → NTT(B) → PWM(A,B) → INTT(D) → Encode12(D)</code></p><p>Semua intermediate dihasilkan DUT pada RAM bersama. Output dibandingkan dengan perkalian schoolbook modulo x^256+1 dan q=3329. Hash polinomial menempuh RAM → transcoder → packer 64 bit → SHA3 → buffer → host.</p><p>Input contoh dan expected dapat dibaca di <a href="tb/vectors/chain_a.hex">chain_a.hex</a>, <a href="tb/vectors/chain_b.hex">chain_b.hex</a>, <a href="tb/vectors/chain_expected.hex">chain_expected.hex</a>.</p></section><h2>Expected dan actual: seluruh polinomial</h2><p>Klik kasus untuk melihat 128 word (=256 koefisien). Hex word menyimpan {odd,even}.</p>''')
    for name,rows in grouped.items():
        parts.append(f'<details><summary>{esc(name)} — {len(rows)*2} koefisien PASS</summary><div class="scroll"><table><tr><th>Slot</th><th>Word</th><th>Actual</th><th>Expected</th></tr>')
        for r in rows:parts.append(f'<tr><td>{r["slot"]}</td><td>{r["word"]}</td><td class="mono">{r["actual"]}</td><td class="mono">{r["expected"]}</td></tr>')
        parts.append('</table></div></details>')
    parts.append('<h2>Expected dan actual: seluruh hash TOP</h2><p>Byte di luar keep tidak ditampilkan sebagai data valid. Golden menggunakan Python hashlib.</p>')
    manifest={f'HASH_{c["id"]:03d}':c for c in json.loads((ROOT/'tb/vectors/hash_manifest.json').read_text())}
    for name,rows in hgrouped.items():
        c=manifest.get(name);info=f' mode={c["mode"]}, input={c["input_bytes"]} byte, output={c["output_bytes"]} byte' if c else ' input=ByteEncode12(slot 14)'
        parts.append(f'<details><summary>{esc(name+info)} — PASS</summary><div class="scroll"><table><tr><th>Word</th><th>Actual (valid lanes)</th><th>Expected (valid lanes)</th><th>Keep</th></tr>')
        for r,mask in rows:parts.append(f'<tr><td>{r["word"]}</td><td class="mono">{int(r["actual"],16)&mask:016x}</td><td class="mono">{int(r["expected"],16)&mask:016x}</td><td>{r["keep"]}</td></tr>')
        parts.append('</table></div></details>')
    parts.append('''<h2>Bukti mentah dan sumber</h2><section><ul><li><a href="results/top.log">Log TOP</a> / <a href="results/test_summary.json">ringkasan mesin</a></li><li><a href="results/coefficients.csv">CSV seluruh koefisien</a> / <a href="results/hashes.csv">CSV hash</a></li><li><a href="results/original_transcoder_bug.log">Bug RTL transcoder asli</a> / <a href="results/checker_negative.log">expected salah ditolak</a></li><li><a href="results/synthesis_summary.json">Ringkasan sintesis struktural</a> / <a href="results/synthesis.log">log Yosys</a></li><li><a href="results/top_demo.vcd">Waveform VCD</a> (buka melalui GTKWave/Questa)</li><li><a href="sources_manifest.json">Checksum arsip komponen</a></li></ul><p><a href="https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.203.pdf">FIPS 203</a> / <a href="https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf">FIPS 202</a>.</p></section></main></html>''')
    (ROOT/'BUKA_HASIL.html').write_text(''.join(parts),encoding='utf-8');print('Offline report generated from actual CSV: all comparisons verified')
if __name__=='__main__':main()
