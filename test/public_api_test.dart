// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// public_api_test.dart
// Compile-time coverage for supported package entry points.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/schematic_connectivity.dart'
    as connectivity;
import 'package:rohd_schematic_viewer/schematic_host.dart' as host;
import 'package:rohd_schematic_viewer/schematic_layout.dart' as layout;
import 'package:rohd_schematic_viewer/schematic_viewer.dart' as viewer;

void main() {
  test('core entry point exposes the embedded widget contract', () {
    const embeddedViewer = viewer.EmbeddedSchematicViewer.fromJson(
      schematicJson: '{}',
      themeMode: viewer.SchematicThemeMode.dark,
      expansionMode: viewer.SchematicExpansionMode.collapsed,
    );
    const icon = viewer.SchematicIcon();
    const helpButton = viewer.SchematicHelpButton(isDark: true);

    expect(embeddedViewer.schematicJson, '{}');
    expect(embeddedViewer.themeMode, viewer.SchematicThemeMode.dark);
    expect(
      embeddedViewer.expansionMode,
      viewer.SchematicExpansionMode.collapsed,
    );
    expect(icon, isA<viewer.SchematicIcon>());
    expect(helpButton, isA<viewer.SchematicHelpButton>());
  });

  test('optional entry points expose intentional advanced contracts', () {
    expect(layout.SchematicLayoutEngine, isNotNull);
    expect(layout.SchematicLayoutResult, isNotNull);
    expect(host.StandaloneSchematicViewerPage, isNotNull);
    expect(host.FlutterSchematicViewerPage, isNotNull);
    expect(connectivity.NetlistSchematicConnectivity, isNotNull);
    expect(connectivity.SchematicTraversalMode, isNotNull);
  });
}
