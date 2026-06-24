#!/bin/bash
# scripts/kernel/build-gki-android16-virtio-mmio-tpm.sh — reproduz o build do GKI usado pelo Capivara
#
# Pipeline, em ordem: repo sync (revisão pinada) → aplica patch do driver virtio-tpm → merge do
# fragmento de Kconfig → build via Bazel/Kleaf → coleta e verifica os artefatos.
#
# Tudo que define O QUE muda (manifest pinado, patch, fragmento de config) vive em
# patches/kernel/ — este script só orquestra; nenhuma lógica de patch/config aqui além da
# aplicação. Ver patches/kernel/README.md para o que cada arquivo faz e como atualizar o pin.
#
# Substituiu um esquema antigo de 3 scripts separados (patch-gki-android16.sh,
# collect-gki-artifacts.sh) cada um chamado só por este, mais `sed -i` em linhas-âncora pra editar
# o defconfig — frágil contra drift do AOSP upstream (ver git log deste arquivo / patches/kernel/README.md
# pra detalhes do que já tinha virado no-op silencioso). Consolidado num script só porque nenhuma
# das partes era reusada independentemente.

set -euo pipefail

ARTIFACTS_DIR="${1:-/tmp/artifacts}"
KERNEL_DIR="${2:-/tmp/kernel}"
KERNEL_DIST_DIR="${3:-/tmp/kernel-dist}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHES_DIR="$REPO_ROOT/patches/kernel"
PINNED_MANIFEST="$PATCHES_DIR/pinned-manifest.xml"
PATCH="$PATCHES_DIR/0001-add-tpm-virtio-driver.patch"
CONFIG_FRAGMENT="$PATCHES_DIR/capivara_gki.config"

if ! command -v repo >/dev/null 2>&1; then
  echo "✗ repo não encontrado" >&2
  exit 1
fi
for f in "$PINNED_MANIFEST" "$PATCH" "$CONFIG_FRAGMENT"; do
  if [ ! -f "$f" ]; then
    echo "✗ arquivo esperado não encontrado: $f" >&2
    exit 1
  fi
done

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
       "patches/kernel/pinned-manifest.xml. Não vou tentar adivinhar; atualize o pin ou" \
       "regenere o patch (ver patches/kernel/README.md)." >&2
  exit 1
fi

# ── 3. merge do fragmento de Kconfig ────────────────────────────────────────────────────────────
DEFCONFIG="$KERNEL_COMMON/arch/arm64/configs/gki_defconfig"
KCONFIG_CONFIG="$DEFCONFIG" "$KERNEL_COMMON/scripts/kconfig/merge_config.sh" -m \
  "$DEFCONFIG" "$CONFIG_FRAGMENT"

# ── 4. build via Bazel/Kleaf ────────────────────────────────────────────────────────────────────
cd "$KERNEL_DIR"
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

echo "✓ GKI build completo em $ARTIFACTS_DIR"
