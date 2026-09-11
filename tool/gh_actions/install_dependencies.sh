#!/usr/bin/env bash

# Copyright (C) 2023-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# install_dependencies.sh
# GitHub Actions step: Install project dependencies.
#
# 2023 August 01
# Author: Yao Jing Quek <yao.jing.quek@intel.com>

set -euo pipefail

cd "$(dirname "$0")/../.."

bash scripts/verify_flutter_version.sh

flutter_bin="${FLUTTER:-flutter}"
dependency_mode="${ROHD_SCHEMATIC_DEPENDENCY_MODE:-}"

if [[ -n "$dependency_mode" ]]; then
  bash scripts/schematic_dev_mode.sh "$dependency_mode"
elif [[ -n "${ROHD_LOCAL_PATH:-}" ]]; then
  bash scripts/schematic_dev_mode.sh local-all
fi

"$flutter_bin" pub get
