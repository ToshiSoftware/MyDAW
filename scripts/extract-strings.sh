#!/bin/bash
# Lists the GUI strings in Sources/ that the compiler marks for localization
# (SwiftUI literals and String(localized:)) and reports keys missing from, or
# no longer used by, Resources/ja.lproj/Localizable.strings.
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Compile a copy outside Google Drive (same reason as build.sh).
mkdir -p "$WORK_DIR/src" "$WORK_DIR/out"
cp -R "$PROJECT_DIR/Sources/"* "$WORK_DIR/src/"
swiftc -c -wmo -module-name MyDAW -parse-as-library \
    -target arm64-apple-macosx13.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -module-cache-path "$WORK_DIR/cache" \
    $(find "$WORK_DIR/src" -name '*.swift') \
    -emit-localized-strings -emit-localized-strings-path "$WORK_DIR/out" \
    -o "$WORK_DIR/out/MyDAW.o" 2>&1 | grep -E 'error' || true

python3 - "$WORK_DIR/out" "$PROJECT_DIR/Resources/ja.lproj/Localizable.strings" <<'EOF'
import glob, json, subprocess, sys
out_dir, ja_path = sys.argv[1], sys.argv[2]
keys = set()
for path in glob.glob(f"{out_dir}/*.stringsdata"):
    for entries in json.load(open(path))["tables"].values():
        keys.update(entry["key"] for entry in entries)
keys.discard("")
ja = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", ja_path],
                               capture_output=True, check=True).stdout)
missing = sorted(keys - ja.keys())
unused = sorted(ja.keys() - keys)
print(f"{len(keys)} keys in source, {len(ja)} in ja.lproj")
for key in missing:
    print(f"MISSING: {key!r}")
for key in unused:
    print(f"UNUSED:  {key!r}")
sys.exit(1 if missing else 0)
EOF
