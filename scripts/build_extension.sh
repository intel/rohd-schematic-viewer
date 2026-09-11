#!/bin/sh

# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# build_extension.sh
# Builds the VS Code Schematic Viewer extension.
#
# 2025 January
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "Building extension in $ROOT"

# Ensure ELK assets are staged
echo "Staging ELK assets"
bash "$ROOT/scripts/stage_js_bridge.sh"

# Extension staging directory
PKG_NAME=$(node -p "require('$ROOT/package.json').name")
PKG_VERSION=$(node -p "require('$ROOT/package.json').version")
EXT_STAGE="$ROOT/build/extension/${PKG_NAME}-${PKG_VERSION}"
OUT="$ROOT/build/${PKG_NAME}-${PKG_VERSION}-slim.zip"

echo "Staging extension files in $EXT_STAGE"
rm -rf "$EXT_STAGE"
mkdir -p "$EXT_STAGE"

# Copy main files
cp "$ROOT/package.json" "$EXT_STAGE/"
cp "$ROOT/extension.js" "$EXT_STAGE/"
cp "$ROOT/README.md" "$EXT_STAGE/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$EXT_STAGE/"

# Copy shared helpers beside extension.js.
mkdir -p "$EXT_STAGE/shared"
node "$ROOT/scripts/copy_devtools_extension_assets.cjs" "$EXT_STAGE/shared"

# Copy icon if present
if [ -f "$ROOT/icon.png" ]; then
	cp "$ROOT/icon.png" "$EXT_STAGE/"
fi

# Copy any root-level screenshot PNGs (for README images)
for png in "$ROOT"/*.png; do
	[ -f "$png" ] && cp "$png" "$EXT_STAGE/"
done

# Copy images directory if present (for README screenshots)
if [ -d "$ROOT/images" ]; then
	cp -a "$ROOT/images" "$EXT_STAGE/"
fi

# Copy assets if present
if [ -d "$ROOT/assets" ]; then
	cp -a "$ROOT/assets" "$EXT_STAGE/"
fi
if [ -d "$ROOT/build_assets" ]; then
	cp -a "$ROOT/build_assets" "$EXT_STAGE/"
fi
if [ -d "$ROOT/media" ]; then
	cp -a "$ROOT/media" "$EXT_STAGE/"
fi
if [ -d "$ROOT/scripts" ]; then
	cp -a "$ROOT/scripts" "$EXT_STAGE/scripts"
fi

# Include Flutter web build (required for rendering)
FLUTTER_WEB="$ROOT/build/web"
if [ -d "$FLUTTER_WEB" ]; then
		echo "Including Flutter web build in extension package"
		cp -a "$FLUTTER_WEB" "$EXT_STAGE/flutter_web"
else
		echo "Warning: Flutter web build not found at $FLUTTER_WEB"
		echo "Run 'make web' first to build the Flutter web app"
fi

echo "Creating slim package $OUT"
cd "$EXT_STAGE"
zip -r "$OUT" .
echo "Packaged slim extension to $OUT"
echo "Done"
exit 0
