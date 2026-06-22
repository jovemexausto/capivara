#!/usr/bin/env python3
"""Convert Android sparse images to raw images.

Usage:
    python3 scripts/android_sparse_to_raw.py input.img output.raw.img
"""

import argparse
import os
import struct
import sys

SPARSE_HEADER_MAGIC = 0xED26FF3A
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_FILL = 0xCAC2
CHUNK_TYPE_DONT_CARE = 0xCAC3
CHUNK_TYPE_CRC32 = 0xCAC4


def read_exact(f, n):
    data = f.read(n)
    if len(data) != n:
        raise EOFError("unexpected EOF")
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        header = read_exact(f, 28)
        (
            magic,
            major,
            minor,
            file_hdr_sz,
            chunk_hdr_sz,
            blk_sz,
            total_blks,
            total_chunks,
            checksum,
        ) = struct.unpack("<I4H4I", header)
        if magic != SPARSE_HEADER_MAGIC:
            raise SystemExit(f"not an Android sparse image: 0x{magic:08x}")

        if file_hdr_sz > 28:
            f.read(file_hdr_sz - 28)

        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "wb") as out:
            out.truncate(total_blks * blk_sz)

            cur_block = 0
            for _ in range(total_chunks):
                chunk_hdr = read_exact(f, chunk_hdr_sz)
                chunk_type, reserved, chunk_sz, total_sz = struct.unpack(
                    "<2H2I", chunk_hdr
                )
                data_sz = total_sz - chunk_hdr_sz

                if chunk_type == CHUNK_TYPE_RAW:
                    out.seek(cur_block * blk_sz)
                    out.write(read_exact(f, data_sz))
                elif chunk_type == CHUNK_TYPE_FILL:
                    fill_val = read_exact(f, 4)
                    out.seek(cur_block * blk_sz)
                    remaining = chunk_sz * blk_sz
                    block = fill_val * (blk_sz // 4)
                    while remaining > 0:
                        take = min(remaining, blk_sz)
                        out.write(block[:take])
                        remaining -= take
                elif chunk_type == CHUNK_TYPE_DONT_CARE:
                    pass
                elif chunk_type == CHUNK_TYPE_CRC32:
                    f.seek(4, os.SEEK_CUR)
                else:
                    raise SystemExit(f"unknown sparse chunk type: 0x{chunk_type:04x}")

                cur_block += chunk_sz

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
