#!/bin/bash
# Builds the MP3 encoder (LAME, LGPL) as libmp3lame.0.dylib and, given a
# destination app bundle, installs it in Contents/Frameworks with its license
# in Contents/Resources. Used by build.sh and the Xcode target.
# The library ships separately (loaded at run time), so it stays replaceable.
# The source is downloaded once and checked against its SHA-256. Everything
# lives in ~/Library/Caches/MyDAW (outside the project), so the project's own
# location does not matter. `make install` is not used: libtool cannot install
# into a path with spaces, and only the dylib is needed.
set -e

LAME_VERSION="3.100"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
LAME_CACHE_DIR="$HOME/Library/Caches/MyDAW"
LAME_TARBALL="$LAME_CACHE_DIR/lame-$LAME_VERSION.tar.gz"
LAME_SRC_DIR="$LAME_CACHE_DIR/lame-$LAME_VERSION-src"
LAME_LIB_DIR="$LAME_CACHE_DIR/lame-$LAME_VERSION-lib"
LAME_DYLIB="$LAME_LIB_DIR/libmp3lame.0.dylib"

if [ ! -f "$LAME_DYLIB" ]; then
    echo "Building LAME $LAME_VERSION..."
    mkdir -p "$LAME_CACHE_DIR"
    if [ ! -f "$LAME_TARBALL" ]; then
        curl -fL -o "$LAME_TARBALL" "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
    fi
    echo "$LAME_SHA256  $LAME_TARBALL" | shasum -a 256 -c -
    rm -rf "$LAME_SRC_DIR" "$LAME_LIB_DIR"
    mkdir -p "$LAME_SRC_DIR"
    tar xzf "$LAME_TARBALL" -C "$LAME_SRC_DIR" --strip-components 1
    # 3.100 exports a symbol it no longer defines; the macOS linker rejects it.
    sed -i '' '/^lame_init_old$/d' "$LAME_SRC_DIR/include/libmp3lame.sym"
    (
        cd "$LAME_SRC_DIR"
        export MACOSX_DEPLOYMENT_TARGET=13.0
        export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=13.0"
        export LDFLAGS="-arch arm64 -mmacosx-version-min=13.0"
        ./configure --enable-shared --disable-static \
            --disable-frontend --disable-dependency-tracking > "$LAME_CACHE_DIR/lame-configure.log"
        make -j4 > "$LAME_CACHE_DIR/lame-make.log"
    )
    mkdir -p "$LAME_LIB_DIR"
    cp "$LAME_SRC_DIR/libmp3lame/.libs/libmp3lame.0.dylib" "$LAME_DYLIB"
fi

APP_BUNDLE="$1"
if [ -n "$APP_BUNDLE" ]; then
    FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR" "$APP_BUNDLE/Contents/Resources"
    rm -f "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    cp "$LAME_DYLIB" "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    chmod u+w "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    install_name_tool -id "@rpath/libmp3lame.0.dylib" "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    xattr -c "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    codesign --force --sign - "$FRAMEWORKS_DIR/libmp3lame.0.dylib"
    tar xzf "$LAME_TARBALL" -O "lame-$LAME_VERSION/COPYING" > "$APP_BUNDLE/Contents/Resources/LAME-COPYING.txt"
fi
