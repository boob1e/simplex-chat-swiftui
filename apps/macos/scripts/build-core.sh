#!/bin/bash
# Builds the Haskell core for the SwiftUI app and copies it into apps/macos/Libraries.
# Same as scripts/desktop/build-lib-mac.sh, but with the `swift` flag, which makes the core
# emit the JSON format the Swift types decode (the Compose desktop app uses the default format).
set -e

ARCH="${1:-$(uname -m)}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

LOCAL=cabal.project.local
if [ ! -f "$LOCAL" ]; then
    echo "$LOCAL not found - see docs/CLI.md (cp scripts/cabal.project.local.mac cabal.project.local)"
    exit 1
fi

cp "$LOCAL" "$LOCAL.bak"
trap 'mv "$ROOT/$LOCAL.bak" "$ROOT/$LOCAL"' EXIT
cat >> "$LOCAL" <<'FLAGS'

package simplex-chat
    flags: +swift

package simplexmq
    flags: +swift
FLAGS

# build-lib-mac.sh ends by preparing VLC for the Compose app, which isn't needed here
scripts/desktop/build-lib-mac.sh "$ARCH" || [ -f "apps/multiplatform/common/src/commonMain/cpp/desktop/libs/mac-${ARCH/arm64/aarch64}/libsimplex.dylib" ]
apps/macos/scripts/copy-core.sh "$ARCH"
