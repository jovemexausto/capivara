#!/usr/bin/env bash
# scripts/patch-initramfs.sh — injeta os fixes de boot do Capivara no initramfs GKI.
#
# Hoje injeta apenas /init.cf.rc, que cria o symlink by-name/frp + perms cedo
# (em `on init`, antes do system_server), fechando a corrida que matava a 1ª
# instância do system_server em PersistentDataBlockService (phase 500). Ver
# patches/initramfs/init.cf.rc e BOOT-RECIPE.md.
#
# init.rc do segundo estágio faz `import /init.${ro.hardware}.rc`; ro.hardware=cf
# neste guest, então o arquivo TEM de se chamar init.cf.rc na raiz do ramdisk.
#
# Uso: patch-initramfs.sh <initramfs-original.cpio.gz> <saida.cpio.gz>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Resolve para caminhos absolutos: o script faz cd para um tmpdir mais abaixo.
_abspath() { case "$1" in /*) printf '%s\n' "$1";; *) printf '%s/%s\n' "$(pwd)" "$1";; esac; }
SRC="$(_abspath "${1:?uso: patch-initramfs.sh <orig.cpio.gz> <out.cpio.gz>}")"
OUT="$(_abspath "${2:?uso: patch-initramfs.sh <orig.cpio.gz> <out.cpio.gz>}")"
RC="$REPO_ROOT/patches/initramfs/init.cf.rc"

[[ -f "$SRC" ]] || { echo "✗ initramfs original não encontrado: $SRC" >&2; exit 1; }
[[ -f "$RC" ]]  || { echo "✗ init.cf.rc não encontrado: $RC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ extraindo $SRC"
( cd "$TMP" && gzip -dc "$SRC" | cpio -idmu --quiet )

echo "→ injetando /init.cf.rc"
cp "$RC" "$TMP/init.cf.rc"

echo "→ reempacotando (newc, root-owned) → $OUT"
( cd "$TMP" && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9 > "$OUT" )

# Sanidade: init.cf.rc tem de estar presente
if ! gzip -dc "$OUT" | cpio -t --quiet 2>/dev/null | grep -qx "./init.cf.rc"; then
  echo "✗ init.cf.rc ausente do initramfs reempacotado" >&2; exit 1
fi
echo "✓ initramfs patchado: $OUT ($(ls -lh "$OUT" | awk '{print $5}'))"
