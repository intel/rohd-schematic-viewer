// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout.dart
// Optional custom schematic layout API.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Public API for custom schematic layout engines.
library;

export 'src/services/schematic_layout_engine.dart' show SchematicLayoutEngine;
export 'src/services/schematic_layout_models.dart'
    show
        SchematicDependencyStatus,
        SchematicEdgeData,
        SchematicInstanceData,
        SchematicLayoutResult,
        SchematicPoint,
        SchematicPortData;
