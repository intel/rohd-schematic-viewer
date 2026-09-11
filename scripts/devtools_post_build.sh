#!/bin/bash

# Copyright (C) 2024-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# devtools_post_build.sh
# Widget-local post-build hook for DevTools installation.
#
# 2024 April
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
#
# Args:
#   1: deployed directory (under extension/devtools)
#   2: route name
#   3: package directory
#   4: build output directory (relative to package directory)

set -euo pipefail

deploy_dir="$1"
route="$2"

if [ "$route" != "schematics" ]; then
  exit 0
fi

# Fix Flutter web asset paths for standalone schematic viewer.
# When building rohd-schematic-viewer as the root package, Flutter places
# bundled assets at assets/assets/... (double-nested) but the web engine
# fetches them at assets/... (single-nested). Package assets also lose
# their packages/<name>/ prefix since the package IS the root.
echo "    [schematics hook] Fixing schematic viewer asset paths..."
cp "$deploy_dir/assets/assets/rohd_schematic.json" \
   "$deploy_dir/assets/rohd_schematic.json"
mkdir -p "$deploy_dir/assets/packages/rohd_schematic_viewer/assets/help"
cp "$deploy_dir/assets/assets/help/schematic_help.md" \
   "$deploy_dir/assets/packages/rohd_schematic_viewer/assets/help/schematic_help.md"
