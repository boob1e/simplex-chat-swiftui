#!/bin/bash
# Copies the Haskell core built by scripts/desktop/build-lib-mac.sh into apps/macos/Libraries.
# Run from anywhere after building the core: apps/macos/scripts/copy-core.sh [arm64|x86_64]
set -e

ARCH="${1:-$(uname -m)}"
[ "$ARCH" == "arm64" ] && ARCH=aarch64

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/apps/multiplatform/common/src/commonMain/cpp/desktop/libs/mac-$ARCH"
DST="$ROOT/apps/macos/Libraries"

if [ ! -f "$SRC/libsimplex.dylib" ]; then
    echo "libsimplex.dylib not found in $SRC - run scripts/desktop/build-lib-mac.sh first"
    exit 1
fi

find "$DST" -name "*.dylib" -delete
cp "$SRC"/*.dylib "$DST"/
echo "Copied $(ls "$DST"/*.dylib | wc -l | tr -d ' ') libraries to $DST"
