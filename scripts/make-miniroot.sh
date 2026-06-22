#!/bin/bash
# scripts/make-miniroot.sh — criar rootfs mínimo para testes SP-3
#
# Usa Alpine minirootfs arm64 como base.
# Resultado: /tmp/miniroot/ (pronto para krun_set_root)
#
# Uso:
#   ./scripts/make-miniroot.sh [out_dir] [init.krun]

set -e

MINIROOT="${1:-/tmp/miniroot}"
INIT_KRUN="${2:-}"
ALPINE_VERSION="3.21.3"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
ALPINE_TGZ="/tmp/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"

echo "→ Criando miniroot em $MINIROOT"

if [ ! -f "$ALPINE_TGZ" ]; then
    echo "→ Baixando Alpine minirootfs arm64..."
    curl -L "$ALPINE_URL" -o "$ALPINE_TGZ"
fi

rm -rf "$MINIROOT"
mkdir -p "$MINIROOT"
tar xzf "$ALPINE_TGZ" -C "$MINIROOT"

echo "✓ Miniroot criado: $(du -sh "$MINIROOT" | cut -f1)"
echo ""
if [ -n "$INIT_KRUN" ]; then
    cp "$INIT_KRUN" "$MINIROOT/init.krun"
    chmod +x "$MINIROOT/init.krun"
    echo "✓ init.krun instalado: $MINIROOT/init.krun"
else
    echo "Falta o init.krun (compilar uma vez):"
    echo "  cargo build --target aarch64-unknown-linux-musl --package krun-init --release"
    echo "  ./scripts/make-miniroot.sh $MINIROOT target/aarch64-unknown-linux-musl/release/krun-init"
fi
echo ""
echo "Uso:"
echo "  ./scripts/run-capy.sh --root $MINIROOT --exec /bin/sh"
