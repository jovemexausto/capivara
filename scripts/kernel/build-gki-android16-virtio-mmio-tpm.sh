#!/bin/bash
# scripts/kernel/build-gki-android16-virtio-mmio-tpm.sh — reproduz o build do GKI

set -euo pipefail

ARTIFACTS_DIR="${1:-/tmp/artifacts}"
KERNEL_DIR="${2:-/tmp/kernel}"
KERNEL_DIST_DIR="${3:-/tmp/kernel-dist}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v repo >/dev/null 2>&1; then
  echo "repo não encontrado" >&2
  exit 1
fi

mkdir -p "$KERNEL_DIR"
cd "$KERNEL_DIR"
repo init -u https://android.googlesource.com/kernel/manifest -b common-android16-6.12 --depth=1
repo sync -c -j"$(nproc)" -q --no-clone-bundle

"$REPO_ROOT/scripts/kernel/patch-gki-android16.sh" "$KERNEL_DIR/common"

cd "$KERNEL_DIR"
./tools/bazel run --config=local --lto=none //common:kernel_aarch64_dist -- --destdir="$KERNEL_DIST_DIR/kernel"

"$REPO_ROOT/scripts/kernel/collect-gki-artifacts.sh" "$KERNEL_DIST_DIR" "$ARTIFACTS_DIR" "$KERNEL_DIR/common"

echo "✓ GKI build completo em $ARTIFACTS_DIR"
