#!/bin/bash
# scripts/make-userdata.sh — cria um userdata.img ext4 limpo para o baseline

set -euo pipefail

OUT="${1:-/tmp/userdata.img}"
SIZE="${2:-2G}"

if command -v mkfs.ext4 >/dev/null 2>&1; then
  MKFS=(mkfs.ext4)
elif command -v mke2fs >/dev/null 2>&1; then
  MKFS=(mke2fs -t ext4)
else
  echo "mkfs.ext4 ou mke2fs não encontrado" >&2
  exit 1
fi

rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
"${MKFS[@]}" -L userdata "$OUT"

echo "✓ userdata criado: $OUT ($SIZE)"
