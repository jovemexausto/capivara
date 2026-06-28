#!/usr/bin/env python3
"""raw2png.py — converte um dump de scanout cru do capy (RGBA8888) em PNG.

O viewfinder do capy (CAPY_DUMP_DIR) grava frame-NNN.raw (W*H*4 bytes RGBA) e um
frame-NNN.txt com "WxH ...". Este script lê o .raw, descobre W/H pelo .txt irmão
(ou via --size WxH), e escreve um PNG — sem dependências (PNG na mão via zlib).

Uso:
    scripts/raw2png.py frame-012.raw [saida.png] [--size 1080x1920] [--scale N]
"""
import sys, os, struct, zlib, argparse, re


def read_size_from_sidecar(raw_path):
    txt = os.path.splitext(raw_path)[0] + ".txt"
    if os.path.exists(txt):
        m = re.search(r"(\d+)x(\d+)", open(txt).read())
        if m:
            return int(m.group(1)), int(m.group(2))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--size", help="WxH (senão lê do frame-NNN.txt irmão)")
    ap.add_argument("--scale", type=int, default=1, help="downscale inteiro (ex.: 4)")
    a = ap.parse_args()

    if a.size:
        w, h = (int(x) for x in a.size.lower().split("x"))
    else:
        wh = read_size_from_sidecar(a.raw)
        if not wh:
            sys.exit("✗ sem --size e sem frame-NNN.txt irmão pra descobrir WxH")
        w, h = wh

    data = open(a.raw, "rb").read()
    need = w * h * 4
    if len(data) < need:
        sys.exit(f"✗ raw tem {len(data)} bytes, esperado {need} ({w}x{h}x4)")

    sc = max(1, a.scale)
    ow, oh = w // sc, h // sc
    rows = bytearray()
    for y in range(oh):
        rows.append(0)  # filter byte: None
        base = y * sc * w
        for x in range(ow):
            p = (base + x * sc) * 4
            rows += data[p:p + 3]  # RGB (descarta alpha pro PNG truecolor)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )
    out = a.out or (os.path.splitext(a.raw)[0] + ".png")
    open(out, "wb").write(png)
    # resumo de conteúdo (útil pra distinguir "renderizou preto" de "vazio")
    nz = sum(1 for i in range(0, need, 4 * 997) if data[i] or data[i + 1] or data[i + 2])
    print(f"✓ {out} ({ow}x{oh}) — amostras RGB!=0: {nz}")


if __name__ == "__main__":
    main()
