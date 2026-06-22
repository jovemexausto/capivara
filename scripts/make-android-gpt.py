#!/usr/bin/env python3
"""Build a sparse GPT disk image for Cuttlefish/Android.

The image contains GPT partitions with names matching Android's expected
`/dev/block/by-name/*` namespace.
"""

from __future__ import annotations

import argparse
import math
import struct
import uuid
import zlib
from dataclasses import dataclass
from pathlib import Path


SECTOR_SIZE = 512
PARTITION_ENTRY_SIZE = 128
NUM_PARTITION_ENTRIES = 128
GPT_HEADER_LBA = 1
GPT_ENTRY_LBA = 2
GPT_FIRST_USABLE_LBA = 2048
GPT_LAST_RESERVED_LBAS = 33  # 32 sectors table + 1 sector header

GPT_PART_TYPE_LINUX_FS = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
BOOT_NAMES = {
    "boot",
    "init_boot",
    "vendor_boot",
    "vbmeta",
    "vbmeta_system",
    "vbmeta_vendor_dlkm",
    "vbmeta_system_dlkm",
}


@dataclass
class PartitionSpec:
    name: str
    path: Path
    size: int


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def pack_guid(g: uuid.UUID) -> bytes:
    return g.bytes_le


def build_mbr(disk_sectors: int) -> bytes:
    mbr = bytearray(512)
    part_start = 1
    part_sectors = min(disk_sectors - 1, 0xFFFFFFFF)
    entry = struct.pack(
        "<B3sB3sII",
        0x00,
        b"\x00\x02\x00",
        0xEE,
        b"\xff\xff\xff",
        part_start,
        part_sectors,
    )
    mbr[446 : 446 + 16] = entry
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def pack_partition_entry(
    part_type: uuid.UUID, part_guid: uuid.UUID, first_lba: int, last_lba: int, name: str
) -> bytes:
    name_bytes = name.encode("utf-16le")[:72].ljust(72, b"\x00")
    return struct.pack(
        "<16s16sQQQ72s",
        pack_guid(part_type),
        pack_guid(part_guid),
        first_lba,
        last_lba,
        0,
        name_bytes,
    )


def build_gpt_header(
    current_lba: int,
    backup_lba: int,
    first_usable: int,
    last_usable: int,
    disk_guid: uuid.UUID,
    part_entry_lba: int,
    part_entry_crc32: int,
) -> bytes:
    header = struct.pack(
        "<8sIIIIQQQQ16sQIII",
        b"EFI PART",
        0x00010000,
        92,
        0,
        0,
        current_lba,
        backup_lba,
        first_usable,
        last_usable,
        pack_guid(disk_guid),
        part_entry_lba,
        NUM_PARTITION_ENTRIES,
        PARTITION_ENTRY_SIZE,
        part_entry_crc32,
    )
    crc = zlib.crc32(header) & 0xFFFFFFFF
    header = struct.pack(
        "<8sIIIIQQQQ16sQIII",
        b"EFI PART",
        0x00010000,
        92,
        crc,
        0,
        current_lba,
        backup_lba,
        first_usable,
        last_usable,
        pack_guid(disk_guid),
        part_entry_lba,
        NUM_PARTITION_ENTRIES,
        PARTITION_ENTRY_SIZE,
        part_entry_crc32,
    )
    return header.ljust(SECTOR_SIZE, b"\x00")


def normalize_name(name: str, slot_suffix: str) -> str:
    if name in BOOT_NAMES and slot_suffix and not name.endswith(slot_suffix):
        return f"{name}{slot_suffix}"
    return name


def parse_part(spec: str, slot_suffix: str) -> tuple[str, Path]:
    if "=" not in spec:
        raise SystemExit(f"invalid partition spec: {spec!r}; expected name=path")
    name, raw_path = spec.split("=", 1)
    return normalize_name(name, slot_suffix), Path(raw_path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--slot-suffix", default="_a")
    ap.add_argument(
        "--partition",
        action="append",
        required=True,
        help="name=path; name is GPT label",
    )
    args = ap.parse_args()

    parts: list[PartitionSpec] = []
    for spec in args.partition:
        name, path = parse_part(spec, args.slot_suffix)
        if not path.exists():
            raise SystemExit(f"missing input image: {path}")
        parts.append(PartitionSpec(name=name, path=path, size=path.stat().st_size))

    offset_lba = GPT_FIRST_USABLE_LBA
    layout = []
    for part in parts:
        start = offset_lba
        size_lba = math.ceil(part.size / SECTOR_SIZE)
        end = start + size_lba - 1
        layout.append((part, start, end))
        offset_lba = align_up(end + 1, GPT_FIRST_USABLE_LBA)

    disk_sectors = align_up(
        layout[-1][2] + GPT_LAST_RESERVED_LBAS, GPT_FIRST_USABLE_LBA
    )
    disk_bytes = disk_sectors * SECTOR_SIZE
    backup_entry_lba = disk_sectors - 33
    backup_header_lba = disk_sectors - 1
    last_usable = disk_sectors - GPT_LAST_RESERVED_LBAS

    entries = bytearray(PARTITION_ENTRY_SIZE * NUM_PARTITION_ENTRIES)
    for idx, (part, start, end) in enumerate(layout):
        entry = pack_partition_entry(
            GPT_PART_TYPE_LINUX_FS,
            uuid.uuid5(uuid.NAMESPACE_URL, f"capy:{part.name}:{part.path}"),
            start,
            end,
            part.name,
        )
        entries[idx * PARTITION_ENTRY_SIZE : (idx + 1) * PARTITION_ENTRY_SIZE] = entry

    entry_crc = zlib.crc32(entries) & 0xFFFFFFFF
    disk_guid = uuid.uuid4()
    primary_header = build_gpt_header(
        GPT_HEADER_LBA,
        backup_header_lba,
        GPT_FIRST_USABLE_LBA,
        last_usable,
        disk_guid,
        GPT_ENTRY_LBA,
        entry_crc,
    )
    backup_header = build_gpt_header(
        backup_header_lba,
        GPT_HEADER_LBA,
        GPT_FIRST_USABLE_LBA,
        last_usable,
        disk_guid,
        backup_entry_lba,
        entry_crc,
    )

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as f:
        f.truncate(disk_bytes)
        f.seek(0)
        f.write(build_mbr(disk_sectors))
        f.seek(SECTOR_SIZE * GPT_HEADER_LBA)
        f.write(primary_header)
        f.seek(SECTOR_SIZE * GPT_ENTRY_LBA)
        f.write(entries)

        for part, start, _end in layout:
            f.seek(start * SECTOR_SIZE)
            f.write(part.path.read_bytes())

        f.seek(backup_entry_lba * SECTOR_SIZE)
        f.write(entries)
        f.seek(backup_header_lba * SECTOR_SIZE)
        f.write(backup_header)

    print(f"wrote {out} ({disk_bytes} bytes)")
    for part, start, end in layout:
        print(f"{part.name}: LBA {start}-{end} ({part.size} bytes) <- {part.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
