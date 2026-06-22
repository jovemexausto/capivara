#!/bin/bash
# build-android-gpt.sh — monta um disco GPT único com as partições by-name
# que o first-stage init / AVB do Android esperam encontrar (Cuttlefish-style).
#
# Requer: brew install gptfdisk  (sgdisk)
#
# Uso:
#   ./build-android-gpt.sh /path/to/images /tmp/capy-android-gpt.img

set -euo pipefail

IMAGES_DIR="${1:?uso: $0 <images_dir> <out.img>}"
OUT="${2:?uso: $0 <images_dir> <out.img>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

SECTOR=512

# Partições exigidas pelo first-stage init / AVB.
# Ordem não importa: o lookup é por label GPT.
PART_NAMES=(boot_a init_boot_a metadata super vbmeta_a vbmeta_system_a vbmeta_system_dlkm_a vbmeta_vendor_dlkm_a vendor_boot_a misc)
PART_SIZES=(68M 12M 16M 0M 1M 1M 1M 1M 64M 16M)

SUPER_SRC=super.raw.img
if [ ! -f "$IMAGES_DIR/$SUPER_SRC" ]; then
  SUPER_SRC=super.img
fi

SUPER_FILE="$IMAGES_DIR/$SUPER_SRC"
SUPER_WORK="$TMP_DIR/super.raw.img"

# Cuttlefish ships super.img as Android sparse image in newer builds.
# Expand it before we size/copy it into the GPT wrapper.
if python3 - "$SUPER_FILE" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
sys.exit(0 if magic == 0xED26FF3A else 1)
PY
then
  python3 "$SCRIPT_DIR/android_sparse_to_raw.py" "$SUPER_FILE" "$SUPER_WORK"
  SUPER_FILE="$SUPER_WORK"
fi

METADATA_SRC=metadata.raw.img
if [ ! -f "$IMAGES_DIR/$METADATA_SRC" ]; then
  METADATA_SRC=metadata.img
fi

PART_SRCS=(boot.img init_boot.img "$METADATA_SRC" "$SUPER_SRC" vbmeta.img vbmeta_system.img vbmeta_system_dlkm.img vbmeta_vendor_dlkm.img vendor_boot.img misc.img)

# Tamanho real do super, arredondado pra cima em MB + 16MB de folga.
SUPER_BYTES=$(stat -f%z "$SUPER_FILE")
SUPER_MB=$(( (SUPER_BYTES + 1024*1024 - 1) / (1024*1024) + 16 ))
PART_SIZES[3]="${SUPER_MB}M"

echo "${SUPER_SRC}: ${SUPER_BYTES} bytes -> partição super de ${SUPER_MB}M"

# Tamanho total do disco: soma das partições + overhead GPT (~2MB).
TOTAL_MB=2
for sz in "${PART_SIZES[@]}"; do
  TOTAL_MB=$(( TOTAL_MB + ${sz%M} ))
done
echo "Tamanho total do disco: ${TOTAL_MB}M"

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1m count="$TOTAL_MB" 2>/dev/null
sgdisk -og "$OUT" >/dev/null

PART_NUM=1
for i in "${!PART_NAMES[@]}"; do
  name="${PART_NAMES[$i]}"
  size="${PART_SIZES[$i]}"
  sgdisk -n "0:0:+${size}" -c "0:${name}" "$OUT" >/dev/null
  PART_NUM=$((PART_NUM + 1))
done

sgdisk -p "$OUT"

for i in "${!PART_NAMES[@]}"; do
  src_name="${PART_SRCS[$i]}"
  [ -z "$src_name" ] && continue
  name="${PART_NAMES[$i]}"
  num=$((i + 1))
  start_sector=$(sgdisk -i "$num" "$OUT" | awk '/First sector/ {print $3}')
  src="$IMAGES_DIR/$src_name"
  if [ "$name" = "super" ]; then
    src="$SUPER_FILE"
  fi
  echo "Escrevendo $src -> partição $name (#$num, setor $start_sector)"
  dd if="$src" of="$OUT" bs=$SECTOR seek="$start_sector" conv=notrunc 2>/dev/null
done

echo ""
echo "✓ Disco composite criado: $OUT"
sgdisk -p "$OUT"
