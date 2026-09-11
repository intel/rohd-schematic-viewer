#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# verify_elk_distribution.sh
# Verifies that ELK and its required notices are installed in every delivery
# artifact: Linux Flutter bundle, standalone web output, and VS Code package.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_ELK_SHA256='cd56bf0ddb7ad2587583461d523fdd974dc56b59efd20cdfee954e1112ff1a49'
ELK_ASSET="$ROOT/assets/js/elk.bundled.js"
LICENSE_ASSET="$ROOT/assets/licenses/elkjs_LICENSES.txt"
JS_LICENSE_ASSET="$ROOT/assets/js/LICENSE"
JS_README_ASSET="$ROOT/assets/js/README.md"
NOTICE="$ROOT/THIRD_PARTY_NOTICES.md"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Missing $2: ${1#$ROOT/}"
}

verify_elk_file() {
  local artifact="$1"
  require_file "$artifact" 'ELK asset'

  local actual_sha256
  actual_sha256="$(sha256sum "$artifact" | awk '{print $1}')"
  [[ "$actual_sha256" == "$EXPECTED_ELK_SHA256" ]] ||
      fail "ELK hash mismatch in ${artifact#$ROOT/}: $actual_sha256"
}

verify_license_file() {
  local artifact="$1"
  require_file "$artifact" 'ELK license notice'
  cmp -s "$LICENSE_ASSET" "$artifact" ||
      fail "ELK license notice differs in ${artifact#$ROOT/}"
}

archive_entries=''

# Cache the archive's file listing once so repeated entry checks avoid piping
# `unzip -Z1` into a `grep -q` that exits early: under `set -o pipefail` that
# combination intermittently reports failure via SIGPIPE even when the entry
# is present.
load_archive_entries() {
  archive_entries="$(unzip -Z1 "$1")"
}

verify_archive_entry() {
  local entry="$1"
  grep -Fxq "$entry" <<<"$archive_entries" ||
      fail "Embedded package is missing $entry"
}

# Every directory that carries a copy of elk.bundled.js must also carry a
# colocated LICENSE file and a README.md pointing users at where to download
# a copy, so the asset is self-documenting wherever it is installed.
verify_js_license_readme() {
  local js_dir="$1"
  require_file "$js_dir/LICENSE" 'colocated ELK LICENSE file'
  require_file "$js_dir/README.md" 'colocated ELK README.md'
  cmp -s "$JS_LICENSE_ASSET" "$js_dir/LICENSE" ||
      fail "ELK LICENSE file differs in ${js_dir#$ROOT/}/LICENSE"
  cmp -s "$JS_README_ASSET" "$js_dir/README.md" ||
      fail "ELK README.md differs in ${js_dir#$ROOT/}/README.md"
}

require_file "$ELK_ASSET" 'canonical ELK asset'
require_file "$LICENSE_ASSET" 'canonical ELK license notice'
require_file "$NOTICE" 'third-party notice'
verify_elk_file "$ELK_ASSET"
verify_js_license_readme "$ROOT/assets/js"
grep -Fq 'elkjs 0.8.2' "$LICENSE_ASSET" ||
    fail 'Canonical ELK license notice does not identify elkjs 0.8.2'
grep -Fq "$EXPECTED_ELK_SHA256" "$NOTICE" ||
    fail 'Third-party notice does not contain the ELK SHA-256'

printf 'Verified canonical ELK asset and source notice.\n'

linux_assets=("$ROOT"/build/linux/*/*/bundle/data/flutter_assets/assets)
[[ -d "${linux_assets[0]}" ]] ||
    fail 'No Linux Flutter bundle found; run make linux first'
for asset_root in "${linux_assets[@]}"; do
  verify_elk_file "$asset_root/js/elk.bundled.js"
  verify_license_file "$asset_root/licenses/elkjs_LICENSES.txt"
  verify_js_license_readme "$asset_root/js"
done
printf 'Verified Linux Flutter bundle (%d artifact(s)).\n' "${#linux_assets[@]}"

web_assets="$ROOT/build/web/assets/assets"
[[ -d "$web_assets" ]] ||
    fail 'No standalone web build found; run make web first'
verify_elk_file "$web_assets/js/elk.bundled.js"
verify_license_file "$web_assets/licenses/elkjs_LICENSES.txt"
verify_js_license_readme "$web_assets/js"

# `flutter run -d web-server` produces the Flutter asset bundle but does not
# execute Make's release-only copy commands. When present, verify the public
# release copies too.
if [[ -e "$ROOT/build/web/THIRD_PARTY_NOTICES.md" ||
      -e "$ROOT/build/web/licenses/elkjs_LICENSES.txt" ]]; then
  require_file "$ROOT/build/web/THIRD_PARTY_NOTICES.md" 'public web notice'
  verify_license_file "$ROOT/build/web/licenses/elkjs_LICENSES.txt"
  cmp -s "$NOTICE" "$ROOT/build/web/THIRD_PARTY_NOTICES.md" ||
      fail 'Public web third-party notice differs from source notice'
  # `assets/js/` here is the raw script-tag copy staged for index.html.
  verify_js_license_readme "$ROOT/build/web/assets/js"
fi
printf 'Verified standalone web output.\n'

shopt -s nullglob
archives=("$ROOT"/build/*-slim.zip)
[[ "${#archives[@]}" -eq 1 ]] ||
    fail 'Expected exactly one embedded extension ZIP; run make extension first'
archive="${archives[0]}"
load_archive_entries "$archive"
verify_archive_entry 'THIRD_PARTY_NOTICES.md'
verify_archive_entry 'assets/js/elk.bundled.js'
verify_archive_entry 'assets/js/LICENSE'
verify_archive_entry 'assets/js/README.md'
verify_archive_entry 'assets/licenses/elkjs_LICENSES.txt'
verify_archive_entry 'flutter_web/assets/assets/js/elk.bundled.js'
verify_archive_entry 'flutter_web/assets/assets/js/LICENSE'
verify_archive_entry 'flutter_web/assets/assets/js/README.md'
verify_archive_entry 'flutter_web/assets/assets/licenses/elkjs_LICENSES.txt'

archive_elk_sha256="$(unzip -p "$archive" 'assets/js/elk.bundled.js' | sha256sum | awk '{print $1}')"
[[ "$archive_elk_sha256" == "$EXPECTED_ELK_SHA256" ]] ||
    fail "ELK hash mismatch in embedded package: $archive_elk_sha256"
cmp -s "$LICENSE_ASSET" <(unzip -p "$archive" 'assets/licenses/elkjs_LICENSES.txt') ||
    fail 'ELK license notice differs in embedded package'
cmp -s "$JS_LICENSE_ASSET" <(unzip -p "$archive" 'assets/js/LICENSE') ||
    fail 'ELK js/LICENSE differs in embedded package'
cmp -s "$JS_README_ASSET" <(unzip -p "$archive" 'assets/js/README.md') ||
    fail 'ELK js/README.md differs in embedded package'
printf 'Verified embedded extension package: %s\n' "${archive#$ROOT/}"

printf 'ELK distribution verification passed.\n'