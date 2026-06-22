#!/bin/bash
# scripts/run-capy.sh — roda capy com todos os env vars necessários
#
# Uso:
#   ./scripts/run-capy.sh --root /tmp/miniroot --exec /test.sh --verbose
#   ./scripts/run-capy.sh --kernel /path/to/Image --verbose

set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${CAPY_PROFILE:-debug}"

CAPY="$REPO_ROOT/target/$PROFILE/capy"

if [ ! -f "$CAPY" ]; then
    echo "✗ $CAPY não existe. Rode ./scripts/build-all.sh primeiro."
    exit 1
fi

# Assinar com entitlement HVF (necessário toda vez que o binário é recompilado)
codesign --sign - \
  --entitlements "$REPO_ROOT/vendor/libkrun/hvf-entitlements.plist" \
  --force "$CAPY"

# DYLD_LIBRARY_PATH:
#   target/$PROFILE        → libkrun.dylib (symlink libkrun.1.dylib → libkrun.dylib necessário)
#   gfxstream build-macos  → libgfxstream_backend.0.dylib
#   build/libkrunfw        → libkrunfw.5.dylib (kernel embutido)
#   /opt/homebrew/lib      → libvulkan.dylib (brew install vulkan-loader)
export DYLD_LIBRARY_PATH="$REPO_ROOT/target/$PROFILE:$REPO_ROOT/vendor/gfxstream/build-macos/host:$REPO_ROOT/build/libkrunfw:/opt/homebrew/lib"

# VK_ICD_FILENAMES → MoltenVK ICD (brew install molten-vk)
export VK_ICD_FILENAMES="/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json"

# Sem isso, o compositor do gfxstream falha com:
#   [mvk-error] SPIR-V to MSL conversion error: Argument buffer resource
#   base type could not be determined.
#   [compositor_vk.cpp(370)] #x failed with VK_ERROR_INITIALIZATION_FAILED
# Workaround: desabilita Metal argument buffers no MoltenVK (impacto de
# performance esperado: baixo para o compositor gfxstream; revisitar se
# jogos com descriptor indexing pesado mostrarem regressão — ver TECH.md)
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0

# Symlink necessário: dyld procura libkrun.1.dylib mas o cargo gera libkrun.dylib
if [ ! -e "$REPO_ROOT/target/$PROFILE/libkrun.1.dylib" ]; then
    ln -sf "$REPO_ROOT/target/$PROFILE/libkrun.dylib" \
           "$REPO_ROOT/target/$PROFILE/libkrun.1.dylib"
fi

if [ ! -f "$REPO_ROOT/build/libkrunfw/libkrunfw.5.dylib" ]; then
    bash "$REPO_ROOT/scripts/libkrunfw/bootstrap.sh"
fi

# O socket do bridge ADB é fixo; remove sobras de execuções anteriores para evitar EADDRINUSE.
rm -f /tmp/capy-adb-5555.sock

exec "$CAPY" "$@"
