#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# verify_flutter_version.sh
# Verifies that Flutter meets the repository's minimum version.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

minimum_version='3.47.0'

if ! command -v flutter >/dev/null 2>&1; then
  echo 'error: flutter must be available on PATH.' >&2
  exit 2
fi

flutter_version="$(flutter --version | sed -n '1s/^Flutter \([^ ]*\).*/\1/p')"
if [[ -z "$flutter_version" ]]; then
  echo 'error: could not determine the Flutter version on PATH.' >&2
  exit 2
fi

if [[ "$(printf '%s\n%s\n' "$minimum_version" "$flutter_version" | sort -V | head -n1)" != "$minimum_version" ]]; then
  echo "error: Flutter $minimum_version or newer is required; found $flutter_version." >&2
  exit 1
fi
