#!/bin/bash
set -e

# Copies MyPlugIn's sources (shared core, every effect, the catalog) into
# Sources/BuiltIn/MyPlugIn, where build.sh compiles them into MyDAW. Effects
# added to MyPlugIn come along without changes here: MyDAW registers
# whatever MyPlugInCatalog lists (BuiltInPlugins.swift).
# Edit the sources in MyPlugIn (next to MyDAW), then run this script.
# MYPLUGIN_DIR overrides that location (../MyPlugIn).

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
MYPLUGIN_DIR="${MYPLUGIN_DIR:-$PROJECT_DIR/../MyPlugIn}"
SOURCE_DIR="$MYPLUGIN_DIR/Sources"
DEST_DIR="$PROJECT_DIR/Sources/BuiltIn/MyPlugIn"

if [ ! -d "$SOURCE_DIR/MyPlugInCatalog" ]; then
    echo "MyPlugIn sources not found: $SOURCE_DIR" >&2
    exit 1
fi

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
# Swift files only, keeping the folder layout.
rsync -a --include='*/' --include='*.swift' --exclude='*' "$SOURCE_DIR/" "$DEST_DIR/"
for folder in "$DEST_DIR"/*/; do
    echo "$(basename "$folder"): $(find "$folder" -name '*.swift' | wc -l | tr -d ' ') files"
done
