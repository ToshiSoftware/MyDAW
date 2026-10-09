#!/bin/bash
# Git pre-commit hook body (the hook in the git dir only calls this).
# On main: refuses a commit whose sources are newer than build/MyDAW.app
# (built from older code), then refreshes build/MyDAW.zip and adds it to the
# commit. Other branches are left alone. Bypass: git commit --no-verify.
set -e

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel)"
cd "$PROJECT_DIR"
APP_EXECUTABLE="build/MyDAW.app/Contents/MacOS/MyDAW"

# Staged files that go into the app.
STALE=""
while IFS= read -r f; do
    case "$f" in
        Sources/*|VST3Host/*|Resources/*|Info.plist|MyDAW.entitlements)
            if [ -f "$f" ] && { [ ! -f "$APP_EXECUTABLE" ] || [ "$f" -nt "$APP_EXECUTABLE" ]; }; then
                STALE="$STALE  $f\n"
            fi
            ;;
    esac
done < <(git diff --cached --name-only --diff-filter=ACMR)

if [ -n "$STALE" ]; then
    echo "pre-commit: build/MyDAW.app is older than these staged files:" >&2
    printf "%b" "$STALE" >&2
    echo "pre-commit: run scripts/build.sh, then commit again (or commit with --no-verify)." >&2
    exit 1
fi

[ -f "$APP_EXECUTABLE" ] || exit 0
scripts/make-zip.sh
git add build/MyDAW.zip
