#!/bin/bash
# scripts/kernel/build-gki.sh — reproduz o build do GKI usado pelo Capivara (virtio-tpm)
#
# Pipeline, em ordem: repo sync (revisão pinada da versão escolhida) → aplica patch do driver
# virtio-tpm → merge do fragmento de Kconfig → build via Bazel/Kleaf → coleta e verifica os
# artefatos.
#
# Tudo que define O QUE muda (manifest pinado, patch) vive em patches/kernel/<versão>/; o
# fragmento de Kconfig é compartilhado entre versões em patches/kernel/capivara_gki.config — este
# script só orquestra. Ver patches/kernel/README.md.
#
# Uso: build-gki.sh <android-version> [artifacts-dir] [kernel-dir] [kernel-dist-dir]
#   android-version: android14 | android15 | android16 (default: android16)
#
# Trocar de versão é só apontar pra outra pasta em patches/kernel/ — ver
# "Como adicionar uma nova versão" em patches/kernel/README.md para o processo de pinar e gerar o
# patch contra um branch GKI diferente (common-android<N>-<kernel-version>).

set -euo pipefail

ANDROID_VERSION="${1:-android16}"
ARTIFACTS_DIR="${2:-/tmp/artifacts}"
KERNEL_DIR="${3:-/tmp/kernel}"
KERNEL_DIST_DIR="${4:-/tmp/kernel-dist}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHES_DIR="$REPO_ROOT/patches/kernel"
VERSION_DIR="$PATCHES_DIR/$ANDROID_VERSION"
PINNED_MANIFEST="$VERSION_DIR/pinned-manifest.xml"
PATCH="$VERSION_DIR/0001-add-tpm-virtio-driver.patch"
CONFIG_FRAGMENT="$PATCHES_DIR/capivara_gki.config"

if ! command -v repo >/dev/null 2>&1; then
  echo "✗ repo não encontrado" >&2
  exit 1
fi
if [ ! -d "$VERSION_DIR" ]; then
  echo "✗ versão desconhecida: $ANDROID_VERSION (não existe $VERSION_DIR)." >&2
  echo "  Versões disponíveis: $(ls -d "$PATCHES_DIR"/android* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')" >&2
  exit 1
fi
for f in "$PINNED_MANIFEST" "$PATCH" "$CONFIG_FRAGMENT"; do
  if [ ! -f "$f" ]; then
    echo "✗ arquivo esperado não encontrado: $f" >&2
    exit 1
  fi
done

echo "→ versão: $ANDROID_VERSION ($VERSION_DIR)"

# ── 1. repo sync na revisão pinada ──────────────────────────────────────────────────────────────
mkdir -p "$KERNEL_DIR"
cd "$KERNEL_DIR"

if [ -d .repo ]; then
  echo "✓ $KERNEL_DIR já inicializado (provavelmente restaurado de cache) — pulando repo init"
else
  repo init -u "file://$PINNED_MANIFEST" --standalone-manifest
fi
repo sync -c -j"$(nproc)" -q --no-clone-bundle

# ── 2. aplica o patch do driver virtio-tpm ──────────────────────────────────────────────────────
KERNEL_COMMON="$KERNEL_DIR/common"
cd "$KERNEL_COMMON"

# Idempotência: se o patch já foi aplicado (re-execução local contra um $KERNEL_DIR reaproveitado),
# não falha.
if git apply --check -p1 "$PATCH" 2>/dev/null; then
  git apply -p1 "$PATCH"
  echo "✓ Patch aplicado: $(basename "$PATCH")"
elif git apply --reverse --check -p1 "$PATCH" 2>/dev/null; then
  echo "✓ Patch já estava aplicado: $(basename "$PATCH")"
else
  echo "✗ Patch não aplica nem está aplicado — árvore divergiu da revisão pinada em" \
       "patches/kernel/$ANDROID_VERSION/pinned-manifest.xml. Não vou tentar adivinhar; atualize o" \
       "pin ou regenere o patch (ver patches/kernel/README.md)." >&2
  exit 1
fi

# ── 3. aplica o fragmento de Kconfig em forma CANÔNICA ──────────────────────────────────────────
# Por que não merge_config.sh -m: ele faz merge TEXTUAL, anexando as linhas do
# fragmento no fim do gki_defconfig. O Kleaf, no kernel_aarch64_config, roda
# `savedefconfig` e exige que o gki_defconfig JÁ esteja na forma minimal/canônica
# que o savedefconfig produz (símbolos nas posições certas, sem comentários) —
# senão falha com "savedefconfig does not match ...gki_defconfig". E não dá pra
# corrigir com `_config -- savedefconfig`: o check roda ao BUILDAR o target _config,
# antes do subcomando executar (chicken-and-egg).
#
# Então inserimos cada símbolo na posição canônica que o savedefconfig emite (ordem
# derivada do próprio diff do savedefconfig). Partimos de um gki_defconfig pristino
# (git checkout) pra ser idempotente mesmo num checkout cacheado já modificado por
# runs anteriores; a única mudança da patch 0001 no defconfig é remover ` bootconfig`
# do CONFIG_CMDLINE, que o checkout reverteu e re-aplicamos aqui.
DEFCONFIG="$KERNEL_COMMON/arch/arm64/configs/gki_defconfig"
git -C "$KERNEL_COMMON" checkout -- arch/arm64/configs/gki_defconfig
sed -i '/^CONFIG_CMDLINE=/s/ bootconfig"/"/' "$DEFCONFIG"

# Inserções nas posições canônicas (mesma ordem/lugar do savedefconfig).
# IDEMPOTENTES: alguns símbolos (ex.: UDMABUF, DMABUF_HEAPS) já vêm no gki_defconfig
# base do android16 — inserir de novo geraria duplicata ("reassigning to symbol")
# e quebraria o check do savedefconfig. ins_* só insere se o símbolo ainda não
# existir; se a âncora sumir numa versão futura do GKI, falha alto.
ins_after()  { grep -qxF "$2" "$DEFCONFIG" && return 0
  grep -qxF "$1" "$DEFCONFIG" || { echo "✗ âncora ausente p/ '$2': $1" >&2; exit 1; }
  sed -i "/^$1\$/a $2" "$DEFCONFIG"; }
ins_before() { grep -qxF "$2" "$DEFCONFIG" && return 0
  grep -qxF "$1" "$DEFCONFIG" || { echo "✗ âncora ausente p/ '$2': $1" >&2; exit 1; }
  sed -i "/^$1\$/i $2" "$DEFCONFIG"; }

ins_after  "# CONFIG_DEVPORT is not set"     "CONFIG_TCG_TPM=y"
ins_after  "CONFIG_TCG_TPM=y"                "CONFIG_TCG_VIRTIO=y"
ins_after  "CONFIG_DRM=y"                    "CONFIG_DRM_VIRTIO_GPU=y"
ins_before "CONFIG_DMABUF_SYSFS_STATS=y"     "CONFIG_DMABUF_HEAPS=y"
ins_before "CONFIG_DMABUF_HEAPS=y"           "CONFIG_UDMABUF=y"
ins_after  "CONFIG_DMABUF_SYSFS_STATS=y"     "CONFIG_DMABUF_HEAPS_SYSTEM=y"
ins_after  "CONFIG_VIRTIO_BALLOON=m"         "CONFIG_VIRTIO_MMIO=y"
ins_after  "CONFIG_BUG_ON_DATA_CORRUPTION=y" "CONFIG_CRYPTO_USER=y"

# Guard: todos os símbolos do Capivara presentes (pega âncora que sumiu / drift do GKI).
for sym in $(grep -E '^CONFIG_' "$CONFIG_FRAGMENT"); do
  if ! grep -qx "$sym" "$DEFCONFIG"; then
    echo "✗ $sym ausente do gki_defconfig — âncora de inserção mudou no GKI? ajuste scripts/kernel/build-gki.sh" >&2
    grep -iE "DMABUF|VIRTIO_MMIO|TCG_VIRTIO|VIRTIO_GPU|CRYPTO_USER" "$DEFCONFIG" >&2 || true
    exit 1
  fi
done
echo "✓ gki_defconfig em forma canônica; símbolos do Capivara presentes"
cd "$KERNEL_DIR"

# ── 4. build via Bazel/Kleaf ────────────────────────────────────────────────────────────────────
./tools/bazel run --config=local --lto=none //common:kernel_aarch64_dist -- --destdir="$KERNEL_DIST_DIR/kernel"

# ── 5. coleta e verifica os artefatos ───────────────────────────────────────────────────────────
mkdir -p "$ARTIFACTS_DIR"

find "$KERNEL_DIST_DIR" -name "*.ko" 2>/dev/null | sort | tee "$ARTIFACTS_DIR/ko-list.txt" > /dev/null || true

for f in \
  "$KERNEL_DIST_DIR/kernel/Image" \
  "$KERNEL_DIST_DIR/kernel/arch/arm64/boot/Image" \
  "$KERNEL_DIST_DIR/kernel/boot.img" \
  "$KERNEL_DIST_DIR/kernel/system_dlkm.img" \
  "$KERNEL_DIST_DIR/kernel/system_dlkm_staging_archive.tar.gz"; do
  [ -f "$f" ] && cp "$f" "$ARTIFACTS_DIR/"
done

while IFS= read -r ko; do
  rel="${ko#${KERNEL_DIST_DIR}/}"
  mkdir -p "$ARTIFACTS_DIR/$(dirname "$rel")"
  cp "$ko" "$ARTIFACTS_DIR/$rel"
done < <(find "$KERNEL_DIST_DIR" -name "*.ko" 2>/dev/null | sort)

# tpm_virtio.ko é o ponto inteiro deste build. Se não aparecer em lugar nenhum dos artefatos
# coletados, o patch ou o fragmento de config falharam silenciosamente em algum lugar antes do
# build do Bazel terminar — isso não deve passar como build verde.
if ! find "$ARTIFACTS_DIR" -name "tpm_virtio.ko" | grep -q .; then
  echo "✗ tpm_virtio.ko não encontrado em nenhum artefato coletado — patch ou config do" \
       "virtio-tpm não pegou." >&2
  exit 1
fi

echo "✓ GKI build completo ($ANDROID_VERSION) em $ARTIFACTS_DIR"
