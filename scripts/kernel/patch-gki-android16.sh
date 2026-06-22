#!/bin/bash
# scripts/kernel/patch-gki-android16.sh — aplica o patch do GKI usado pelo Capivara

set -euo pipefail

KERNEL_COMMON="${1:?uso: $0 <path-para-kernel/common>}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cp "$REPO_ROOT/kernel/drivers/char/tpm/tpm_virtio.c" \
  "$KERNEL_COMMON/drivers/char/tpm/tpm_virtio.c"

KCONFIG="$KERNEL_COMMON/drivers/char/tpm/Kconfig"
if ! grep -q "TCG_VIRTIO" "$KCONFIG"; then
  printf '\nconfig TCG_VIRTIO\n\ttristate "Virtio TPM Interface"\n\tdepends on TCG_TPM && VIRTIO\n\thelp\n\t  This driver provides TPM via virtio transport.\n\t  The VMM exposes a virtio device (ID 29) with a single\n\t  virtqueue for TPM command/response exchange.\n\n\t  To compile as a module, choose M; module: tpm_virtio.\n' >> "$KCONFIG"
fi

MAKEFILE="$KERNEL_COMMON/drivers/char/tpm/Makefile"
if ! grep -q "tpm_virtio" "$MAKEFILE"; then
  echo "obj-\$(CONFIG_TCG_VIRTIO) += tpm_virtio.o" >> "$MAKEFILE"
fi

VIRTIO_IDS="$KERNEL_COMMON/include/uapi/linux/virtio_ids.h"
if ! grep -q "VIRTIO_ID_TPM" "$VIRTIO_IDS"; then
  sed -i '/^#endif/i #define VIRTIO_ID_TPM\t\t\t29 /* virtio TPM */' "$VIRTIO_IDS" || \
    echo "#define VIRTIO_ID_TPM 29" >> "$VIRTIO_IDS"
fi

cd "$KERNEL_COMMON"
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 89/' Makefile

grep -rl "bootconfig" arch/ 2>/dev/null | while read -r f; do
  sed -i 's/ bootconfig//g' "$f"
  sed -i 's/bootconfig //g' "$f"
done

CONFIG="arch/arm64/configs/gki_defconfig"
sed -i '/^CONFIG_VIRTIO_MMIO=/d' "$CONFIG"
sed -i '/^CONFIG_TCG_TPM=/d' "$CONFIG"
sed -i '/^CONFIG_TCG_VTPM_PROXY=/d' "$CONFIG"
sed -i '/^CONFIG_TCG_VIRTIO=/d' "$CONFIG"
sed -i '/^CONFIG_CRYPTO_USER=/d' "$CONFIG"
sed -i '/^# CONFIG_DRM_VIRTIO_GPU is not set$/d' "$CONFIG"
sed -i '/^CONFIG_DRM_VIRTIO_GPU=/d' "$CONFIG"
sed -i '/^CONFIG_UDMABUF=/d' "$CONFIG"
sed -i '/^# CONFIG_UDMABUF is not set$/d' "$CONFIG"
sed -i 's/ bootconfig//' "$CONFIG"

sed -i '/^CONFIG_VIRTIO_BALLOON=m$/a CONFIG_VIRTIO_MMIO=y' "$CONFIG"
sed -i '/^CONFIG_BUG_ON_DATA_CORRUPTION=y$/a CONFIG_CRYPTO_USER=y' "$CONFIG"
sed -i '/^# CONFIG_DEVPORT is not set$/a CONFIG_TCG_TPM=y\nCONFIG_TCG_VIRTIO=y' "$CONFIG"
sed -i '/^CONFIG_DRM=y$/a CONFIG_DRM_VIRTIO_GPU=y' "$CONFIG"
sed -i '/^CONFIG_DRM_VIRTIO_GPU=y$/a CONFIG_UDMABUF=y' "$CONFIG"

echo "✓ Kernel patched in $KERNEL_COMMON"
