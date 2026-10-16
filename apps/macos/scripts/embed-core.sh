#!/bin/bash
# Xcode build phase: embeds the Haskell core dylibs into SimpleX.app/Contents/Frameworks and signs them.
set -e

LIBS="${PROJECT_DIR}/Libraries"
DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$DEST"

if ! ls "$LIBS"/*.dylib >/dev/null 2>&1; then
    echo "error: no Haskell core in $LIBS - build it with scripts/desktop/build-lib-mac.sh, then run apps/macos/scripts/copy-core.sh"
    exit 1
fi

for lib in "$LIBS"/*.dylib; do
    name=$(basename "$lib")
    if [ ! -f "$DEST/$name" ] || [ "$lib" -nt "$DEST/$name" ]; then
        cp -f "$lib" "$DEST/$name"
        chmod 755 "$DEST/$name"
    fi
done

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
find "$DEST" -maxdepth 1 -name "*.dylib" -print0 | \
    xargs -0 -n 16 codesign --force --timestamp=none --options runtime --sign "$IDENTITY"
