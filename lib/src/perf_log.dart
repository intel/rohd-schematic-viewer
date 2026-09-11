// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// perf_log.dart
// Performance logging configuration for expensive schematic operations.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Enables timing diagnostics for expensive schematic operations.
// ignore: do_not_use_environment
const kPerfLog = bool.fromEnvironment('ROHD_SCHEMATIC_PERF_LOG');
