#!/bin/sh

# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# install_extension_server.sh
# Installs the Schematic Viewer extension on a VS Code remote server.
#
# 2025 January
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$1"
if [ -z "$PKG" ]; then
  echo "Usage: $0 <path-to-zip>" >&2
  exit 2
fi
if [ ! -f "$PKG" ]; then
  echo "Package $PKG not found" >&2
  exit 3
fi

PUBLISHER=$(node -p "require('./package.json').publisher || 'desmond'")
NAME=$(node -p "require('./package.json').name")
VER=$(node -p "require('./package.json').version")

# Use VSCODE_EXTENSIONS_DIR if set, otherwise default to remote server extensions
if [ -n "$VSCODE_EXTENSIONS_DIR" ]; then
  EXT_DIR="$VSCODE_EXTENSIONS_DIR/${PUBLISHER}.${NAME}-${VER}"
else
  EXT_DIR="$HOME/.vscode-server/extensions/${PUBLISHER}.${NAME}-${VER}"
fi

echo "Installing $PKG -> $EXT_DIR"
mkdir -p "$EXT_DIR"

# Detect if file looks like a VSIX (contains 'extension/' or 'extension/package.json')
if unzip -l "$PKG" | grep -q "extension/package.json" 2>/dev/null; then
  echo "Detected VSIX package; extracting package contents"
  TMPDIR=$(mktemp -d /tmp/vsix_pkg_XXXX)
  unzip -o "$PKG" -d "$TMPDIR"
  # Move package contents (usually under 'extension/') into EXT_DIR
  if [ -d "$TMPDIR/extension" ]; then
    rm -rf "$EXT_DIR"/* || true
    cp -a "$TMPDIR/extension/." "$EXT_DIR/"
  else
    echo "VSIX did not contain expected 'extension/' folder; aborting" >&2
    rm -rf "$TMPDIR"
    exit 4
  fi
  rm -rf "$TMPDIR"
else
  echo "Assuming slim package (runtime zip); extracting into extension dir"
  unzip -o "$PKG" -d "$EXT_DIR"
fi

# Register the extension in VS Code's extensions.json registry
# Without this entry VS Code will not discover the extension at all.
EXT_BASE="$(dirname "$EXT_DIR")"
REGISTRY="$EXT_BASE/extensions.json"
EXT_ID="${PUBLISHER}.${NAME}"
REL_LOC="${PUBLISHER}.${NAME}-${VER}"
TIMESTAMP=$(date +%s)000

if [ -f "$REGISTRY" ]; then
  # Check if already registered
  if node -e "
    const fs = require('fs');
    const reg = JSON.parse(fs.readFileSync('$REGISTRY','utf8'));
    const idx = reg.findIndex(e => e.identifier && e.identifier.id === '$EXT_ID');
    if (idx >= 0) {
      // Update existing entry
      reg[idx].version = '$VER';
      reg[idx].location = { \"\\\$mid\": 1, path: '$EXT_DIR', scheme: 'file' };
      reg[idx].relativeLocation = '$REL_LOC';
      reg[idx].metadata = reg[idx].metadata || {};
      reg[idx].metadata.installedTimestamp = $TIMESTAMP;
      reg[idx].metadata.source = 'vsix';
    } else {
      // Add new entry
      reg.push({
        identifier: { id: '$EXT_ID' },
        version: '$VER',
        location: { \"\\\$mid\": 1, path: '$EXT_DIR', scheme: 'file' },
        relativeLocation: '$REL_LOC',
        metadata: { isMachineScoped: true, installedTimestamp: $TIMESTAMP, pinned: true, source: 'vsix' }
      });
    }
    fs.writeFileSync('$REGISTRY', JSON.stringify(reg, null, 2));
    console.log('Registered $EXT_ID in extensions.json');
  "; then
    echo "Extension registered in $REGISTRY"
  else
    echo "Warning: Failed to update extensions.json; extension may not be discovered by VS Code" >&2
  fi
else
  # Create a new registry with just this extension
  node -e "
    const fs = require('fs');
    const reg = [{
      identifier: { id: '$EXT_ID' },
      version: '$VER',
      location: { \"\\\$mid\": 1, path: '$EXT_DIR', scheme: 'file' },
      relativeLocation: '$REL_LOC',
      metadata: { isMachineScoped: true, installedTimestamp: $TIMESTAMP, pinned: true, source: 'vsix' }
    }];
    fs.writeFileSync('$REGISTRY', JSON.stringify(reg, null, 2));
    console.log('Created extensions.json with $EXT_ID');
  "
  echo "Created $REGISTRY"
fi

echo "Installed to $EXT_DIR"
exit 0
