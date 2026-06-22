#!/usr/bin/env python3
"""
extract_android_boot.py — extrai kernel, ramdisk e dtb de imagens de boot
Android GKI (boot_img_hdr v3/v4, vendor_boot_img_hdr v3/v4), sem depender
de ferramentas externas (unpack_bootimg/AVB).

Uso:
    python3 extract_android_boot.py images/ out/

Gera em out/:
    kernel              ← do boot.img
    boot_ramdisk        ← ramdisk do boot.img (se houver)
    init_boot_ramdisk   ← ramdisk do init_boot.img (se houver)
    vendor_ramdisk      ← ramdisk do vendor_boot.img (se houver)
    ramdisk.cpio.gz     ← vendor_ramdisk (vendor_boot.img) + ramdisk (init_boot.img), concatenados
    dtb                 ← do vendor_boot.img (se presente)
    boot_cmdline.txt    ← cmdline do boot.img
    vendor_cmdline.txt  ← cmdline do vendor_boot.img
"""

import os
import struct
import sys

PAGE = 4096


def read_u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def read_u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def pad(n, page=PAGE):
    return (n + page - 1) // page * page


def parse_boot_img(path):
    """boot.img / init_boot.img — boot_img_hdr v3/v4"""
    with open(path, "rb") as f:
        data = f.read()

    magic = data[0:8]
    if magic != b"ANDROID!":
        raise ValueError(f"{path}: magic inesperado {magic!r}")

    kernel_size = read_u32(data, 8)
    ramdisk_size = read_u32(data, 12)
    os_version = read_u32(data, 16)
    header_size = read_u32(data, 20)
    header_version = read_u32(data, 40)
    cmdline = data[44 : 44 + 1536 + 1024].split(b"\x00")[0].decode("utf-8", "replace")

    print(
        f"  {os.path.basename(path)}: header_version={header_version} "
        f"kernel_size={kernel_size} ramdisk_size={ramdisk_size} "
        f"header_size={header_size}"
    )

    off = PAGE  # header sempre ocupa 1 page (4096) em v3/v4
    kernel = data[off : off + kernel_size]
    off += pad(kernel_size)
    ramdisk = data[off : off + ramdisk_size]
    off += pad(ramdisk_size)

    return {
        "kernel": kernel,
        "ramdisk": ramdisk,
        "cmdline": cmdline,
        "header_version": header_version,
    }


def parse_vendor_boot_img(path):
    """vendor_boot.img — vendor_boot_img_hdr v3/v4"""
    with open(path, "rb") as f:
        data = f.read()

    magic = data[0:8]
    if magic != b"VNDRBOOT":
        raise ValueError(f"{path}: magic inesperado {magic!r}")

    header_version = read_u32(data, 8)
    page_size = read_u32(data, 12)
    vendor_ramdisk_size = read_u32(data, 24)
    cmdline = data[28 : 28 + 2048].split(b"\x00")[0].decode("utf-8", "replace")
    dtb_size = read_u32(data, 2080)

    print(
        f"  {os.path.basename(path)}: header_version={header_version} "
        f"page_size={page_size} vendor_ramdisk_size={vendor_ramdisk_size} "
        f"dtb_size={dtb_size}"
    )

    header_total = pad(2108 if header_version >= 4 else 2092, page_size)

    off = header_total
    vendor_ramdisk = data[off : off + vendor_ramdisk_size]
    off += pad(vendor_ramdisk_size, page_size)
    dtb = data[off : off + dtb_size]
    off += pad(dtb_size, page_size)

    return {
        "vendor_ramdisk": vendor_ramdisk,
        "dtb": dtb,
        "cmdline": cmdline,
        "header_version": header_version,
        "page_size": page_size,
    }


def main():
    if len(sys.argv) != 3:
        print(
            f"Uso: {sys.argv[0]} <dir com boot.img/vendor_boot.img/init_boot.img> <dir saida>"
        )
        sys.exit(1)

    images_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    print("Parseando imagens...")
    boot = parse_boot_img(os.path.join(images_dir, "boot.img"))

    init_boot_path = os.path.join(images_dir, "init_boot.img")
    init_boot = None
    if os.path.exists(init_boot_path):
        init_boot = parse_boot_img(init_boot_path)

    vendor_boot_path = os.path.join(images_dir, "vendor_boot.img")
    vendor_boot = None
    if os.path.exists(vendor_boot_path):
        vendor_boot = parse_vendor_boot_img(vendor_boot_path)

    # kernel
    with open(os.path.join(out_dir, "kernel"), "wb") as f:
        f.write(boot["kernel"])
    print(f"\n✓ kernel: {len(boot['kernel'])} bytes")

    # ramdisk combinado: vendor_ramdisk (vendor_boot) + ramdisk (init_boot ou boot)
    parts = []
    if vendor_boot and vendor_boot["vendor_ramdisk"]:
        parts.append(vendor_boot["vendor_ramdisk"])
        print(f"✓ vendor_ramdisk: {len(vendor_boot['vendor_ramdisk'])} bytes")
    if init_boot and init_boot["ramdisk"]:
        parts.append(init_boot["ramdisk"])
        print(
            f"✓ init_boot ramdisk (generic, com /init): {len(init_boot['ramdisk'])} bytes"
        )
    elif boot["ramdisk"]:
        parts.append(boot["ramdisk"])
        print(f"✓ boot ramdisk: {len(boot['ramdisk'])} bytes")

    if boot["ramdisk"]:
        with open(os.path.join(out_dir, "boot_ramdisk"), "wb") as f:
            f.write(boot["ramdisk"])
    if init_boot and init_boot["ramdisk"]:
        with open(os.path.join(out_dir, "init_boot_ramdisk"), "wb") as f:
            f.write(init_boot["ramdisk"])
    if vendor_boot and vendor_boot["vendor_ramdisk"]:
        with open(os.path.join(out_dir, "vendor_ramdisk"), "wb") as f:
            f.write(vendor_boot["vendor_ramdisk"])

    combined = b"".join(parts)
    ramdisk_out = os.path.join(out_dir, "ramdisk.cpio.gz")
    with open(ramdisk_out, "wb") as f:
        f.write(combined)
    print(f"✓ ramdisk combinado: {ramdisk_out} ({len(combined)} bytes)")

    # dtb
    if vendor_boot and vendor_boot["dtb"]:
        with open(os.path.join(out_dir, "dtb"), "wb") as f:
            f.write(vendor_boot["dtb"])
        print(f"✓ dtb: {len(vendor_boot['dtb'])} bytes")

    # cmdlines
    with open(os.path.join(out_dir, "boot_cmdline.txt"), "w") as f:
        f.write(boot["cmdline"])
    print(f"\nboot cmdline:\n  {boot['cmdline']!r}")

    if vendor_boot:
        with open(os.path.join(out_dir, "vendor_cmdline.txt"), "w") as f:
            f.write(vendor_boot["cmdline"])
        print(f"\nvendor cmdline:\n  {vendor_boot['cmdline']!r}")

    # detectar magic dos primeiros bytes do kernel/ramdisk (sanity check)
    def magic_of(b):
        if b[:2] == b"\x1f\x8b":
            return "gzip"
        if b[:4] == b"\x02\x21\x4c\x18":
            return "lz4 (legacy)"
        if b[:4] == b"\x04\x22\x4d\x18":
            return "lz4"
        if b[:2] == b"MZ":
            return "PE/EFI (kernel Image ARM64 com header EFI)"
        if b[:4] == b"\x28\xb5\x2f\xfd":
            return "zstd"
        return f"desconhecido ({b[:4].hex()})"

    print(f"\nkernel magic: {magic_of(boot['kernel'])}")
    print(f"ramdisk magic: {magic_of(combined)}")


if __name__ == "__main__":
    main()
