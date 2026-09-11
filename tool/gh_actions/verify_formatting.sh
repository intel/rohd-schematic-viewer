#!/usr/bin/env bash

# Copyright (C) 2022-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# verify_formatting.sh
# GitHub Actions step: Verify project formatting.
#
# 2022 October 9
# Author: Chykon

set -euo pipefail

if dart format --output=none --set-exit-if-changed .; then
  echo 'Format check passed!'
else
  exit_code=$?
  echo 'Format check failed: please format your code (use "dart format .")!'
  exit "$exit_code"
fi
