#!/usr/bin/env bash
# scripts/regen-initramfs.sh — reconstrói o initramfs com os módulos de um build
# de kernel novo (artefatos do workflow build-gki) + os fixes de boot do Capivara.
#
# POR QUE: o initramfs embute /lib/modules/<KVER>/ (árvore kernel/*.ko + metadados).
# O first-stage init carrega os módulos listados em modules.load — hoje só
# virtio_blk.ko e vmw_vsock_virtio_transport.ko. Quando o kernel é rebuildado
# (ex.: pra ligar CONFIG_DMABUF_HEAPS_SYSTEM), o <KVER>/vermagic muda e os .ko
# antigos param de carregar ("module ... disagrees about version" / CRC). É
# preciso trocar a árvore de módulos inteira pela do build novo e renomear o dir
# pro <KVER> novo (o init procura por /lib/modules/$(uname -r) sem fallback).
#
# Uso:
#   scripts/regen-initramfs.sh <artifacts-dir> <initramfs-orig.cpio.gz> <saida.cpio.gz>
#
#   <artifacts-dir>  pasta baixada do artefato do workflow build-gki (contém
#                    system_dlkm_staging_archive.tar.gz e/ou os .ko soltos, Image).
#
# Também injeta /init.cf.rc (mesmo fix de frp do patch-initramfs.sh).
#
# NOTA: primeira versão — validar contra os artefatos reais. Os pontos que
# dependem do layout exato do artefato falham com mensagem clara em vez de
# adivinhar (fonte dos módulos, KVER, presença dos módulos do modules.load).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_abspath() { case "$1" in /*) printf '%s\n' "$1";; *) printf '%s/%s\n' "$(pwd)" "$1";; esac; }
ART="$(_abspath "${1:?uso: regen-initramfs.sh <artifacts-dir> <orig.cpio.gz> <out.cpio.gz>}")"
SRC="$(_abspath "${2:?faltou o initramfs original}")"
OUT="$(_abspath "${3:?faltou o caminho de saída}")"
RC="$REPO_ROOT/patches/initramfs/init.cf.rc"

for p in "$ART" "$SRC" "$RC"; do
  [[ -e "$p" ]] || { echo "✗ não encontrado: $p" >&2; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NEWMOD="$TMP/newmod"; OLDFS="$TMP/oldfs"
mkdir -p "$NEWMOD" "$OLDFS"

# ── 1. obter a árvore de módulos nova (lib/modules/<KVER>) dos artefatos ─────────
# Preferência: system_dlkm_staging_archive.tar.gz (tem metadados completos).
# Fallback: copiar os .ko soltos preservando a estrutura kernel/... (sem metadados
# regenerados — só serve se o build já trouxer modules.dep junto).
STAGING="$(find "$ART" -name 'system_dlkm_staging_archive.tar.gz' | head -1 || true)"
if [[ -n "$STAGING" ]]; then
  echo "→ extraindo módulos de $(basename "$STAGING")"
  tar -xzf "$STAGING" -C "$NEWMOD"
else
  echo "→ system_dlkm_staging_archive.tar.gz ausente; tentando lib/modules/ solto nos artefatos"
  SRCMODDIR="$(find "$ART" -type d -path '*/lib/modules/*' -name 'kernel' -print -quit | xargs -r dirname || true)"
  [[ -n "$SRCMODDIR" ]] || { echo "✗ não achei nem o staging archive nem uma árvore lib/modules/<KVER> nos artefatos ($ART). Verifique o layout do artefato." >&2; exit 1; }
  mkdir -p "$NEWMOD/lib/modules"
  cp -a "$SRCMODDIR" "$NEWMOD/lib/modules/"
fi

# localizar o dir lib/modules/<KVER> resultante
NEW_KVER_DIR="$(find "$NEWMOD" -type d -path '*/lib/modules/*' -name 'kernel' -print -quit | xargs -r dirname || true)"
[[ -n "$NEW_KVER_DIR" ]] || { echo "✗ árvore de módulos extraída não tem lib/modules/<KVER>/kernel" >&2; exit 1; }
NEW_KVER="$(basename "$NEW_KVER_DIR")"
echo "✓ KVER novo: $NEW_KVER"

# ── 2. extrair o initramfs original ─────────────────────────────────────────────
echo "→ extraindo initramfs original"
( cd "$OLDFS" && gzip -dc "$SRC" | cpio -idmu --quiet )

OLD_KVER_DIR="$(find "$OLDFS/lib/modules" -maxdepth 1 -mindepth 1 -type d -print -quit || true)"
[[ -n "$OLD_KVER_DIR" ]] || { echo "✗ initramfs original não tem /lib/modules/<KVER>" >&2; exit 1; }
OLD_KVER="$(basename "$OLD_KVER_DIR")"
echo "✓ KVER antigo: $OLD_KVER"

# preservar a modules.load curada do Cuttlefish (quais módulos o first-stage carrega)
MODULES_LOAD="$(cat "$OLD_KVER_DIR/modules.load" 2>/dev/null || true)"
[[ -n "$MODULES_LOAD" ]] || { echo "✗ modules.load do initramfs original vazio/ausente — não sei quais módulos carregar" >&2; exit 1; }
echo "→ modules.load preservado:"; echo "$MODULES_LOAD" | sed 's/^/    /'

# ── 3. trocar a árvore de módulos ───────────────────────────────────────────────
rm -rf "$OLDFS/lib/modules/$OLD_KVER"
cp -a "$NEW_KVER_DIR" "$OLDFS/lib/modules/$NEW_KVER"
# restaurar a modules.load curada (a do build pode diferir/estar vazia)
printf '%s\n' "$MODULES_LOAD" > "$OLDFS/lib/modules/$NEW_KVER/modules.load"

# ── 4. validar: todo módulo do modules.load existe na árvore nova ───────────────
missing=0
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if [[ ! -f "$OLDFS/lib/modules/$NEW_KVER/$m" ]]; then
    echo "✗ módulo do modules.load ausente na árvore nova: $m" >&2
    echo "  (pode ter virado built-in no novo .config, ou mudou de caminho — ajuste modules.load)" >&2
    missing=1
  fi
done <<< "$MODULES_LOAD"
[[ "$missing" == "0" ]] || { echo "✗ abortando: módulos de first-stage faltando" >&2; exit 1; }
echo "✓ todos os módulos do modules.load presentes no KVER novo"

# ── 5. injetar o fix de boot (init.cf.rc) ───────────────────────────────────────
cp "$RC" "$OLDFS/init.cf.rc"

# ── 6. reempacotar ──────────────────────────────────────────────────────────────
echo "→ reempacotando → $OUT"
( cd "$OLDFS" && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9 > "$OUT" )

# sanidade
gzip -dc "$OUT" | cpio -t --quiet 2>/dev/null | grep -qx "./init.cf.rc" || { echo "✗ init.cf.rc ausente no resultado" >&2; exit 1; }
gzip -dc "$OUT" | cpio -t --quiet 2>/dev/null | grep -qx "./lib/modules/$NEW_KVER/modules.load" || { echo "✗ modules tree ausente no resultado" >&2; exit 1; }
echo "✓ initramfs regenerado: $OUT ($(ls -lh "$OUT" | awk '{print $5}'))  KVER=$NEW_KVER"
echo "  Lembre de usar o Image novo (do mesmo build) junto com este initramfs."
