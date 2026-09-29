// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_expansion_mode.dart
// Enum controlling initial schematic expansion state.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Controls the initial expansion state of the schematic after loading.
///
/// These modes are a *rendering* concern. They control graph or hierarchy
/// expansion before layout, not what data is present in the source.
enum SchematicExpansionMode {
  /// Default: top module shows non-primitive sub-modules as blocks,
  /// no wires.  This is the `fromJson` default behaviour.
  defaultView,

  /// Nothing expanded — the top module is a single collapsed block.
  collapsed,

  /// All hierarchy blocks visible at every level, but no wires.
  /// Uses `SchematicGraph.expandNonPrimitivesRecursive`.
  blocksOnly,

  /// Fully expanded with all available wires visible at every level.
  ///
  /// Uses `SchematicGraph.toggleNodeRecursive` for netlist-backed layouts.
  /// Hierarchy-only layouts have no wires, so this behaves like [blocksOnly].
  fullyExpanded,
}
