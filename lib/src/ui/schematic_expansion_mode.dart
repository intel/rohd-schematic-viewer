// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_expansion_mode.dart
// Enum controlling initial schematic expansion state.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/schematic/schematic.dart'
    show SchematicGraph;
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart'
    show SchematicGraph;

/// Controls the initial expansion state of the schematic after loading.
///
/// These modes are a *rendering* concern — they control which
/// [SchematicGraph] methods are called before the first ELK layout,
/// not what data is in the JSON.
enum SchematicExpansionMode {
  /// Default: top module shows non-primitive sub-modules as blocks,
  /// no wires.  This is the `fromJson` default behaviour.
  defaultView,

  /// Nothing expanded — the top module is a single collapsed block.
  collapsed,

  /// All hierarchy blocks visible at every level, but no wires.
  /// Uses `SchematicGraph.expandNonPrimitivesRecursive`.
  blocksOnly,

  /// Fully expanded with all wires visible at every level.
  /// Uses `SchematicGraph.toggleNodeRecursive`.
  fullyExpanded,
}
