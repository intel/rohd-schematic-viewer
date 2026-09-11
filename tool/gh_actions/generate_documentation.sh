#!/usr/bin/env bash

# Copyright (C) 2022-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# generate_documentation.sh
# GitHub Actions step: Generate project documentation.
#
# 2022 October 10
# Author: Chykon

set -euo pipefail

output=$(dart doc 2>&1 | tee)

if echo "$output" | grep --silent -e 'no issues found' -e 'Success!'; then
  echo 'Documentation check passed!'
else
  echo "$output"
  echo 'Documentation failed since some issues were found'
  exit 1
fi
