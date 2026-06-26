#!/bin/bash
# tools/oemlock-stub/build.sh — cross-compile the oemlock binder stub.
#
# Usage:
#   ANDROID_NDK_ROOT=/path/to/ndk ./tools/oemlock-stub/build.sh [out_path]
#
# Defaults to the Homebrew Android NDK cask location if ANDROID_NDK_ROOT is
# unset. Produces an aarch64 ELF that links libbinder_ndk.so for the
# AIBinder_Class_define/AIBinder_new symbols it needs at link time (these are
# exported by the public NDK stub .so since API 29); AServiceManager_addService
# and ABinderProcess_* are platform-only symbols not exposed in the public NDK,
# so the binary dlopen()s the on-device libbinder_ndk.so and dlsym()s those at
# runtime instead.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SCRIPT_DIR/oemlock_stub}"

if [ -z "$ANDROID_NDK_ROOT" ]; then
    ANDROID_NDK_ROOT=$(find /opt/homebrew/Caskroom/android-ndk -maxdepth 2 -iname "AndroidNDK*.app" -exec echo "{}/Contents/NDK" \; 2>/dev/null | head -1)
fi

if [ -z "$ANDROID_NDK_ROOT" ] || [ ! -d "$ANDROID_NDK_ROOT" ]; then
    echo "✗ NDK não encontrado. Defina ANDROID_NDK_ROOT ou instale: brew install --cask android-ndk"
    exit 1
fi

CLANG="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android30-clang++"
if [ ! -x "$CLANG" ]; then
    echo "✗ $CLANG não existe (NDK incompleto ou layout diferente do esperado)"
    exit 1
fi

"$CLANG" -O2 -static-libstdc++ -fno-exceptions -fno-rtti \
    -o "$OUT" \
    "$SCRIPT_DIR/oemlock_stub.cpp" \
    -lbinder_ndk -ldl

echo "✓ $OUT"
