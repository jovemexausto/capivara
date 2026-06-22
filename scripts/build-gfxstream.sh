#!/bin/bash
# scripts/build-gfxstream.sh — SP-1: compilar gfxstream no macOS ARM64
# Resultado: vendor/gfxstream/build-macos/host/libgfxstream_backend.0.dylib
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GFXSTREAM_DIR="$REPO_ROOT/vendor/gfxstream"
BUILD_DIR="$GFXSTREAM_DIR/build-macos"

echo "╔══════════════════════════════════════════════╗"
echo "║  Capivara: build gfxstream (SP-1)            ║"
echo "╚══════════════════════════════════════════════╝"

for cmd in meson ninja; do
  command -v $cmd &>/dev/null || { echo "✗ $cmd não encontrado: brew install $cmd"; exit 1; }
done
echo "✓ meson $(meson --version), ninja $(ninja --version)"

# MoltenVK
for p in "$(brew --prefix 2>/dev/null)/share/vulkan/icd.d/MoltenVK_icd.json" \
          "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json"; do
    [ -f "$p" ] && export VK_ICD_FILENAMES="$p" && echo "✓ MoltenVK: $p" && break
done
[ -z "$VK_ICD_FILENAMES" ] && echo "⚠ MoltenVK não encontrado: brew install molten-vk"

cd "$GFXSTREAM_DIR"
[ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"

meson setup \
    -Ddecoders=vulkan \
    -Dgfxstream-build=host \
    -Dlog-level=warn \
    --buildtype=release \
    "$BUILD_DIR"

NCPUS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
ninja -C "$BUILD_DIR" -j "$NCPUS"

DYLIB="$BUILD_DIR/host/libgfxstream_backend.0.dylib"
echo ""
echo "✓ $(ls -lh "$DYLIB" | awk '{print $5, $9}')"
echo ""
echo "Próximo: scripts/build-all.sh"
