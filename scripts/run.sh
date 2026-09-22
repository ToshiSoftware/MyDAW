#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Build first
"$SCRIPT_DIR/build.sh"

APP_BUNDLE="$PROJECT_DIR/build/MyDAW.app"
echo "Launching $APP_BUNDLE ..."
open "$APP_BUNDLE"

