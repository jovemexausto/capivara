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

# ── 3. merge do fragmento de Kconfig ────────────────────────────────────────────────────────────
# merge_config -m só faz merge TEXTUAL: anexa as linhas do fragmento no fim do
# gki_defconfig. Isso deixa o defconfig em forma NÃO-canônica (símbolos fora de
# ordem, comentários, redundâncias). O Kleaf, no kernel_aarch64_config, roda
# `savedefconfig` e exige que o gki_defconfig commitado JÁ esteja na forma minimal
# que o savedefconfig produz — senão falha com
# "savedefconfig does not match common/arch/arm64/configs/gki_defconfig".
DEFCONFIG="$KERNEL_COMMON/arch/arm64/configs/gki_defconfig"
KCONFIG_CONFIG="$DEFCONFIG" "$KERNEL_COMMON/scripts/kconfig/merge_config.sh" -m \
  "$DEFCONFIG" "$CONFIG_FRAGMENT"

# ── 3.5 normaliza o gki_defconfig via savedefconfig do próprio Kleaf ──────────────────────────────
# Regenera o gki_defconfig na forma canônica (resolve a ordem/minimalização que o
# check do kernel_aarch64_config exige). No Kleaf, savedefconfig é um SUBCOMANDO
# do target _config (não um target próprio — `//common:kernel_aarch64_savedefconfig`
# não existe); é o mesmo comando que a doc do GKI manda rodar quando dá
# "savedefconfig does not match". Lê o defconfig mergeado acima, deriva o .config
# e escreve o savedefconfig de volta no source tree, in-place.
cd "$KERNEL_DIR"
./tools/bazel run --config=local --lto=none //common:kernel_aarch64_config -- savedefconfig

# Guard: o savedefconfig só mantém símbolos não-default. Se algum dos nossos não
# sobreviveu (dependência não satisfeita, símbolo renomeado, etc.), o build dist
# seguiria sem ele e o boot/codec regrediria silenciosamente — falha aqui.
for sym in \
  CONFIG_VIRTIO_MMIO=y CONFIG_TCG_VIRTIO=y CONFIG_DRM_VIRTIO_GPU=y \
  CONFIG_DMABUF_HEAPS=y CONFIG_DMABUF_HEAPS_SYSTEM=y; do
  if ! grep -qx "$sym" "$DEFCONFIG"; then
    echo "✗ $sym sumiu do gki_defconfig após savedefconfig — dependência não satisfeita?" >&2
    echo "  defconfig atual:"; grep -iE "DMABUF|VIRTIO_MMIO|TCG_VIRTIO|VIRTIO_GPU" "$DEFCONFIG" >&2 || true
    exit 1
  fi
done
echo "✓ gki_defconfig normalizado; símbolos do Capivara presentes"

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
