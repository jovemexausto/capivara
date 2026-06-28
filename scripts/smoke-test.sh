#!/usr/bin/env bash
# scripts/smoke-test.sh — verifica que o boot chega a sys.boot_completed=1
#
# Uso:
#   ./scripts/smoke-test.sh [--snapshot <dir>] [--timeout <segundos>]
#
# Defaults:
#   --snapshot  snapshots/boot-complete-2026-06-28-gles-composer
#   --timeout   180
#
# Saída:
#   0  — boot_completed=1 dentro do timeout
#   1  — timeout expirado sem boot_completed
#   2  — pré-condição falhou (artefato ausente, hash errado, ADB não disponível)
#
# O smoke-test NÃO aplica os workarounds de oemlock/frp — ele usa o userdata.img
# do snapshot, que já tem o estado desses workarounds gravado. Se usar um userdata
# limpo, espere um boot mais longo ou falha.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Parâmetros ──────────────────────────────────────────────────────────────
SNAPSHOT="$REPO_ROOT/snapshots/boot-complete-2026-06-28-gles-composer"
TIMEOUT_SECS=180
POLL_INTERVAL=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --timeout)  TIMEOUT_SECS="$2"; shift 2 ;;
    *) echo "Uso: $0 [--snapshot <dir>] [--timeout <s>]" >&2; exit 2 ;;
  esac
done

# ── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit "${2:-1}"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

# ── Manifesto: hashes esperados ──────────────────────────────────────────────
declare -A EXPECTED_SHA256=(
  [gki-virtio-mmio-tpm-Image]="26db4c456d1b01e8ea2119c4368e76a1dfc795c09ebf77fd4896b491b367abfb"
  [gki-android-hybrid-v5-skiavk.cpio.gz]="c590e68c2808ba5e73054c100157b73b1ce7285fde45e9b201c7a9890d8fd95f"
  [super.img]="93a55ed917d934fa0049351a3b6fd7b18f9a58a19e8a0a42c2d7ce59d9bf820d"
  [frp.img]="5bdacd0eb510c431cd32d1a4529904e2f1be16e1c67da8777b42d7e05dd3acb3"
  # userdata.img é intencionalmente excluído: muda a cada boot (ADB state)
)

# ── Pré-condições ────────────────────────────────────────────────────────────
echo "Snapshot: $SNAPSHOT"
echo ""

echo "==> Verificando artefatos..."
for name in "${!EXPECTED_SHA256[@]}"; do
  path="$SNAPSHOT/$name"
  [[ -f "$path" ]] || fail "$path não encontrado" 2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  expected="${EXPECTED_SHA256[$name]}"
  if [[ "$actual" != "$expected" ]]; then
    fail "$name: hash errado\n  esperado: $expected\n  obtido:   $actual" 2
  fi
  ok "$name"
done

userdata="$SNAPSHOT/userdata.img"
[[ -f "$userdata" ]] || fail "userdata.img não encontrado" 2
ok "userdata.img (sem verificação de hash — muda a cada boot)"

echo ""
echo "==> Verificando binários..."

CAPY="$REPO_ROOT/target/debug/capy"
[[ -f "$CAPY" ]] || fail "$CAPY não encontrado — rode ./scripts/build-all.sh primeiro" 2
ok "capy: $CAPY"

GFXSTREAM_LIB="$REPO_ROOT/vendor/gfxstream/build-macos/host/libgfxstream_backend.0.dylib"
[[ -f "$GFXSTREAM_LIB" ]] || fail "libgfxstream_backend não encontrado — rode ./scripts/build-gfxstream.sh" 2
ok "libgfxstream_backend"

[[ -f "$REPO_ROOT/build/libkrunfw/libkrunfw.5.dylib" ]] || \
  bash "$REPO_ROOT/scripts/libkrunfw/bootstrap.sh"
ok "libkrunfw"

command -v adb >/dev/null 2>&1 || fail "adb não encontrado no PATH" 2
ok "adb"

echo ""
echo "==> Iniciando boot..."

# Copia de segurança do userdata (o capy pode escrever; queremos o original intacto)
WORK_DIR="$(mktemp -d /tmp/capivara-smoke-XXXXXX)"
trap 'rm -rf "$WORK_DIR"; kill "$CAPY_PID" 2>/dev/null || true' EXIT
cp "$userdata" "$WORK_DIR/userdata.img"

LOG="$WORK_DIR/boot.log"
rm -f /tmp/capy-adb-5555.sock

export DYLD_LIBRARY_PATH="$REPO_ROOT/target/debug:$REPO_ROOT/vendor/gfxstream/build-macos/host:$REPO_ROOT/build/libkrunfw:/opt/homebrew/lib"
export VK_ICD_FILENAMES="/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json"
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0

# Assinar
codesign --sign - \
  --entitlements "$REPO_ROOT/vendor/libkrun/hvf-entitlements.plist" \
  --force "$CAPY" 2>/dev/null

# Symlink libkrun
[[ -e "$REPO_ROOT/target/debug/libkrun.1.dylib" ]] || \
  ln -sf "$REPO_ROOT/target/debug/libkrun.dylib" "$REPO_ROOT/target/debug/libkrun.1.dylib"

"$CAPY" \
  --kernel  "$SNAPSHOT/gki-virtio-mmio-tpm-Image" \
  --initramfs "$SNAPSHOT/gki-android-hybrid-v5-skiavk.cpio.gz" \
  --disk "super=$SNAPSHOT/super.img" \
  --disk "userdata=$WORK_DIR/userdata.img" \
  --disk "frp=$SNAPSHOT/frp.img" \
  --vcpus 4 \
  --ram-mib 4096 \
  >"$LOG" 2>&1 &
CAPY_PID=$!

echo "capy PID=$CAPY_PID, log: $LOG"
echo ""

# ── Poll ADB para boot_completed ─────────────────────────────────────────────
echo "==> Aguardando sys.boot_completed=1 (timeout: ${TIMEOUT_SECS}s)..."
START_TS=$SECONDS
BOOT_DONE=0

while (( SECONDS - START_TS < TIMEOUT_SECS )); do
  sleep "$POLL_INTERVAL"

  if ! kill -0 "$CAPY_PID" 2>/dev/null; then
    echo ""
    fail "capy morreu antes do boot_completed. Último log:" 1
  fi

  # Conecta via socket unix do bridge ADB (não precisa de tcpip)
  RESULT=$(adb -s "localabstract:capy-adb-5555" shell getprop sys.boot_completed 2>/dev/null \
           || adb shell getprop sys.boot_completed 2>/dev/null \
           || echo "")

  ELAPSED=$(( SECONDS - START_TS ))
  printf "\r  %ds..." "$ELAPSED"

  if [[ "$RESULT" == "1" ]]; then
    BOOT_DONE=1
    break
  fi
done

echo ""

if [[ "$BOOT_DONE" != "1" ]]; then
  warn "Timeout após ${TIMEOUT_SECS}s sem boot_completed=1"
  echo "Últimas 30 linhas do log:"
  tail -30 "$LOG" || true
  kill "$CAPY_PID" 2>/dev/null || true
  exit 1
fi

ELAPSED=$(( SECONDS - START_TS ))
echo ""
ok "sys.boot_completed=1 em ${ELAPSED}s"

# Props de interesse
echo ""
echo "==> Props do guest:"
for prop in sys.boot_completed init.svc.surfaceflinger init.svc.zygote \
            ro.boot.hardware.gltransport ro.hardware.gralloc; do
  val=$(adb shell getprop "$prop" 2>/dev/null || echo "(erro)")
  printf "  %-40s %s\n" "$prop" "$val"
done

kill "$CAPY_PID" 2>/dev/null || true
echo ""
ok "Smoke test passou."
