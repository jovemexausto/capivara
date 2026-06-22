#!/bin/bash
# scripts/libkrunfw/bootstrap.sh — prepara o libkrunfw runtime a partir de um input pinado

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INPUT_DIR="$REPO_ROOT/inputs/libkrunfw"
ARCHIVE="$INPUT_DIR/libkrunfw-prebuilt-aarch64.tgz"
EXPECTED_SHA256="cc82af3b53a0e2bee21c9a339cba2c682c25e9465910480ff8e678f13c39e54c"
OUT_DIR="$REPO_ROOT/build/libkrunfw"

mkdir -p "$INPUT_DIR" "$OUT_DIR"

if [ ! -f "$ARCHIVE" ]; then
  curl -fL "https://github.com/containers/libkrunfw/releases/download/v5.2.0/libkrunfw-prebuilt-aarch64.tgz" -o "$ARCHIVE"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "libkrunfw archive hash mismatch" >&2
  echo "expected: $EXPECTED_SHA256" >&2
  echo "actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

tar xzf "$ARCHIVE" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/libkrunfw/kernel.c" ]; then
  echo "kernel.c not found in libkrunfw archive" >&2
  exit 1
fi

ABI=$(grep '^ABI_VERSION' "$TMP_DIR/libkrunfw/Makefile" | head -1 | awk '{print $3}')
ABI="${ABI:-5}"

cp "$TMP_DIR/libkrunfw/kernel.c" "$OUT_DIR/kernel.c"
cp "$TMP_DIR/Image" "$OUT_DIR/Image" 2>/dev/null || true

cc -fPIC -DABI_VERSION="$ABI" -shared -arch arm64 -o "$OUT_DIR/libkrunfw.5.dylib" "$TMP_DIR/libkrunfw/kernel.c"

echo "✓ libkrunfw pronto em $OUT_DIR"
