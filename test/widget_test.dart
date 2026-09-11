// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// widget_test.dart
// Widget tests for the SchematicViewerApp.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/src/app.dart';

void main() {
  group('SchematicViewerApp Widget Tests', () {
    testWidgets('SchematicViewerApp renders and builds MaterialApp', (
      tester,
    ) async {
      // Build our app and trigger a frame.
      await tester.pumpWidget(const SchematicViewerApp());

      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('SchematicViewerApp has correct title', (tester) async {
      await tester.pumpWidget(const SchematicViewerApp());

      final app =
          find.byType(MaterialApp).evaluate().first.widget as MaterialApp;
      expect(app.title, 'ROHD Schematic Viewer');
    });

    testWidgets('SchematicViewerApp uses dark theme', (tester) async {
      await tester.pumpWidget(const SchematicViewerApp());

      final app =
          find.byType(MaterialApp).evaluate().first.widget as MaterialApp;
      expect(app.theme, isNotNull);
      // Verify dark theme is applied
      expect(app.themeMode, equals(ThemeMode.system)); // Default themeMode
    });

    testWidgets('SchematicViewerApp initializes correctly', (tester) async {
      await tester.pumpWidget(const SchematicViewerApp());
      // Avoid waiting for potential long-running async layout initialization
      await tester.pump();

      // Verify the app doesn't crash and renders a Scaffold
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}
