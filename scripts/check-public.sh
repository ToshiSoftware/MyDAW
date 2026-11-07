#!/bin/bash
# Checks what goes public (MyDAW.zip and the manual PDFs) for private
# names and other vendors' product names (word list: see WORDS_FILE).
# Exit status 1 if anything is found. copy-to-note.sh runs this first.
# Usage: check-public.sh [zip] (default build/MyDAW.zip)
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
ZIP="${1:-$PROJECT_DIR/build/MyDAW.zip}"
# The word list is private (it names what must stay hidden), so it lives in
# MyInstrument next to MyDAW. CHECK_PUBLIC_WORDS overrides its location.
WORDS_FILE="${CHECK_PUBLIC_WORDS:-$PROJECT_DIR/../MyInstrument/Private/check-public-words.txt}"
if [ ! -f "$WORDS_FILE" ]; then
    echo "check-public: word list not found: $WORDS_FILE" >&2
    exit 1
fi
WORDS="$(grep -v -E '^[[:space:]]*(#|$)' "$WORDS_FILE" | paste -sd '|' -)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

report() {
    echo "check-public: $1:" >&2
    echo "$2" | cut -c1-160 | head -10 >&2
    status=1
}

if [ ! -f "$ZIP" ]; then
    report "missing" "$ZIP"
else
    ditto -x -k "$ZIP" "$WORK/zip"
    APP="$(find "$WORK/zip" -maxdepth 2 -name 'MyDAW.app' | head -1)"
    if [ -z "$APP" ]; then
        report "no app in zip" "$ZIP"
    else
        while IFS= read -r file; do
            # Words of at least 4 characters, so that machine code that only
            # happens to contain a short word does not count.
            found="$(LC_ALL=C strings -a -n 4 "$file" | LC_ALL=C grep -E "$WORDS")"
            [ -n "$found" ] && report "$(basename "$file")" "$found"
        done < <(find "$APP" -type f ! -name '._*')
    fi
fi

for pdf in OperationManual_jp.pdf OperationManual_en.pdf; do
    path="$PROJECT_DIR/$pdf"
    if [ ! -f "$path" ]; then
        report "missing" "$pdf"
        continue
    fi
    found="$(xcrun swift "$SCRIPT_DIR/pdf-text.swift" "$path" | grep -E "$WORDS|dimension")"
    [ -n "$found" ] && report "$pdf" "$found"
    # A PDF older than its source does not show the current text.
    source="$PROJECT_DIR/docs/manual/$(basename "$pdf" .pdf).html"
    [ "$source" -nt "$path" ] && report "$pdf is older than its source" "$source"
done

[ "$status" -eq 0 ] && echo "check-public: OK"
exit "$status"
