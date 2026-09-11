// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_engine.dart
// Abstract interface for schematic layout computation.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

export 'schematic_layout_models.dart';

/// Abstract interface for schematic layout computation.
///
/// Web: Uses browser's JavaScript engine with ELK
/// Native: Uses QuickJS via flutter_js with bundled ELK
abstract class SchematicLayoutEngine {
  /// Check if the layout engine is available.
  bool get isAvailable;

  /// Check the status of JavaScript dependencies.
  SchematicDependencyStatus checkDependencies();

  /// Compute layout from a pre-parsed ELK graph (Dart-first path).
  ///
  /// This accepts an ELK-formatted graph (from `SchematicGraph.toJsGraph()`)
  /// and runs ELK layout. All netlist-to-ELK conversion and post-processing
  /// is done in Dart.
  ///
  /// The [elkGraphJson] should be the result of
  /// `NetlistSchematicAdapter.toJsGraph()`.
  ///
  /// [sessionId] isolates JS bridge state per session.
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  });

  /// Dispose of any resources.
  void dispose();
}
