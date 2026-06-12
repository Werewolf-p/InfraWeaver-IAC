#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_DIR/apps/infraweaver-init"
TARGET_DIR="$SCRIPT_DIR/out"

cd "$APP_DIR"
npm run build

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp -R out/. "$TARGET_DIR/"

echo "Built init UI into $TARGET_DIR"
