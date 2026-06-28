#!/usr/bin/env bash
# scripts/boot-android.sh — arranca o Android com oemlock stub + frp symlink automáticos
#
# Uso:
#   ./scripts/boot-android.sh [--kernel K] [--initramfs I] [--disk D] ... [--vcpus N] [--ram-mib M]
#
# Todos os argumentos são passados direto ao capy. O script:
#   1. Inicia capy em background
#   2. Espera ADB conectar (via vsock bridge)
#   3. Envia oemlock_stub e inicia em background no guest
#   4. Cria symlink /dev/block/by-name/frp → /dev/block/vdc com perms corretas
#   5. Fica em foreground — CTRL+C mata o capy e o bridge

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${CAPY_PROFILE:-debug}"
CAPY="$REPO_ROOT/target/$PROFILE/capy"
OEMLOCK_STUB="$REPO_ROOT/tools/oemlock-stub/oemlock_stub"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[[ -f "$CAPY" ]] || die "$CAPY não encontrado — rode ./scripts/build-all.sh"
[[ -f "$OEMLOCK_STUB" ]] || die "$OEMLOCK_STUB não encontrado — rode ./tools/oemlock-stub/build.sh"

# Verifica se --allow-transport-mismatch já está nos args do usuário
_has_transport_flag=0
for _arg in "$@"; do
  [[ "$_arg" == "--allow-transport-mismatch" ]] && _has_transport_flag=1
done

codesign --sign - \
  --entitlements "$REPO_ROOT/vendor/libkrun/hvf-entitlements.plist" \
  --force "$CAPY" 2>/dev/null

export DYLD_LIBRARY_PATH="$REPO_ROOT/target/$PROFILE:$REPO_ROOT/vendor/gfxstream/build-macos/host:$REPO_ROOT/build/libkrunfw:/opt/homebrew/lib"
export VK_ICD_FILENAMES="/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json"
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0

[[ -e "$REPO_ROOT/target/$PROFILE/libkrun.1.dylib" ]] || \
  ln -sf "$REPO_ROOT/target/$PROFILE/libkrun.dylib" \
         "$REPO_ROOT/target/$PROFILE/libkrun.1.dylib"

[[ -f "$REPO_ROOT/build/libkrunfw/libkrunfw.5.dylib" ]] || \
  bash "$REPO_ROOT/scripts/libkrunfw/bootstrap.sh"

rm -f /tmp/capy-adb-5556.sock

echo "==> Iniciando capy..."
if [[ "$_has_transport_flag" == "0" ]]; then
  "$CAPY" "$@" --allow-transport-mismatch &
else
  "$CAPY" "$@" &
fi
CAPY_PID=$!
echo "    PID=$CAPY_PID"

cleanup() {
  echo ""
  echo "==> Encerrando capy (PID=$CAPY_PID)..."
  kill "$CAPY_PID" 2>/dev/null || true
  wait "$CAPY_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Espera ADB ficar disponível ───────────────────────────────────────────────
# Aguarda ADB estar em estado "device" (não apenas "connected").
# adbd escuta direto em vsock:5555 (service.adb.listen_addrs no super.img) e
# ro.adb.secure=0, então não há prompt de autorização. capy faz bridge
# tcp 127.0.0.1:5556 → vsock:5555. Timeout de 120s cobre o tempo até adbd subir.
echo "==> Aguardando ADB em estado device (127.0.0.1:5556)..."
ADB_SERIAL="127.0.0.1:5556"
ADB_TIMEOUT=120
ADB_START=$SECONDS

while true; do
  if ! kill -0 "$CAPY_PID" 2>/dev/null; then
    die "capy morreu antes do ADB conectar"
  fi
  (( SECONDS - ADB_START < ADB_TIMEOUT )) || die "ADB não chegou a estado device em ${ADB_TIMEOUT}s"
  if [[ "$(adb -s "$ADB_SERIAL" get-state 2>/dev/null | tr -d '\r')" == "device" ]]; then
    break
  fi
  # Conectar cedo demais (antes do adbd subir o listener vsock) cacheia uma
  # entrada "offline" que `adb connect` sozinho NÃO refresca. disconnect antes
  # de reconectar limpa o estado preso — sem isso o boot trava esperando device.
  adb disconnect "$ADB_SERIAL" >/dev/null 2>&1 || true
  adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
  sleep 2
done
ok "ADB em estado device em $ADB_SERIAL ($(( SECONDS - ADB_START ))s)"

# /data já está montado quando ADB alcança device state.
# Garante /data/local/tmp (pode não existir em primeiro boot)
adb -s "$ADB_SERIAL" shell "mkdir -p /data/local/tmp; chmod 777 /data/local/tmp" >/dev/null 2>&1 || true

# ── frp symlink (PRECISA de root) ────────────────────────────────────────────
# PersistentDataBlockService (OnBootPhase_500) lê /dev/block/by-name/frp.
# O 3º disco do capy (frp.img) aparece como /dev/block/vdc, mas não há symlink
# by-name porque androidboot.partition_map não mapeia vdc→frp neste boot.
# IMPORTANTE: /dev/block é root-only — operações têm de rodar via `su 0`, senão
# falham silenciosamente (o usuário 'shell' não tem permissão) e o
# PersistentDataBlockService derruba o system_server em loop.
echo "==> Criando symlink frp (root)..."
adb -s "$ADB_SERIAL" shell "su 0 sh -c 'ln -sf /dev/block/vdc /dev/block/by-name/frp; chown root:system /dev/block/vdc; chmod 0660 /dev/block/vdc'" >/dev/null 2>&1
if adb -s "$ADB_SERIAL" shell "ls /dev/block/by-name/frp" >/dev/null 2>&1; then
  ok "frp: /dev/block/by-name/frp → /dev/block/vdc"
else
  warn "frp symlink não confirmado — PersistentDataBlockService pode reciclar o system_server"
fi

# ── oemlock stub ─────────────────────────────────────────────────────────────
# OemLockService espera pelo binder android.hardware.oemlock.IOemLock/default.
# vendor.oemlock_default (HAL real do Cuttlefish) requer /dev/hvc10 e crasha.
# Registramos o stub antes que OemLockService entre no timeout de 65s.
echo "==> Enviando e iniciando oemlock_stub..."
adb -s "$ADB_SERIAL" push "$OEMLOCK_STUB" /data/local/tmp/oemlock_stub >/dev/null
adb -s "$ADB_SERIAL" shell chmod 755 /data/local/tmp/oemlock_stub
# Roda em background no guest; nohup garante que siga vivo quando o shell ADB sair.
# O processo é independente do system_server: sobrevive a reinícios dele e mantém
# o binder IOemLock/default registrado no servicemanager.
adb -s "$ADB_SERIAL" shell "nohup /data/local/tmp/oemlock_stub >/dev/null 2>&1 &"
if adb -s "$ADB_SERIAL" shell "service check android.hardware.oemlock.IOemLock/default" 2>/dev/null | grep -q "found"; then
  ok "oemlock_stub registrado (IOemLock/default: found)"
else
  warn "IOemLock/default ainda não registrado — pode levar 1-2s"
fi

# ── Aguarda boot_completed ───────────────────────────────────────────────────
# Primeiro boot de userdata fresca é lento (dexopt + restart do system_server até
# achar frp/oemlock). É resiliente: o system_server reinicia e encontra os fixes.
echo "==> Aguardando sys.boot_completed=1..."
BOOT_TIMEOUT=300
BOOT_START=$SECONDS
while true; do
  kill -0 "$CAPY_PID" 2>/dev/null || die "capy morreu antes de boot_completed"
  (( SECONDS - BOOT_START < BOOT_TIMEOUT )) || die "boot_completed não chegou em ${BOOT_TIMEOUT}s"
  adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
  if [[ "$(adb -s "$ADB_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
    break
  fi
  sleep 3
done
ok "BOOT COMPLETO — sys.boot_completed=1 ($(( SECONDS - BOOT_START ))s após injeção)"

# ── Fica em foreground ───────────────────────────────────────────────────────
echo ""
echo "==> Android rodando. Próximo passo: scrcpy. (CTRL+C para encerrar)"
echo ""

wait "$CAPY_PID"
