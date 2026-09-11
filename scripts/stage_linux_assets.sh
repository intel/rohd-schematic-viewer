#!/bin/bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# stage_linux_assets.sh
# Stage assets for Flutter Linux builds
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
#
# For Linux, Flutter automatically bundles everything in assets/ (declared in pubspec.yaml)
# into the build output at: build/linux/*/bundle/data/flutter_assets/assets/
#
# This script validates that required assets exist and are properly staged.
# The actual asset bundling is handled by Flutter's build system.
#
# Required assets for Linux:
#   assets/js/                          - ELK engine JS files
#   assets/rohd_schematic.json          - Test schematic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE_ASSETS="$PROJECT_ROOT/assets"

echo "=== Validating Linux Assets ==="

# Check required directories/files exist
errors=0

if [ ! -d "$SOURCE_ASSETS/js" ]; then
    echo "ERROR: assets/js/ not found"
    errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
    echo "Linux asset validation failed with $errors error(s)"
    exit 1
fi

echo "Linux assets validated successfully"
echo "  - assets/js/ ✓"
echo ""
echo "Flutter will bundle these into build/linux/*/bundle/data/flutter_assets/"
