// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_stub.dart
// Stub for conditional import of schematic layout engine.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';

/// Stub factory - should never be called directly.
/// Use conditional imports to get the right implementation.
SchematicLayoutEngine createSchematicLayoutEngine() {
  throw UnsupportedError(
    'Cannot create SchematicLayoutEngine without a platform implementation. '
    'Use conditional imports to include the correct implementation.',
  );
}
