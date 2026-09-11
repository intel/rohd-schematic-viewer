#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <flutter-command> [arguments...]" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
toolchain_dir="$root/.dart_tool/flutter_linux_toolchain"

if command -v clang >/dev/null 2>&1 &&
    command -v clang++ >/dev/null 2>&1; then
  cc=$(command -v clang)
  cxx=$(command -v clang++)
  using_gcc=false
elif command -v gcc >/dev/null 2>&1 &&
    command -v g++ >/dev/null 2>&1; then
  cc=$(command -v gcc)
  cxx=$(command -v g++)
  using_gcc=true
else
  echo "Linux builds require clang/clang++ or gcc/g++." >&2
  exit 1
fi

mkdir -p "$toolchain_dir"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$cc" >"$toolchain_dir/clang"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$cxx" >"$toolchain_dir/clang++"
chmod +x "$toolchain_dir/clang" "$toolchain_dir/clang++"

if [[ "$using_gcc" == true ]]; then
  echo "Clang is unavailable; using GCC for the Flutter Linux build." >&2
fi

PATH="$toolchain_dir:$PATH" "$@"
