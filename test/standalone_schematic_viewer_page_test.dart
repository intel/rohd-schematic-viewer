// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// standalone_schematic_viewer_page_test.dart
// Standalone viewer host behavior tests.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data' show ByteData, Uint8List;

// The embedded help widget still requires Flutter's MaterialLocalizations.
// ignore: migrate_design_widgets
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide DefaultMaterialLocalizations;
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show AppBarOverlay;
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_native.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_help_button.dart';
import 'package:rohd_schematic_viewer/src/ui/standalone_schematic_viewer_page.dart';

void main() {
  testWidgets('changes theme and opens help while viewing a schematic', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          localizationsDelegates: const [
            DefaultMaterialLocalizations.delegate,
          ],
          home: StandaloneSchematicViewerPage(
            initialSchematicJson:
                File('assets/rohd_schematic.json').readAsStringSync(),
            layoutEngine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(find.byTooltip('Switch to light theme'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch to light theme'));
    await tester.pump();

    expect(find.byTooltip('Switch to dark theme'), findsOneWidget);
    expect(
      tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
      Colors.white,
    );

    await tester.tap(find.byType(SchematicHelpButton));
    await tester.pumpAndSettle();

    expect(find.text('Incremental Expansion'), findsOneWidget);
  });

  testWidgets('toggles the standalone app-bar pin control', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: StandaloneSchematicViewerPage(
            initialSchematicJson:
                File('assets/rohd_schematic.json').readAsStringSync(),
            layoutEngine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(find.byTooltip('Unpin top bar'), findsOneWidget);
    expect(
      tester.widget<AppBarOverlay>(find.byType(AppBarOverlay)).autoHide,
      isFalse,
    );
    final canvasState = tester.state<SchematicCanvasState>(
      find.byType(SchematicCanvas),
    );
    const preservedOffset = Offset(140, 100);
    canvasState.setView(offset: preservedOffset, scale: 1.5);
    final anchorBeforeToggle = _schematicAnchor(tester, canvasState);

    await tester.tap(find.byTooltip('Unpin top bar'));
    await tester.pump();

    expect(find.byTooltip('Pin top bar'), findsOneWidget);
    expect(
      tester.widget<AppBarOverlay>(find.byType(AppBarOverlay)).autoHide,
      isTrue,
    );
    expect(canvasState.currentScale, 1.5);
    expect(_schematicAnchor(tester, canvasState), anchorBeforeToggle);

    await tester.tap(find.byTooltip('Pin top bar'));
    await tester.pump();

    expect(canvasState.currentScale, 1.5);
    expect(canvasState.currentOffset, preservedOffset);
    expect(_schematicAnchor(tester, canvasState), anchorBeforeToggle);
  });

  testWidgets(
    'loads the FilterBank fixture and navigates a searched hierarchy result',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final engine = _FakeLayoutEngine();

      await tester.pumpWidget(
        BlocProvider(
          create: (_) => SchematicThemeCubit(),
          child: MaterialApp(
            localizationsDelegates: const [
              DefaultMaterialLocalizations.delegate,
            ],
            home: StandaloneSchematicViewerPage(
              initialSchematicJson:
                  File('assets/FilterBank.rohd.json').readAsStringSync(),
              layoutEngine: engine,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(SchematicCanvas), findsOneWidget);
      expect(engine.elkGraphs.single, contains('FilterBank'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'FilterBank/ch0/mac');
      await tester.pump();

      final result = find.ancestor(
        of: find.text('ch0/mac'),
        matching: find.byType(InkWell),
      );
      expect(result, findsOneWidget);

      await tester.tap(result);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(engine.elkGraphs, hasLength(2));
      expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
    },
  );

  testWidgets('lays out the GateCatalog fixture with the production engine', (
    tester,
  ) async {
    if (Platform.environment['RUN_NATIVE_LAYOUT_COVERAGE'] != 'true') {
      return;
    }
    await _pumpProductionFixture(
      tester,
      'assets/gate_catalog.rohd.json',
      surfaceSize: const Size(1800, 1200),
    );

    expect(find.byType(SchematicCanvas), findsOneWidget);
    final canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.layout.instances.length, greaterThan(80));
    expect(find.textContaining('Failed to load schematic'), findsNothing);
  });
}

Future<void> _pumpProductionFixture(
  WidgetTester tester,
  String fixturePath, {
  required Size surfaceSize,
}) async {
  SchematicLayoutEngineNative().forceDispose();
  addTearDown(() => SchematicLayoutEngineNative().forceDispose());
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
    if (message == null) {
      return null;
    }
    var assetKey = utf8.decode(
      message.buffer.asUint8List(
        message.offsetInBytes,
        message.lengthInBytes,
      ),
    );
    const packagePrefix = 'packages/rohd_schematic_viewer/';
    if (assetKey.startsWith(packagePrefix)) {
      assetKey = assetKey.substring(packagePrefix.length);
    }
    final asset = File(assetKey);
    if (!asset.existsSync()) {
      return null;
    }
    return ByteData.sublistView(Uint8List.fromList(asset.readAsBytesSync()));
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null),
  );

  await tester.pumpWidget(
    BlocProvider(
      create: (_) => SchematicThemeCubit(),
      child: MaterialApp(
        localizationsDelegates: const [
          DefaultMaterialLocalizations.delegate,
        ],
        home: StandaloneSchematicViewerPage(
          initialSchematicJson: File(fixturePath).readAsStringSync(),
        ),
      ),
    ),
  );

  await tester.runAsync(
    () => Future<void>.delayed(const Duration(seconds: 10)),
  );
  for (var attempt = 0;
      attempt < 300 && find.byType(SchematicCanvas).evaluate().isEmpty;
      attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Offset _schematicAnchor(WidgetTester tester, SchematicCanvasState canvasState) {
  final canvasBox =
      tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
  const schematicPoint = Offset(100, 80);
  return canvasBox.localToGlobal(
    schematicPoint * canvasState.currentScale + canvasState.currentOffset,
  );
}

class _FakeLayoutEngine implements SchematicLayoutEngine {
  final List<String> elkGraphs = [];

  @override
  bool get isAvailable => true;

  @override
  SchematicDependencyStatus checkDependencies() =>
      SchematicDependencyStatus(elk: true);

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) async {
    elkGraphs.add(elkGraphJson);
    return SchematicLayoutResult(
      instances: [
        SchematicInstanceData(
          id: 'FilterBank',
          x: 20,
          y: 20,
          width: 220,
          height: 120,
          name: 'FilterBank',
          hasChildren: true,
        ),
      ],
      ports: const [],
      edges: const [],
      width: 260,
      height: 160,
    );
  }

  @override
  void dispose() {}
}
