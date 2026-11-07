#!/bin/bash
# Publishes build/MyDAW.zip as a GitHub Release of the current commit.
# The tag is v<version>, e.g. v4.0.20261107.1530, from the app's Info.plist. Runs check-public.sh first and stops if it finds anything.
# Needs the GitHub CLI (gh) signed in. Usage: make-release.sh [--draft]
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_DIR"
APP_BUNDLE="build/MyDAW.app"
APP_ZIP="build/MyDAW.zip"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "make-release: commit your changes first" >&2
    exit 1
fi
scripts/make-zip.sh
scripts/check-public.sh "$APP_ZIP"

PLIST="$APP_BUNDLE/Contents/Info.plist"
# CFBundleShortVersionString holds version and build, e.g. 4.0.20261107.1530.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
TAG="v$VERSION"

NOTES="MyDAW $VERSION for Apple Silicon Macs (macOS 13 or later).

The app is not notarized: after unzipping, allow it in System Settings > Privacy & Security (Open Anyway).
Manuals: OperationManual_en.pdf / OperationManual_jp.pdf in the repository."

gh release create "$TAG" "$APP_ZIP" --target "$(git rev-parse HEAD)" \
    --title "MyDAW $VERSION" --notes "$NOTES" "$@"
