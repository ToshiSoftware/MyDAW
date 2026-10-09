#!/bin/bash
# Zips build/MyDAW.app into build/MyDAW.zip, the copy committed for GitHub
# (the .app itself is not committed). Runs from the git pre-commit hook on
# main (scripts/pre-commit.sh); can also be run by hand.
# Skips the zip when it is already newer than the app; --force always zips.
# ditto keeps the signature and permissions and adds no __MACOSX folder.
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
APP_BUNDLE="$PROJECT_DIR/build/MyDAW.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/MyDAW"
APP_ZIP="$PROJECT_DIR/build/MyDAW.zip"

if [ ! -f "$APP_EXECUTABLE" ]; then
    echo "make-zip: $APP_BUNDLE not found; run scripts/build.sh first" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "?")

if [ "$1" != "--force" ] && [ -f "$APP_ZIP" ] && [ "$APP_ZIP" -nt "$APP_EXECUTABLE" ]; then
    echo "make-zip: MyDAW.zip is up to date ($VERSION)"
    exit 0
fi

rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
echo "make-zip: zipped MyDAW $VERSION"
