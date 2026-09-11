#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# generate_coverage.sh
# Generates LCOV, HTML, and textual Dart coverage from Flutter tests.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
#
# JavaScript assets are intentionally excluded: elk.bundled.js is an unmodified
# third-party distribution, and the local wrapper has no JavaScript test runner.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COVERAGE_DIR="$ROOT_DIR/coverage"
LCOV_FILE="$COVERAGE_DIR/lcov.info"
HTML_DIR="$COVERAGE_DIR/html"

bash "$ROOT_DIR/scripts/verify_flutter_version.sh"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: required tool not found: %s\n' "$1" >&2
    exit 2
  }
}

require_tool genhtml
require_tool lcov

rm -rf "$HTML_DIR"

if [[ "$(uname -s)" == "Linux" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) flutter_arch="x64" ;;
    aarch64|arm64) flutter_arch="arm64" ;;
    *)
      printf 'error: unsupported Linux architecture for native coverage: %s\n' \
        "$(uname -m)" >&2
      exit 2
      ;;
  esac
  quickjs_lib_dir="$ROOT_DIR/build/linux/$flutter_arch/debug/bundle/lib"
  if [[ ! -f "$quickjs_lib_dir/libquickjs_c_bridge_plugin.so" ]]; then
    make -B -C "$ROOT_DIR" linux-debug
  fi
  [[ -f "$quickjs_lib_dir/libquickjs_c_bridge_plugin.so" ]] || {
    printf 'error: QuickJS plugin was not built: %s\n' "$quickjs_lib_dir" >&2
    exit 1
  }
  export RUN_NATIVE_LAYOUT_COVERAGE=true
  export LD_LIBRARY_PATH="$quickjs_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

printf 'Running Flutter tests with Dart coverage...\n'
make -C "$ROOT_DIR" test ARGS="--coverage ${COVERAGE_TEST_ARGS:-}"

[[ -s "$LCOV_FILE" ]] || {
  printf 'error: coverage output is missing or empty: %s\n' "$LCOV_FILE" >&2
  exit 1
}

genhtml \
  --output-directory "$HTML_DIR" \
  --title 'ROHD Schematic Viewer Dart Coverage' \
  "$LCOV_FILE"

printf '\n'
lcov --summary "$LCOV_FILE"
printf '\nHTML report: %s\n' "$HTML_DIR/index.html"