#!/usr/bin/env bash
# scripts/prepare-userdata.sh — gera uma userdata F2FS FRESCA de fábrica.
#
# Por que existe:
#   O init_user0 (vdc cryptfs init_user0) SÓ passa numa F2FS limpa de fábrica.
#   Qualquer userdata que já bootou e foi morta abruptamente (pkill/CTRL+C) fica
#   com o journal F2FS sujo; no remount o F2FS faz rollback para um checkpoint
#   inconsistente e o init_user0 falha → "Rebooting into recovery: init_user0_failed".
#
#   A fonte determinística de uma F2FS limpa é a userdata.img (sparse) dentro do
#   ZIP de imagens do AOSP Cuttlefish. Este script extrai e expande para raw.
#
# REGRA DE OURO DE SEGURANÇA DE DISCO:
#   NUNCA aponte o capy para este master nem para imagens originais. Sempre BOOTE
#   a partir de uma CÓPIA em /tmp (boot-android.sh já faz isso). Bootar grava no
#   disco e suja o F2FS — a próxima boot falharia o init_user0.
#
# Uso:
#   ./scripts/prepare-userdata.sh [saida.img]
#       default saida: /tmp/capy-userdata.img (cópia de trabalho, descartável)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$REPO_ROOT/inputs/aosp_cf_arm64_only_phone-img-15581820.zip"
OUT="${1:-/tmp/capy-userdata.img}"

[[ -f "$ZIP" ]] || { echo "✗ ZIP do AOSP não encontrado: $ZIP" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Extraindo userdata.img (sparse) de $ZIP..."
unzip -o -j "$ZIP" userdata.img -d "$TMP" >/dev/null

echo "==> Expandindo sparse → raw em $OUT..."
python3 "$REPO_ROOT/scripts/android_sparse_to_raw.py" "$TMP/userdata.img" "$OUT"

# Sanidade: magic F2FS (0x10 0x20 0xf5 0xf2) em offset 1024
MAGIC="$(xxd -s 1024 -l 4 -p "$OUT" 2>/dev/null || true)"
if [[ "$MAGIC" != "1020f5f2" ]]; then
  echo "✗ magic F2FS inesperado em $OUT: $MAGIC (esperado 1020f5f2)" >&2
  exit 1
fi
echo "✓ userdata F2FS fresca pronta: $OUT ($(ls -lh "$OUT" | awk '{print $5}'))"
echo "  Boote sempre a partir de uma CÓPIA desta imagem (nunca da original)."
