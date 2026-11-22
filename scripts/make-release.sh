#!/bin/bash
# Publishes build/MyDAW.zip as a GitHub Release of the current commit.
# The sample song projects in SAMPLE_SONGS (build/<name>.zip) are attached too; a missing one is skipped with a warning.
# Before upload, Finder leftovers (__MACOSX/, .DS_Store, ._*) are deleted from those zips in place.
# The tag is v<version>, e.g. v4.0.20261107.1530, from the app's Info.plist. Runs check-public.sh first and stops if it finds anything.
# Needs the GitHub CLI (gh) signed in. Usage: make-release.sh [--draft]
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_DIR"
APP_BUNDLE="build/MyDAW.app"
APP_ZIP="build/MyDAW.zip"
# Sample song projects: "zip base name|song title". Each zip holds <name>/<name>.mydaw and its Recordings folder.
SAMPLE_SONGS=(
    "BalloonAdventure_SHORT|Balloon Adventure"
    "FuwariYurari_SHORT|Fuwari-Yurari"
)

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

# Deletes Finder leftovers (__MACOSX/, .DS_Store, ._*) from a zip in place, only when it has any.
clean_zip() {
    if zipinfo -1 "$1" | grep -qE '^__MACOSX/|(^|/)\.DS_Store$|(^|/)\._'; then
        echo "make-release: removing Finder leftovers from $1"
        zip -q -d "$1" "__MACOSX/*" "*.DS_Store" "*/._*" "._*"
    fi
}

ASSETS=("$APP_ZIP")
SAMPLE_LINES=""
for entry in "${SAMPLE_SONGS[@]}"; do
    name="${entry%%|*}"
    title="${entry#*|}"
    zip="build/$name.zip"
    if [ -f "$zip" ]; then
        clean_zip "$zip"
        ASSETS+=("$zip")
        SAMPLE_LINES="$SAMPLE_LINES
- $name.zip: \"$title\""
    else
        echo "make-release: $zip not found, releasing without it" >&2
    fi
done
if [ -n "$SAMPLE_LINES" ]; then
    NOTES="$NOTES

Sample song projects:$SAMPLE_LINES

Unzip one anywhere and open the .mydaw file inside with File > Open Project… in MyDAW. Keep the Recordings folder next to the .mydaw file."
fi

gh release create "$TAG" "${ASSETS[@]}" --target "$(git rev-parse HEAD)" \
    --title "MyDAW $VERSION" --notes "$NOTES" "$@"
