#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# build_app.sh
# Builds the standalone Flutter application for GitHub Pages.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
#
# Usage:
#   tool/gh_actions/build_app.sh [base-href]
#
# When base-href is omitted in GitHub Actions, GITHUB_REPOSITORY determines
# the project-site path. Local builds default to /rohd-schematic-viewer/.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
base_href="${1:-}"

if [[ -z "$base_href" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    owner="${GITHUB_REPOSITORY%%/*}"
    repository="${GITHUB_REPOSITORY#*/}"
    if [[ "$repository" == "$owner.github.io" ]]; then
      base_href="/"
    else
      base_href="/$repository/"
    fi
  else
    base_href="/rohd-schematic-viewer/"
  fi
fi

if [[ ! "$base_href" =~ ^/[A-Za-z0-9._/-]*/$ ]]; then
  echo "error: base href must start and end with '/': $base_href" >&2
  exit 64
fi

cd "$repo_root"

bash scripts/verify_flutter_version.sh
make web-release \
  FLUTTER_WEB_BUILD_ARGS="--base-href=$base_href --pwa-strategy=none"

# Flutter's PWA build option is deprecated. Enforce the no-service-worker
# artifact policy explicitly instead.
rm -f build/web/flutter_service_worker.js

bash scripts/devtools_post_build.sh build/web schematics

required_files=(
  build/web/index.html
  build/web/flutter_bootstrap.js
  build/web/main.dart.mjs
  build/web/main.dart.wasm
  build/web/main.dart.js
  build/web/assets/AssetManifest.bin
  build/web/assets/elk_layout_only.js
  build/web/assets/rohd_schematic.json
  build/web/assets/packages/rohd_schematic_viewer/assets/help/schematic_help.md
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "error: expected Pages artifact not found: $required_file" >&2
    exit 1
  fi
done

if [[ -e build/web/flutter_service_worker.js ]]; then
  echo "error: Pages artifact unexpectedly contains a service worker." >&2
  exit 1
fi

if grep -Fq 'serviceWorkerSettings: {' build/web/flutter_bootstrap.js; then
  echo "error: Flutter bootstrap unexpectedly registers a service worker." >&2
  exit 1
fi

if ! grep -Fq "<base href=\"$base_href\">" build/web/index.html; then
  echo "error: generated index.html does not use base href $base_href" >&2
  exit 1
fi

touch build/web/.nojekyll

echo "Standalone app ready in build/web/ (base href: $base_href)."
