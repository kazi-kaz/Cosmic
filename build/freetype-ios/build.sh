#!/bin/bash
# Build freetype static for iOS arm64 — consumed by build/win32u-unix/build.sh,
# which compiles freetype_ios.c against these headers and merges
# build/libfreetype.a into libwin32u_unix.a (no Xcode project changes).
#
# Source: shallow clone of freetype in research/freetype at FREETYPE_TAG
#   git clone --depth 1 --branch VER-2-15-0 https://github.com/freetype/freetype.git research/freetype
# An existing clone at another tag is moved to FREETYPE_TAG (and the cmake build
# folder is cleared) so a machine with an old checkout really rebuilds.
# Going back: FREETYPE_TAG=VER-2-13-3 (the pin before Nov 19 2026).
# All optional deps disabled — fonts are plain TTFs from wine/fonts/.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC="$REPO_ROOT/research/freetype"
FREETYPE_TAG="${FREETYPE_TAG:-VER-2-15-0}"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
    [ ! -e "$SRC" ] || { echo "ERROR: $SRC exists without CMakeLists.txt; preserve or repair it first" >&2; exit 1; }
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git "$SRC"
fi
have="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || echo unknown)"
if [ "$have" != "$FREETYPE_TAG" ]; then
    [ -z "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] || { echo "ERROR: $SRC has local changes; preserve them before moving it to $FREETYPE_TAG" >&2; exit 1; }
    echo "freetype: $SRC is at $have, moving to $FREETYPE_TAG"
    git -C "$SRC" fetch --depth 1 origin tag "$FREETYPE_TAG"
    git -C "$SRC" checkout -q "$FREETYPE_TAG"
    rm -rf "$BUILD_DIR/build"
fi


cmake -S "$SRC" -B "$BUILD_DIR/build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_HVF=ON \
  -DCMAKE_C_FLAGS="-fno-stack-protector"

cmake --build "$BUILD_DIR/build" -j8
echo "$FREETYPE_TAG" > "$BUILD_DIR/build/libfreetype.version"
echo "Done: $BUILD_DIR/build/libfreetype.a ($FREETYPE_TAG)"
