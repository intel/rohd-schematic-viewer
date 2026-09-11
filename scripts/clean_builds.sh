#!/bin/sh

# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# clean_builds.sh
# Removes local Schematic Viewer build and extension artifacts.
#
# 2025 January
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
EXT_DIR="$HOME/.vscode-server/extensions/desmond.vscode-schematic-viewer-0.0.1"

echo "Cleaning build directory: $BUILD_DIR"
if [ -d "$BUILD_DIR" ]; then
  rm -rf "$BUILD_DIR"/*
fi

echo "Cleaning packaged extension install dir: $EXT_DIR"
if [ -d "$EXT_DIR" ]; then
  rm -rf "$EXT_DIR"/*
fi

echo "Cleanup complete"
exit 0
