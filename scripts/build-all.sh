#!/bin/bash
# scripts/build-all.sh — build completo do Capivara no macOS ARM64
#
# Ordem:
#   1. gfxstream (meson/ninja) → libgfxstream_backend.0.dylib
#   2. cargo build workspace   → libkrun.dylib + capy
#
# Pré-requisitos: ./scripts/setup-macos.sh
#
# Uso:
#   ./scripts/build-all.sh [--release]

set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="debug"
CARGO_FLAGS=""

for arg in "$@"; do
    case $arg in
        --release) PROFILE="release"; CARGO_FLAGS="--release" ;;
    esac
done

echo "╔══════════════════════════════════════════════╗"
echo "║  Capivara build — macOS ARM64 ($PROFILE)    "
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: gfxstream ──────────────────────────────
DYLIB="$REPO_ROOT/vendor/gfxstream/build-macos/host/libgfxstream_backend.0.dylib"
if [ ! -f "$DYLIB" ]; then
    echo "→ Step 1: compilando gfxstream..."
    "$REPO_ROOT/scripts/build-gfxstream.sh"
else
    echo "→ Step 1: gfxstream já compilado ($(ls -lh "$DYLIB" | awk '{print $5}'))"
fi
export GFXSTREAM_PATH="$REPO_ROOT/vendor/gfxstream/build-macos/host"
echo ""

# ── Step 2: libkrun + capy ──────────────────────────
echo "→ Step 2: compilando workspace Cargo..."
cd "$REPO_ROOT"
cargo build $CARGO_FLAGS \
    -p libkrun --features libkrun/gpu-gfxstream,libkrun/blk \
    -p capy

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✓  Build concluído                          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

CAPY="$REPO_ROOT/target/$PROFILE/capy"
LIBKRUN="$REPO_ROOT/target/$PROFILE/libkrun.dylib"
echo "Artefatos:"
ls -lh "$CAPY" "$LIBKRUN" 2>/dev/null | awk '{print "  "$5, $9}'
echo ""
echo "Próximo passo — rodar (assinatura e env vars automáticos):"
echo ""
echo "  CAPY_PROFILE=$PROFILE ./scripts/run-capy.sh --root /tmp/miniroot --exec /bin/sh"
echo ""
echo "Se /tmp/miniroot não existir: ./scripts/make-miniroot.sh"
