#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# stage_js_bridge.sh
# Stage Dart-first ELK wrapper to canonical assets location
# Flutter's pubspec.yaml bundles everything in assets/ into builds automatically
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Canonical source
ELK_ONLY_SRC="${ROOT}/js_bridge/elk_layout_only.js"

# Single destination: assets/ (declared in pubspec.yaml)
FLUTTER_ASSETS_DEST="${ROOT}/assets"

mkdir -p "$FLUTTER_ASSETS_DEST"

echo "Staging Dart-first ELK wrapper..."
cp -v "$ELK_ONLY_SRC" "$FLUTTER_ASSETS_DEST/"

echo "JS files staged. Flutter will automatically bundle into:"
echo "  - build/web/assets/ (for web builds)"
echo "  - build/linux/assets/ (for Linux builds)"
