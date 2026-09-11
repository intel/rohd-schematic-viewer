#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# schematic_run.sh
# Runs the Schematic Viewer with selected dependency and runtime modes.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/verify_flutter_version.sh

mode="${1:-}"
mode="${mode%% *}"
run_mode="${2:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/schematic_run.sh <dependency-mode> <run-mode>

Dependency modes:
  manifest         Use pubspec.yaml dependency sources.
  local-rohd       Local ROHD + hierarchy; Git DevTools-extension packages.
  local-extension  Pub.dev ROHD; local hierarchy + DevTools-extension packages.
  local-all        Local ROHD, hierarchy, and DevTools-extension packages.
Run modes: web-debug, web-release, linux-debug, linux-release
USAGE
}

if [[ -z "$mode" || -z "$run_mode" ]]; then
  usage >&2
  exit 2
fi

case "$mode" in
  -h|--help|help) usage; exit 0 ;;
esac

case "$run_mode" in
  -h|--help|help) usage; exit 0 ;;
esac

bash scripts/schematic_dev_mode.sh "$mode"
flutter pub get

case "$run_mode" in
  web-debug)
    make stage-js
    flutter run -d web-server --web-port=9199 --web-hostname=localhost
    ;;
  web-release)
    make stage-js
    flutter run --release --wasm -d web-server --web-port=9199 --web-hostname=localhost
    ;;
  linux-debug)
    make linux-run-debug
    ;;
  linux-release)
    make linux-run-release
    ;;
  *) usage >&2; exit 2 ;;
esac
