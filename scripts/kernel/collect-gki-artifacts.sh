#!/bin/bash
# scripts/kernel/collect-gki-artifacts.sh — coleta os artefatos do build do GKI

set -euo pipefail

DIST_DIR="${1:?uso: $0 <kernel-dist-dir> <artifacts-dir> [kernel-tree-dir]}"
ARTIFACTS_DIR="${2:?uso: $0 <kernel-dist-dir> <artifacts-dir> [kernel-tree-dir]}"
KERNEL_TREE="${3:-}"

mkdir -p "$ARTIFACTS_DIR"

find "$DIST_DIR" -name "failover.ko" -o -name "virtio_blk.ko" 2>/dev/null || true
find "$DIST_DIR" -name "*.ko" 2>/dev/null | sort | tee "$ARTIFACTS_DIR/ko-list.txt" || true

for f in \
  "$DIST_DIR/kernel/Image" \
  "$DIST_DIR/kernel/arch/arm64/boot/Image" \
  "$DIST_DIR/kernel/boot.img"; do
  if [ -f "$f" ]; then
    cp "$f" "$ARTIFACTS_DIR/"
  fi
done

for f in \
  "$DIST_DIR/kernel/system_dlkm.img" \
  "$DIST_DIR/kernel/system_dlkm_staging_archive.tar.gz"; do
  if [ -f "$f" ]; then
    cp "$f" "$ARTIFACTS_DIR/"
  fi
done

while IFS= read -r ko; do
  rel="${ko#${DIST_DIR}/}"
  mkdir -p "$ARTIFACTS_DIR/$(dirname "$rel")"
  cp "$ko" "$ARTIFACTS_DIR/$rel"
done < <(find "$DIST_DIR" -name "*.ko" 2>/dev/null | sort)

if [ -n "$KERNEL_TREE" ] && [ -f "$KERNEL_TREE/drivers/char/tpm/tpm_virtio.ko" ]; then
  cp "$KERNEL_TREE/drivers/char/tpm/tpm_virtio.ko" "$ARTIFACTS_DIR/"
fi

echo "✓ Artefatos coletados em $ARTIFACTS_DIR"
