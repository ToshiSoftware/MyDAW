#!/bin/bash
set -e

# Change to project root directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_DIR"

echo "========================================"
echo " Building MyDAW (Mac / Apple Silicon)   "
echo "========================================"

APP_NAME="MyDAW"
BASE_VERSION="1.2"
BUILD_VERSION="${BASE_VERSION}.$(date +%Y%m%d.%H%M)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$PROJECT_DIR/.build_cache"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
mkdir -p "$PROJECT_DIR/Recordings"

# Discover Toolchain & SDK
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ -f "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SWIFTC_CMD="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
    SWIFTC_CMD=$(which swiftc)
fi

if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SDK_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
fi

echo "Developer Dir: $DEVELOPER_DIR"
echo "SDK Path: $SDK_PATH"
echo "Compiler: $SWIFTC_CMD"

# Build the isolated VST3 bridge. The AU path remains Swift/AVAudioEngine-only.
VST3_BUILD_DIR="$PROJECT_DIR/.build_myDAW_vst3"
echo "Building VST3 bridge..."
cmake -S "$PROJECT_DIR/VST3Host" -B "$VST3_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$VST3_BUILD_DIR" --target MyDAWVST3Bridge -j2
VST3_BRIDGE_LIBRARY_DIR="$VST3_BUILD_DIR"
VST3_SDK_LIBRARY_DIR="$VST3_BUILD_DIR/lib/Release"

# Gather all swift files
SWIFT_FILES=$(find Sources -name "*.swift")

echo "Compiling Swift sources..."
"$SWIFTC_CMD" \
    -module-cache-path "$CACHE_DIR" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    -O \
    -parse-as-library \
    $SWIFT_FILES \
    -L "$VST3_BRIDGE_LIBRARY_DIR" \
    -L "$VST3_SDK_LIBRARY_DIR" \
    -lMyDAWVST3Bridge \
    -lsdk_hosting \
    -lsdk_common \
    -lbase \
    -lpluginterfaces \
    -lc++ \
    -framework CoreFoundation \
    -framework Foundation \
    -o "$MACOS_DIR/$APP_NAME"

echo "Copying Info.plist and app icon..."
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
echo "Build version: $BUILD_VERSION"
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "Installed AppIcon.icns"
else
    echo "Warning: AppIcon.icns not found in project root"
fi

# Code signing with entitlements for audio input
echo "Signing application bundle with entitlements..."
codesign --force --deep --sign - --entitlements "MyDAW.entitlements" "$APP_BUNDLE"

echo "========================================"
echo " Build Succeeded!                       "
echo " App location: $APP_BUNDLE              "
echo " To run: open $APP_BUNDLE               "
echo "========================================"
