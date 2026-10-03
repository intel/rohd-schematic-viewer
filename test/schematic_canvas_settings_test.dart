// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_canvas_settings_test.dart
// Tests painter settings that do not require layout recomputation.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

void main() {
  test('width display setting invalidates the painter without a new layout',
      () {
    final viewTransform = ValueNotifier((
      scale: 1.0,
      offset: Offset.zero,
    ));
    final snapshotMode = ValueNotifier(false);
    final hoveredPort = ValueNotifier<({String? portId, bool isInterior})>((
      portId: null,
      isInterior: false,
    ));
    addTearDown(() {
      viewTransform.dispose();
      snapshotMode.dispose();
      hoveredPort.dispose();
    });

    final withoutWidths = SchematicPainter(
      layout: SchematicLayoutResult.empty(),
      viewTransform: viewTransform,
      snapshotMode: snapshotMode,
      hoveredBoundaryPortNotifier: hoveredPort,
      displaySignalWidths: false,
    );
    final withWidths = SchematicPainter(
      layout: SchematicLayoutResult.empty(),
      viewTransform: viewTransform,
      snapshotMode: snapshotMode,
      hoveredBoundaryPortNotifier: hoveredPort,
    );

    expect(withWidths.shouldRepaint(withoutWidths), isTrue);
  });
}
