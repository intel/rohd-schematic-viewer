#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# run_coverity.sh
# Runs Coverity analysis using the repository scan configuration.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${COVERITY_SCAN_CONFIG:-$ROOT_DIR/coverity/scan.conf}"

usage() {
  cat <<'USAGE'
Usage: scripts/run_coverity.sh [stage]

Stages:
  all       Configure, capture, analyze, report, source, and run Dart analysis
  setup     Generate Coverity compiler/source configuration
  capture   Capture the configured Linux build with cov-build
  analyze   Run cov-analyze on the captured intermediate directory
  report    Generate JSON and HTML reports from captured findings
  source    Analyze configured Dart/TypeScript source files
  dart      Run the configured Flutter/Dart analyzer command
  clean     Remove Coverity output under build/coverity

Environment:
  COVERITY_SCAN_CONFIG=/path/to/scan.conf
  COVERITY_HOME=/opt/cov-analysis-linux64-2025.3.0
  COVERITY_LINUX_BUILD_COMMAND='make clean-linux linux-debug'
  COVERITY_FLUTTER_ANALYZE_COMMAND='flutter analyze'
USAGE
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "error: Coverity scan config not found: $CONFIG_FILE" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

COVERITY_BIN="$COVERITY_HOME/bin"
IDIR="$ROOT_DIR/$COVERITY_IDIR"
REPORT_DIR="$ROOT_DIR/$COVERITY_REPORT_DIR"
CONFIG_XML="$ROOT_DIR/$COVERITY_CONFIG_XML"

require_tool() {
  local tool_name="$1"
  if [[ ! -x "$COVERITY_BIN/$tool_name" ]]; then
    echo "error: missing executable: $COVERITY_BIN/$tool_name" >&2
    exit 2
  fi
}

run_step() {
  local label="$1"
  shift
  printf '\n[coverity] %s\n' "$label"
  "$@"
}

setup_coverity_config() {
  require_tool cov-configure
  mkdir -p "$(dirname "$CONFIG_XML")"
  rm -f "$CONFIG_XML"

  for language in "${COVERITY_CONFIGURE_LANGUAGES[@]}"; do
    case "$language" in
      gcc) "$COVERITY_BIN/cov-configure" --config "$CONFIG_XML" --gcc ;;
      clang) "$COVERITY_BIN/cov-configure" --config "$CONFIG_XML" --clang ;;
      dart) "$COVERITY_BIN/cov-configure" --config "$CONFIG_XML" --dart ;;
      javascript) "$COVERITY_BIN/cov-configure" --config "$CONFIG_XML" --javascript ;;
      *) echo "error: unsupported Coverity language: $language" >&2; exit 2 ;;
    esac
  done
}

capture_linux_build() {
  require_tool cov-build
  rm -rf "$IDIR"
  mkdir -p "$(dirname "$IDIR")"

  local build_spec build_dir build_command build_cwd
  for build_spec in "${COVERITY_CAPTURE_COMMANDS[@]}"; do
    build_dir="${build_spec%%::*}"
    build_command="${build_spec#*::}"
    if [[ "$build_dir" = /* ]]; then
      build_cwd="$build_dir"
    else
      build_cwd="$ROOT_DIR/$build_dir"
    fi
    if [[ ! -d "$build_cwd" ]]; then
      echo "error: Coverity build directory does not exist: $build_cwd" >&2
      exit 2
    fi

    echo "[coverity] capturing in $build_cwd: $build_command"
    cd "$build_cwd"
    "$COVERITY_BIN/cov-build" \
      --dir "$IDIR" \
      --config "$CONFIG_XML" \
      bash -lc "$build_command"
  done
}

analyze_capture() {
  require_tool cov-analyze
  "$COVERITY_BIN/cov-analyze" --dir "$IDIR" "${COVERITY_ANALYZE_ARGS[@]}"
}

write_report() {
  require_tool cov-format-errors
  mkdir -p "$REPORT_DIR"
  "$COVERITY_BIN/cov-format-errors" \
    --dir "$IDIR" \
    --json-output-v10 "$REPORT_DIR/coverity-results.json" \
    --title "ROHD Schematic Viewer Coverity"
  "$COVERITY_BIN/cov-format-errors" \
    --dir "$IDIR" \
    --html-output "$REPORT_DIR/html" \
    --title "ROHD Schematic Viewer Coverity"
}

write_source_response_file() {
  local response_file="$REPORT_DIR/source-files.txt"
  mkdir -p "$REPORT_DIR"
  : > "$response_file"

  local source_dir source_path
  for source_dir in "${COVERITY_DESKTOP_SOURCE_DIRS[@]}"; do
    if [[ "$source_dir" = /* ]]; then
      source_path="$source_dir"
    else
      source_path="$ROOT_DIR/$source_dir"
    fi
    if [[ -f "$source_path" ]]; then
      case "$source_path" in
        *.dart|*.js|*.jsx|*.ts|*.tsx) printf '%s\n' "$source_path" ;;
      esac
    elif [[ -d "$source_path" ]]; then
      find "$source_path" -type f \
        \( -name '*.dart' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \) \
        -not -path '*/build/*' \
        -not -path '*/.dart_tool/*' \
        -not -path '*/node_modules/*'
    fi
  done | sort -u > "$response_file"

  printf '%s\n' "$response_file"
}

analyze_source_files() {
  require_tool cov-run-desktop
  local response_file
  response_file="$(write_source_response_file)"
  if [[ ! -s "$response_file" ]]; then
    echo "[coverity] no Dart/JavaScript source files matched"
    return 0
  fi

  "$COVERITY_BIN/cov-run-desktop" \
    --dir "$IDIR" \
    --config "$CONFIG_XML" \
    --code-base-dir "$ROOT_DIR" \
    --disconnected \
    --json-output-v10 "$REPORT_DIR/source-results.json" \
    --text-output "$REPORT_DIR/source-results.txt" \
    "${COVERITY_SOURCE_ANALYZE_ARGS[@]}" \
    "@@$response_file"
}

run_dart_analyzer() {
  local analyze_spec analyze_dir analyze_command analyze_cwd
  for analyze_spec in "${COVERITY_DART_ANALYZE_COMMANDS[@]}"; do
    analyze_dir="${analyze_spec%%::*}"
    analyze_command="${analyze_spec#*::}"
    if [[ "$analyze_dir" = /* ]]; then
      analyze_cwd="$analyze_dir"
    else
      analyze_cwd="$ROOT_DIR/$analyze_dir"
    fi
    echo "[coverity] dart analyze in $analyze_cwd: $analyze_command"
    cd "$analyze_cwd"
    bash -lc "$analyze_command"
  done
}

clean_coverity_output() {
  rm -rf "$ROOT_DIR/build/coverity"
}

stage="${1:-all}"
case "$stage" in
  all)
    run_step setup setup_coverity_config
    run_step capture capture_linux_build
    run_step analyze analyze_capture
    run_step report write_report
    run_step source analyze_source_files
    run_step dart run_dart_analyzer
    ;;
  setup) run_step setup setup_coverity_config ;;
  capture) run_step capture capture_linux_build ;;
  analyze) run_step analyze analyze_capture ;;
  report) run_step report write_report ;;
  source) run_step source analyze_source_files ;;
  dart) run_step dart run_dart_analyzer ;;
  clean) run_step clean clean_coverity_output ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
