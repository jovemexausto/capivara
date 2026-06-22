#!/bin/bash
# scripts/setup-macos.sh — instalar dependências do host para build do Capivara
#
# Executar uma vez numa máquina nova antes de ./scripts/build-all.sh
#
# Requerimentos:
#   - macOS 13+ (Ventura) com Apple Silicon (M1/M2/M3/M4)
#   - Xcode Command Line Tools
#   - Homebrew

set -e

echo "╔══════════════════════════════════════════════╗"
echo "║  Capivara: setup dependências macOS          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Xcode CLT ──────────────────────────────────────
if ! xcode-select -p &>/dev/null; then
    echo "→ Instalando Xcode Command Line Tools..."
    xcode-select --install
    echo "  Aguarde a instalação e rode este script novamente."
    exit 0
fi
echo "✓ Xcode CLT: $(xcode-select -p)"

# ── Homebrew ───────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo "✗ Homebrew não encontrado."
    echo "  Instale em: https://brew.sh"
    exit 1
fi
echo "✓ Homebrew: $(brew --version | head -1)"

# ── Dependências brew ──────────────────────────────
echo ""
echo "→ Instalando dependências via brew..."

BREW_PKGS=(
    meson         # build system do gfxstream (SP-1)
    ninja         # backend do meson
    molten-vk     # Vulkan → Metal (runtime do gfxstream)
    vulkan-loader # libvulkan.dylib — gfxstream/MoltenVK precisam do loader (SP-3c)
    pkg-config    # usado pelo meson
    FiloSottile/musl-cross/musl-cross  # cross-compile krun-init (aarch64-linux-musl)
)

for pkg in "${BREW_PKGS[@]}"; do
    if brew list "$pkg" &>/dev/null; then
        echo "  ✓ $pkg já instalado"
    else
        echo "  → instalando $pkg..."
        brew install "$pkg"
    fi
done

# ── Rust ───────────────────────────────────────────
echo ""
if ! command -v rustup &>/dev/null; then
    echo "→ Instalando Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    echo "✓ Rust: $(rustc --version)"
fi

# Target musl para compilar krun-init (init estático do guest Linux)
rustup target add aarch64-unknown-linux-musl 2>/dev/null || true

# Configurar linker musl-cross para o target acima
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO_ROOT/.cargo"
if ! grep -q "aarch64-unknown-linux-musl" "$REPO_ROOT/.cargo/config.toml" 2>/dev/null; then
    cat >> "$REPO_ROOT/.cargo/config.toml" << 'EOF'

[target.aarch64-unknown-linux-musl]
linker = "aarch64-linux-musl-gcc"
EOF
    echo "✓ .cargo/config.toml configurado para aarch64-unknown-linux-musl"
fi

echo ""
bash "$REPO_ROOT/scripts/libkrunfw/bootstrap.sh"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✓  Setup concluído                          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Próximo passo:"
echo "  cd $REPO_ROOT"
echo "  ./scripts/build-all.sh"
echo ""
echo "Para compilar o krun-init (uma vez):"
echo "  cargo build --target aarch64-unknown-linux-musl --package krun-init --release"
echo ""
echo "Para testar o boot (SP-3, validado — Linux 6.12.91 + gfxstream OK):"
echo "  ./scripts/make-miniroot.sh"
echo "  cp target/aarch64-unknown-linux-musl/release/krun-init /tmp/miniroot/init.krun"
echo "  chmod +x /tmp/miniroot/init.krun"
echo "  ./scripts/run-capy.sh --root /tmp/miniroot --exec /bin/sh"
