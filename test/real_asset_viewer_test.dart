// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// real_asset_viewer_test.dart
// Widget lifecycle tests driven by realistic schematic fixtures.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart'
    show
        DiagnosticPropertiesBuilder,
        DiagnosticsProperty,
        ObjectFlagProperty,
        StringProperty;
import 'package:flutter/gestures.dart'
    show PointerHoverEvent, PointerScrollEvent, kSecondaryMouseButton;
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, SystemChannels, TextInputAction;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show
        AvailableSourceFormats,
        GoToSourceCallback,
        RohdSourceFormat,
        gotoSourceMenuValue;
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/schematic/wire_search_overlay.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_expansion_mode.dart';

void main() {
  testWidgets('browses the complete GateCatalog fixture', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine(variedPortSides: true);

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/gate_catalog.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(engine.layouts, hasLength(1));
    final layout = engine.layouts.single;
    expect(layout.instances.length, greaterThan(80));
    expect(
      layout.instances.map((instance) => instance.name),
      containsAll(<String>[
        'MUX',
        'AND',
        'OR',
        'XOR',
        'ADD',
        'MUL',
        'FF_clk1',
        'FF_EN_clk1_en1',
        'FF_SRST_clk1_rst1',
        'FF_SRST_EN_clk1_rst1_en1',
        'FF_ARST_clk1_rst1',
        'FF_ARST_EN_clk1_rst1_en1',
      ]),
    );

    final canvasState = canvasKey.currentState!;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    for (final instance in layout.instances.where(
      (candidate) => !candidate.hasChildren,
    )) {
      final localPosition = Offset(
                instance.x + instance.width / 2,
                instance.y + instance.height / 2,
              ) *
              canvasState.currentScale +
          canvasState.currentOffset;
      if (localPosition.dx < 0 ||
          localPosition.dy < 0 ||
          localPosition.dx > canvasBox.size.width ||
          localPosition.dy > canvasBox.size.height) {
        continue;
      }
      await tester.sendEventToBinding(
        PointerHoverEvent(
          kind: PointerDeviceKind.mouse,
          position: canvasBox.localToGlobal(localPosition),
        ),
      );
    }
    await tester.pump();

    final focalPoint = canvasBox.localToGlobal(
      Offset(canvasBox.size.width / 2, canvasBox.size.height / 2),
    );
    for (var index = 0; index < 24; index++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: focalPoint,
          scrollDelta: const Offset(0, -20),
        ),
      );
    }
    await tester.pump();

    expect(canvasState.currentScale, greaterThan(1));
    expect(find.byTooltip('Export schematic as PNG'), findsOneWidget);
  });

  testWidgets('inspects FilterBank ports on every side and direction', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _PortOrientationLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs.single, contains('FilterBank'));
    expect(find.byType(SchematicCanvas), findsOneWidget);

    final canvasState = canvasKey.currentState!;
    final canvasFinder = find.byType(SchematicCanvas);
    final canvasBox = tester.renderObject(canvasFinder) as RenderBox;

    for (final port in engine.layout.ports) {
      final boundary = switch (port.side) {
        'WEST' => Offset(port.x + port.width, port.y + port.height / 2),
        'EAST' => Offset(port.x, port.y + port.height / 2),
        'NORTH' => Offset(port.x + port.width / 2, port.y + port.height),
        'SOUTH' => Offset(port.x + port.width / 2, port.y),
        _ => throw StateError('Unexpected port side ${port.side}'),
      };
      final exteriorDelta = switch (port.side) {
        'WEST' => const Offset(-3, 0),
        'EAST' => const Offset(3, 0),
        'NORTH' => const Offset(0, -3),
        'SOUTH' => const Offset(0, 3),
        _ => Offset.zero,
      };

      for (final schematicPosition in <Offset>[
        boundary + exteriorDelta,
        boundary - exteriorDelta,
      ]) {
        final localPosition = schematicPosition * canvasState.currentScale +
            canvasState.currentOffset;
        await tester.sendEventToBinding(
          PointerHoverEvent(
            kind: PointerDeviceKind.mouse,
            position: canvasBox.localToGlobal(localPosition),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.tapAt(canvasBox.localToGlobal(localPosition));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }

    final modulePosition = const Offset(440, 350) * canvasState.currentScale +
        canvasState.currentOffset;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(canvasBox.localToGlobal(modulePosition));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(canvasBox.localToGlobal(modulePosition));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final externalPort = engine.layout.instances.last;
    final externalPosition = Offset(
              externalPort.x + externalPort.width / 2,
              externalPort.y + externalPort.height / 2,
            ) *
            canvasState.currentScale +
        canvasState.currentOffset;
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        position: canvasBox.localToGlobal(externalPosition),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('inspects visible FilterBank bus connections at every boundary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _PortOrientationLayoutEngine(showMarkers: false);

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            signalValueLookup: (wireName) =>
                (value: "8'h5a", computed: true, signalId: wireName),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final canvasState = canvasKey.currentState!;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final connectedPortIds = engine.layout.edges
        .expand((edge) => [edge.sourcePort, edge.targetPort])
        .whereType<String>()
        .toSet();

    for (final port in engine.layout.ports.where(
      (candidate) => connectedPortIds.contains(candidate.id),
    )) {
      final localPosition =
          Offset(port.x + port.width / 2, port.y + port.height / 2) *
                  canvasState.currentScale +
              canvasState.currentOffset;
      await tester.sendEventToBinding(
        PointerHoverEvent(
          kind: PointerDeviceKind.mouse,
          position: canvasBox.localToGlobal(localPosition),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    expect(find.textContaining('5a'), findsOneWidget);
  });

  testWidgets('loads the FilterBank fixture into the schematic canvas', (
    tester,
  ) async {
    final engine = _FakeLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(engine.elkGraphs, hasLength(1));
    expect(engine.elkGraphs.single, contains('FilterBank'));
  });

  testWidgets('reports diagnostics for the loaded FilterBank viewer', (
    tester,
  ) async {
    final hostKey = GlobalKey<_AssetViewerHostState>();
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _FakeLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            key: hostKey,
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final hostState = hostKey.currentState!;
    final properties = DiagnosticPropertiesBuilder();
    hostState.debugFillProperties(properties);

    expect(
      properties.properties.map((property) => property.name),
      containsAll(<String>[
        'schematicAdapter',
        'layout',
        'schematicJson',
        'fileName',
        'error',
        'isLoading',
        'isToggling',
        'pendingToggleNodeId',
        'recentlyToggledNodeId',
        'focusPortId',
        'externalHierarchy',
        'layoutEngine',
        'sessionId',
        'togglingLabel',
        'signalValueLookup',
        'onSendSignals',
        'hasExternalSignalListeners',
        'onGoToSource',
        'availableSourceFormats',
        'incomingSignalPaths',
        'crossProbeService',
      ]),
    );

    final canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    final canvasProperties = DiagnosticPropertiesBuilder();
    canvas.debugFillProperties(canvasProperties);

    expect(
      canvasProperties.properties.map((property) => property.name),
      containsAll(<String>[
        'layout',
        'colorScheme',
        'netlistJson',
        'externalHierarchy',
        'onNodeToggle',
        'pendingToggleNodeId',
        'recentlyToggledNodeId',
        'isDimmed',
        'focusPortId',
        'signalValueLookup',
        'onPortExpand',
        'onPortExpandThrough',
        'onCollapsePartial',
        'onExpandNonPrimitives',
        'onConvertToBlocksOnly',
        'onExpandChild',
        'onExpandPath',
        'onPortCollapse',
        'onPortCollapseThrough',
        'onNodeToggleRecursive',
        'onExpandNonPrimitivesRecursive',
        'onConvertToBlocksOnlyRecursive',
        'onExpandWire',
        'signalNameForPort',
        'onSendSignals',
        'hasExternalSignalListeners',
        'onGoToSource',
        'availableSourceFormats',
        'incomingSignalPaths',
      ]),
    );

    final canvasState = canvasKey.currentState!
      ..setView(offset: const Offset(24, 36), scale: 1.5);
    final canvasStateProperties = DiagnosticPropertiesBuilder();
    canvasState.debugFillProperties(canvasStateProperties);

    expect(canvasState.currentOffset, const Offset(24, 36));
    expect(canvasState.currentScale, 1.5);
    expect(
      canvasStateProperties.properties.map((property) => property.name),
      containsAll(<String>['currentScale', 'currentOffset']),
    );
    expect(
      canvasStateProperties.properties
          .firstWhere((property) => property.name == 'currentScale')
          .value,
      1.5,
    );
    expect(
      canvasStateProperties.properties
          .firstWhere((property) => property.name == 'currentOffset')
          .value,
      const Offset(24, 36),
    );
  });

  testWidgets('shows a layout error for the FilterBank fixture', (
    tester,
  ) async {
    final engine = _FakeLayoutEngine(
      result: SchematicLayoutResult(
        instances: const [],
        ports: const [],
        edges: const [],
        width: 0,
        height: 0,
        error: 'ELK unavailable',
      ),
    );

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Error'), findsOneWidget);
    expect(
      find.textContaining('Layout error: ELK unavailable'),
      findsOneWidget,
    );
    expect(find.byType(SchematicCanvas), findsNothing);
  });

  testWidgets('shows an exception from the FilterBank layout engine', (
    tester,
  ) async {
    final engine = _FakeLayoutEngine(
      exception: Exception('simulated engine failure'),
    );

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Error'), findsOneWidget);
    expect(
      find.textContaining(
        'Error computing layout: Exception: simulated engine failure',
      ),
      findsOneWidget,
    );
    expect(find.byType(SchematicCanvas), findsNothing);
  });

  testWidgets('projects FilterBank initial expansion modes', (tester) async {
    Future<SchematicLayoutResult> loadMode(SchematicExpansionMode mode) async {
      final engine = _ProjectedLayoutEngine();
      await tester.pumpWidget(
        BlocProvider(
          create: (_) => SchematicThemeCubit(),
          child: MaterialApp(
            home: _AssetViewerHost(
              key: ValueKey<SchematicExpansionMode>(mode),
              assetPath: 'assets/FilterBank.rohd.json',
              engine: engine,
              expansionMode: mode,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(engine.layouts, hasLength(1));
      return engine.layouts.single;
    }

    final collapsed = await loadMode(SchematicExpansionMode.collapsed);
    final defaultView = await loadMode(SchematicExpansionMode.defaultView);
    final blocksOnly = await loadMode(SchematicExpansionMode.blocksOnly);
    final fullyExpanded = await loadMode(SchematicExpansionMode.fullyExpanded);

    expect(collapsed.instances.length, lessThan(defaultView.instances.length));
    expect(
      blocksOnly.instances.length,
      greaterThan(collapsed.instances.length),
    );
    expect(blocksOnly.edges, isEmpty);
    expect(fullyExpanded.edges.length, greaterThan(blocksOnly.edges.length));
  });

  testWidgets('expands a FilterBank node through the viewer controller', (
    tester,
  ) async {
    final hostKey = GlobalKey<_AssetViewerHostState>();
    final engine = _FakeLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            key: hostKey,
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final expansion = hostKey.currentState!.expandFirstFilterBankNode();
    await tester.pump();
    final expandedLayout = await expansion;
    await tester.pump();

    expect(expandedLayout, isNotNull);
    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
    expect(find.byType(SchematicCanvas), findsOneWidget);
  });

  testWidgets('recovers from a failed FilterBank node toggle', (tester) async {
    final hostKey = GlobalKey<_AssetViewerHostState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            key: hostKey,
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialGraph = engine.elkGraphs.single;
    engine.nextResult = SchematicLayoutResult(
      instances: const [],
      ports: const [],
      edges: const [],
      width: 0,
      height: 0,
      error: 'simulated ELK rejection',
    );
    final failedToggle = hostKey.currentState!.expandFirstFilterBankNode();
    await tester.pump();
    expect(await failedToggle, isNull);
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.first, initialGraph);

    final recoveredToggle = hostKey.currentState!.expandFirstFilterBankNode();
    await tester.pump();
    expect(await recoveredToggle, isNotNull);
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    expect(engine.elkGraphs.last, isNot(equals(initialGraph)));
  });

  testWidgets('zooms the FilterBank canvas with a pinch gesture', (
    tester,
  ) async {
    final canvasKey = GlobalKey<SchematicCanvasState>();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialScale = canvasKey.currentState!.currentScale;
    final firstFinger = await tester.startGesture(const Offset(300, 300));
    final secondFinger = await tester.startGesture(
      const Offset(400, 300),
      pointer: 2,
    );
    await tester.pump();
    await firstFinger.moveTo(const Offset(250, 300));
    await secondFinger.moveTo(const Offset(450, 300));
    await tester.pump();
    await firstFinger.up();
    await secondFinger.up();

    expect(canvasKey.currentState!.currentScale, greaterThan(initialScale));
  });

  testWidgets('zooms FilterBank through a plain hover tooltip', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final edge = engine.layouts.single.edges.firstWhere(
      (candidate) => candidate.points.length >= 4,
    );
    final segmentStart = edge.points[2];
    final segmentEnd = edge.points[3];
    final canvasState = canvasKey.currentState!;
    final edgePosition = Offset(
      (segmentStart.x + segmentEnd.x) / 2,
      (segmentStart.y + segmentEnd.y) / 2,
    );
    final canvasPosition =
        edgePosition * canvasState.currentScale + canvasState.currentOffset;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final edgeGlobalPosition = canvasBox.localToGlobal(canvasPosition);

    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        position: edgeGlobalPosition,
      ),
    );
    await tester.pump();

    final scaleBeforeWheel = canvasState.currentScale;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: edgeGlobalPosition + const Offset(15, 15),
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.pump();

    expect(canvasState.currentScale, greaterThan(scaleBeforeWheel));
  });

  testWidgets('pans the FilterBank canvas with a drag gesture', (tester) async {
    final canvasKey = GlobalKey<SchematicCanvasState>();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialOffset = canvasKey.currentState!.currentOffset;
    await tester.dragFrom(const Offset(300, 300), const Offset(80, 60));
    await tester.pump();

    expect(canvasKey.currentState!.currentOffset, isNot(initialOffset));
  });

  testWidgets('zooms the FilterBank canvas with forward and reverse regions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialScale = canvasKey.currentState!.currentScale;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final zoomIn = await tester.startGesture(
      const Offset(250, 200),
      kind: PointerDeviceKind.mouse,
    );
    await zoomIn.moveTo(const Offset(700, 600));
    await tester.pump();
    await zoomIn.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final zoomedInScale = canvasKey.currentState!.currentScale;
    expect(zoomedInScale, isNot(initialScale));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final zoomOut = await tester.startGesture(
      const Offset(700, 600),
      kind: PointerDeviceKind.mouse,
    );
    await zoomOut.moveTo(const Offset(250, 200));
    await tester.pump();
    await zoomOut.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(canvasKey.currentState!.currentScale, lessThan(zoomedInScale));
  });

  testWidgets('copies FilterBank node names and paths from the canvas menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _FakeLayoutEngine();
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.result ??
        SchematicLayoutResult(
          instances: const [],
          ports: const [],
          edges: const [],
          width: 0,
          height: 0,
        );
    final instance = block.instances.isNotEmpty
        ? block.instances.single
        : SchematicInstanceData(
            id: 'FilterBank',
            x: 20,
            y: 20,
            width: 220,
            height: 120,
            name: 'FilterBank',
            hasChildren: true,
          );
    final canvasState = canvasKey.currentState!;
    final nodePosition = Offset(
              instance.x + instance.width / 2,
              instance.y + instance.height / 2,
            ) *
            canvasState.currentScale +
        canvasState.currentOffset;

    await tester.tapAt(nodePosition);
    await tester.pump();
    await tester.tapAt(
      nodePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.text('Copy 1 Name'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('copy_name');
    await tester.pump();

    expect(clipboardText, equals('FilterBank'));

    await tester.tapAt(
      nodePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.text('Copy 1 Full Path'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('copy_path');
    await tester.pump();

    expect(clipboardText, equals('FilterBank'));
  });

  testWidgets('shows FilterBank module details while hovering', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final canvasState = canvasKey.currentState!;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final leaf = engine.layouts.single.instances.firstWhere(
      (instance) => !instance.hasChildren,
    );
    final leafPosition = canvasBox.localToGlobal(
      Offset(leaf.x + leaf.width / 2, leaf.y + leaf.height / 2) *
              canvasState.currentScale +
          canvasState.currentOffset,
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(kind: PointerDeviceKind.mouse, position: leafPosition),
    );
    await tester.pump();

    expect(find.textContaining('inputs:'), findsOneWidget);
    expect(find.textContaining('outputs:'), findsOneWidget);
  });

  testWidgets('shows a live value while hovering a FilterBank wire', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
            signalValueLookup: (wireName) =>
                (value: "8'h2a", computed: true, signalId: wireName),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final edge = engine.layouts.single.edges.firstWhere(
      (candidate) => candidate.points.length >= 4,
    );
    final start = edge.points[2];
    final end = edge.points[3];
    final canvasState = canvasKey.currentState!;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final wirePosition = canvasBox.localToGlobal(
      Offset((start.x + end.x) / 2, (start.y + end.y) / 2) *
              canvasState.currentScale +
          canvasState.currentOffset,
    );

    await tester.sendEventToBinding(
      PointerHoverEvent(kind: PointerDeviceKind.mouse, position: wirePosition),
    );
    await tester.pump();

    expect(find.textContaining('2a'), findsOneWidget);
  });

  testWidgets('explores FilterBank at overview and detail zoom levels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: _ProjectedLayoutEngine(),
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final focalPoint = canvasBox.localToGlobal(
      Offset(canvasBox.size.width / 2, canvasBox.size.height / 2),
    );
    for (var index = 0; index < 30; index++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: focalPoint,
          scrollDelta: const Offset(0, -20),
        ),
      );
    }
    await tester.pump();
    expect(canvasKey.currentState!.currentScale, greaterThan(3));

    for (var index = 0; index < 70; index++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: focalPoint,
          scrollDelta: const Offset(0, 20),
        ),
      );
    }
    await tester.pump();
    expect(canvasKey.currentState!.currentScale, lessThan(0.2));

    await tester.binding.setSurfaceSize(const Size(420, 320));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(1800, 1200));
    await tester.pump();
    expect(find.byType(SchematicCanvas), findsOneWidget);
  });

  testWidgets('shows an unmarked FilterBank port name while hovering', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final layout = engine.layouts.single;
    final markedPortIds = {
      ...layout.interiorHiddenPortIds,
      ...layout.exteriorHiddenPortIds,
    };
    final instancesById = {
      for (final instance in layout.instances) instance.id: instance,
    };
    final connectedPortIds = {
      for (final edge in layout.edges)
        if (edge.sourcePort != null) edge.sourcePort!,
      for (final edge in layout.edges)
        if (edge.targetPort != null) edge.targetPort!,
    };
    final port = layout.ports.firstWhere(
      (candidate) =>
          !markedPortIds.contains(candidate.id) &&
          !(instancesById[candidate.instanceId]?.isExternalPort ?? true) &&
          !connectedPortIds.contains(candidate.id),
    );
    final canvasState = canvasKey.currentState!;
    final canvasBox =
        tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
    final portPosition = canvasBox.localToGlobal(
      Offset(port.x + port.width / 2, port.y + port.height / 2) *
              canvasState.currentScale +
          canvasState.currentOffset,
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(kind: PointerDeviceKind.mouse, position: portPosition),
    );
    await tester.pump();

    expect(find.textContaining(port.name.split('Pipe').first), findsWidgets);
  });

  testWidgets('adds and removes multiple FilterBank selections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            expansionMode: SchematicExpansionMode.fullyExpanded,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final layout = engine.layouts.single;
    final edge = layout.edges.firstWhere(
      (candidate) => candidate.points.length >= 4,
    );
    final edgeStart = edge.points[2];
    final edgeEnd = edge.points[3];
    final canvasState = canvasKey.currentState!;
    Offset toScreen(Offset schematic) =>
        schematic * canvasState.currentScale + canvasState.currentOffset;
    final edgePosition = toScreen(
      Offset((edgeStart.x + edgeEnd.x) / 2, (edgeStart.y + edgeEnd.y) / 2),
    );
    final leaf = layout.instances.firstWhere(
      (instance) => !instance.hasChildren,
    );
    final nodePosition = toScreen(
      Offset(leaf.x + leaf.width / 2, leaf.y + leaf.height / 2),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(edgePosition);
    await tester.tapAt(nodePosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.tapAt(
      edgePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.text('Copy 2 Names'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(edgePosition);
    await tester.tapAt(nodePosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.tapAt(
      edgePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
  });

  testWidgets('navigates to FilterBank source from a selected node', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    RohdSourceFormat? selectedFormat;
    List<String>? selectedPaths;

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: _FakeLayoutEngine(),
            onGoToSource: (format, paths) {
              selectedFormat = format;
              selectedPaths = paths;
            },
            availableSourceFormats: () => const [
              RohdSourceFormat.rohd,
              RohdSourceFormat.sv,
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final canvasState = canvasKey.currentState!;
    final nodePosition = const Offset(130, 80) * canvasState.currentScale +
        canvasState.currentOffset;
    await tester.tapAt(nodePosition);
    await tester.pump();
    await tester.tapAt(
      nodePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.textContaining('ROHD'), findsOneWidget);
    expect(find.textContaining('SV'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas)))
        .pop(gotoSourceMenuValue(RohdSourceFormat.rohd));
    await tester.pump();

    expect(selectedFormat, RohdSourceFormat.rohd);
    expect(selectedPaths, equals(['FilterBank']));
  });

  testWidgets('uses FilterBank canvas controls for blocks-only and collapse', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    Offset controlPosition(SchematicInstanceData instance, int slot) {
      final scale = canvasKey.currentState!.currentScale;
      final iconSize = 20.0 / scale;
      final iconPadding = iconSize * 0.4;
      return Offset(
                instance.x +
                    instance.width -
                    iconPadding -
                    iconSize / 2 +
                    slot * iconSize * 1.15,
                instance.y + iconPadding + iconSize / 2,
              ) *
              scale +
          canvasKey.currentState!.currentOffset;
    }

    final initialBlock = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasChildren,
    );
    await tester.tapAt(controlPosition(initialBlock, 0));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final expandedBlock = engine.layouts.last.instances.firstWhere(
      (instance) => instance.id == initialBlock.id,
    );
    expect(expandedBlock.isExpanded, isTrue);

    await tester.tapAt(controlPosition(expandedBlock, -1));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    final collapsedBlock = engine.layouts.last.instances.firstWhere(
      (instance) => instance.id == initialBlock.id,
    );
    expect(collapsedBlock.isExpanded, isFalse);

    await tester.tapAt(controlPosition(collapsedBlock, 0));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(4));
    final expandedAgain = engine.layouts.last.instances.firstWhere(
      (instance) => instance.id == initialBlock.id,
    );
    expect(expandedAgain.isExpanded, isTrue);

    await tester.tapAt(controlPosition(expandedAgain, 0));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(5));
    expect(engine.layouts.last.edges, isEmpty);
  });

  testWidgets('expands a real FilterBank block through its canvas control', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final hostKey = GlobalKey<_AssetViewerHostState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            key: hostKey,
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasChildren,
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    final schematicPosition = Offset(
      block.x + block.width - iconPadding - iconSize / 2,
      block.y + iconPadding + iconSize / 2,
    );
    final screenPosition = schematicPosition * canvasState.currentScale +
        canvasState.currentOffset;

    await tester.tapAt(screenPosition);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
    expect(engine.layouts.last.edges, isNotEmpty);
    expect(
      engine.layouts.last.edges.every((edge) => edge.points.length >= 2),
      isTrue,
    );

    Offset midpointOnDrawableSegment(SchematicEdgeData candidate) {
      // The projector reserves the third segment for an empty horizontal
      // routing lane, avoiding node bodies that take precedence over wires.
      for (var index = 2; index < candidate.points.length - 1; index++) {
        final start = candidate.points[index];
        final end = candidate.points[index + 1];
        if ((start.y - end.y).abs() <= 1 && (start.x - end.x).abs() > 1) {
          return Offset((start.x + end.x) / 2, (start.y + end.y) / 2);
        }
      }

      SchematicPoint? longestStart;
      SchematicPoint? longestEnd;
      var longestLength = 0.0;
      for (var index = 0; index < candidate.points.length - 1; index++) {
        final start = candidate.points[index];
        final end = candidate.points[index + 1];
        final length = (start.x - end.x).abs() + (start.y - end.y).abs();
        if (length > longestLength) {
          longestStart = start;
          longestEnd = end;
          longestLength = length;
        }
      }
      if (longestStart == null || longestEnd == null || longestLength <= 1) {
        throw StateError('Expected a drawable projected edge segment');
      }
      return Offset(
        (longestStart.x + longestEnd.x) / 2,
        (longestStart.y + longestEnd.y) / 2,
      );
    }

    final edge = engine.layouts.last.edges.firstWhere(
      (candidate) => candidate.points.length >= 2,
    );
    final edgePosition = midpointOnDrawableSegment(edge);
    final viewBeforeWireZoom = (
      scale: canvasState.currentScale,
      offset: canvasState.currentOffset,
    );
    final edgeScreenPosition =
        edgePosition * canvasState.currentScale + canvasState.currentOffset;
    await tester.tapAt(edgeScreenPosition);
    await tester.pump();
    await tester.tapAt(edgeScreenPosition);
    await tester.pump();

    expect((
      scale: canvasState.currentScale,
      offset: canvasState.currentOffset,
    ), isNot(equals(viewBeforeWireZoom)));

    final secondWireEdge = engine.layouts.last.edges.firstWhere(
      (candidate) =>
          candidate.wireId != edge.wireId && candidate.points.length >= 2,
    );
    final secondWirePosition = midpointOnDrawableSegment(secondWireEdge);
    final selectedWirePosition =
        edgePosition * canvasState.currentScale + canvasState.currentOffset;
    final secondWireScreenPosition =
        secondWirePosition * canvasState.currentScale +
            canvasState.currentOffset;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(secondWireScreenPosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.tapAt(
      selectedWirePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.text('Copy 2 Names'), findsOneWidget);
    expect(find.text('Copy 2 Full Paths'), findsOneWidget);
    expect(find.text('Fit to Selection'), findsOneWidget);

    final viewBeforeFit = (
      scale: canvasState.currentScale,
      offset: canvasState.currentOffset,
    );
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('fit');
    await tester.pump();

    expect((
      scale: canvasState.currentScale,
      offset: canvasState.currentOffset,
    ), isNot(equals(viewBeforeFit)));

    final expandedBlock = engine.layouts.last.instances.firstWhere(
      (instance) => instance.id == block.id,
    );
    expect(expandedBlock.isExpanded, isTrue);

    final blocksOnly = hostKey.currentState!.convertToBlocksOnly(block.id);
    await tester.pump();
    await blocksOnly;
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs[1])));

    final collapse = hostKey.currentState!.collapsePartial(block.id);
    await tester.pump();
    await collapse;
    await tester.pump();

    expect(engine.elkGraphs, hasLength(4));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs[2])));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'ch0/dataOut');
    await tester.pump();

    final searchResult = find.ancestor(
      of: find.text('ch0/dataOut'),
      matching: find.byType(InkWell),
    );
    expect(searchResult, findsWidgets);

    await tester.tap(searchResult.first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsNothing);
    expect(engine.elkGraphs, hasLength(5));
    expect(
      engine.layouts.last.edges.any((edge) => edge.wireId == 'dataOut'),
      isTrue,
    );
  });

  testWidgets('recursively expands FilterBank from its canvas control', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasChildren,
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    final expandPosition = Offset(
      block.x + block.width - iconPadding - iconSize / 2,
      block.y + iconPadding + iconSize / 2,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(
      expandPosition * canvasState.currentScale + canvasState.currentOffset,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
    expect(
      engine.layouts.last.instances.where((instance) => instance.isExpanded),
      hasLength(greaterThan(1)),
    );

    final expandedBlock = engine.layouts.last.instances.firstWhere(
      (instance) => instance.id == block.id,
    );
    final blocksOnlyPosition = Offset(
      expandedBlock.x + expandedBlock.width - iconPadding - iconSize / 2,
      expandedBlock.y + iconPadding + iconSize / 2,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(
      blocksOnlyPosition * canvasState.currentScale + canvasState.currentOffset,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    expect(engine.layouts.last.edges, isEmpty);
  });

  testWidgets('expands FilterBank non-primitives from its canvas control', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasHiddenNonPrimitiveChildren,
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    const gap = iconSize * 0.15;
    final rightX = block.x + block.width - iconPadding - iconSize / 2;
    final nonPrimitivePosition = Offset(
      rightX - iconSize - gap,
      block.y + iconPadding + iconSize / 2,
    );

    await tester.tapAt(
      nonPrimitivePosition * canvasState.currentScale +
          canvasState.currentOffset,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
    expect(
      engine.layouts.last.instances.where((instance) => instance.isExpanded),
      isNotEmpty,
    );
  });

  testWidgets(
    'recursively expands FilterBank non-primitives from its control',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final canvasKey = GlobalKey<SchematicCanvasState>();
      final engine = _ProjectedLayoutEngine();

      await tester.pumpWidget(
        BlocProvider(
          create: (_) => SchematicThemeCubit(),
          child: MaterialApp(
            home: _AssetViewerHost(
              assetPath: 'assets/FilterBank.rohd.json',
              canvasKey: canvasKey,
              engine: engine,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();

      final block = engine.layouts.single.instances.firstWhere(
        (instance) => instance.hasHiddenNonPrimitiveChildren,
      );
      final canvasState = canvasKey.currentState!;
      const iconSize = 20.0;
      const iconPadding = iconSize * 0.4;
      const gap = iconSize * 0.15;
      final rightX = block.x + block.width - iconPadding - iconSize / 2;
      final nonPrimitivePosition = Offset(
        rightX - iconSize - gap,
        block.y + iconPadding + iconSize / 2,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(
        nonPrimitivePosition * canvasState.currentScale +
            canvasState.currentOffset,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(engine.elkGraphs, hasLength(2));
      expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
      expect(
        engine.layouts.last.instances.where((instance) => instance.isExpanded),
        hasLength(greaterThan(1)),
      );
    },
  );

  testWidgets('collapses selected FilterBank wires from the canvas menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasChildren,
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    final expandPosition = Offset(
      block.x + block.width - iconPadding - iconSize / 2,
      block.y + iconPadding + iconSize / 2,
    );
    await tester.tapAt(
      expandPosition * canvasState.currentScale + canvasState.currentOffset,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    Offset midpointOnDrawableSegment(SchematicEdgeData edge) {
      for (var index = 2; index < edge.points.length - 1; index++) {
        final start = edge.points[index];
        final end = edge.points[index + 1];
        if ((start.y - end.y).abs() <= 1 && (start.x - end.x).abs() > 1) {
          return Offset((start.x + end.x) / 2, (start.y + end.y) / 2);
        }
      }
      throw StateError('Expected a drawable projected edge segment');
    }

    final firstEdge = engine.layouts.last.edges.firstWhere(
      (edge) => edge.points.length >= 4,
    );
    final secondEdge = engine.layouts.last.edges.firstWhere(
      (edge) => edge.wireId != firstEdge.wireId && edge.points.length >= 4,
    );
    final firstPosition = midpointOnDrawableSegment(firstEdge);
    final secondPosition = midpointOnDrawableSegment(secondEdge);
    final firstScreenPosition =
        firstPosition * canvasState.currentScale + canvasState.currentOffset;
    final secondScreenPosition =
        secondPosition * canvasState.currentScale + canvasState.currentOffset;

    await tester.tapAt(firstScreenPosition);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(secondScreenPosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.tapAt(
      firstScreenPosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.text('Collapse 2 Signals'), findsOneWidget);

    final graphBeforeCollapse = engine.elkGraphs.last;
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('collapse');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(engine.elkGraphs, hasLength(4));
    expect(engine.elkGraphs.last, isNot(equals(graphBeforeCollapse)));
    expect(find.text('Collapse 2 Signals'), findsNothing);
  });

  testWidgets('sends a selected FilterBank wire through cross-probe', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();
    List<String>? sentSignals;

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            onSendSignals: (signals) => sentSignals = signals,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.hasChildren,
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    final expandPosition = Offset(
      block.x + block.width - iconPadding - iconSize / 2,
      block.y + iconPadding + iconSize / 2,
    );
    await tester.tapAt(
      expandPosition * canvasState.currentScale + canvasState.currentOffset,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final edge = engine.layouts.last.edges.firstWhere(
      (candidate) => candidate.points.length >= 4,
    );
    final start = edge.points[2];
    final end = edge.points[3];
    final wirePosition = Offset((start.x + end.x) / 2, (start.y + end.y) / 2);
    final screenPosition =
        wirePosition * canvasState.currentScale + canvasState.currentOffset;

    await tester.tapAt(screenPosition);
    await tester.tapAt(
      screenPosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.text('Send Signal'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('send');
    await tester.pump();

    expect(sentSignals, ['${edge.scopeHierarchyPath}/${edge.wireId}']);
  });

  testWidgets(
      'resolves go-to-source module by definition name for a nested '
      'instance whose cell name differs from its module type', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();
    RohdSourceFormat? selectedFormat;
    List<String>? selectedPaths;

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            onGoToSource: (format, paths) {
              selectedFormat = format;
              selectedPaths = paths;
            },
            availableSourceFormats: () => const [
              RohdSourceFormat.rohd,
              RohdSourceFormat.sv,
            ],
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    // "ch0" is a FilterBank cell instance of module type
    // "FilterChannel_T3_W16_0" — its cell/instance name differs from its
    // module type, exercising the case where cross-probe previously sent
    // the (wrong) instance name instead of the module type.
    final block = engine.layouts.single.instances.firstWhere(
      (instance) => instance.definitionName == 'FilterChannel_T3_W16_0',
    );
    final canvasState = canvasKey.currentState!;
    const iconSize = 20.0;
    const iconPadding = iconSize * 0.4;
    final expandPosition = Offset(
      block.x + block.width - iconPadding - iconSize / 2,
      block.y + iconPadding + iconSize / 2,
    );
    await tester.tapAt(
      expandPosition * canvasState.currentScale + canvasState.currentOffset,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final edge = engine.layouts.last.edges.firstWhere(
      (candidate) =>
          candidate.points.length >= 4 &&
          candidate.scopeHierarchyPath == block.hierarchyPath,
    );
    final start = edge.points[2];
    final end = edge.points[3];
    final wirePosition = Offset((start.x + end.x) / 2, (start.y + end.y) / 2);
    final screenPosition =
        wirePosition * canvasState.currentScale + canvasState.currentOffset;

    await tester.tapAt(screenPosition);
    await tester.tapAt(
      screenPosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.textContaining('ROHD'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas)))
        .pop(gotoSourceMenuValue(RohdSourceFormat.rohd));
    await tester.pump();

    expect(selectedFormat, RohdSourceFormat.rohd);
    // Must use the module *type* ("FilterChannel_T3_W16_0"), not the cell
    // instance name ("ch0"), since FLC/embedded-trace lookups are keyed by
    // module type.
    expect(selectedPaths, ['FilterChannel_T3_W16_0/${edge.wireId}']);
  });

  testWidgets('receives FilterBank signals through cross-probe', (
    tester,
  ) async {
    final incomingSignals = ValueNotifier<List<String>?>(null);
    addTearDown(incomingSignals.dispose);
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
            incomingSignalPaths: incomingSignals,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    incomingSignals.value = <String>[
      'FilterBank/ch0/dataOut',
      'FilterBank/ch0/validOut',
    ];
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(greaterThan(2)));
    expect(
      engine.layouts.last.edges.map((edge) => edge.wireId),
      containsAll(<String>['dataOut', 'validOut']),
    );
  });

  testWidgets('receives top-rooted signals while viewing a lower-level scope', (
    tester,
  ) async {
    final incomingSignals = ValueNotifier<List<String>?>(null);
    addTearDown(incomingSignals.dispose);
    (String, String)? expansionRequest;
    final layout = SchematicLayoutResult(
      instances: [
        SchematicInstanceData(
          id: 'ch0',
          x: 20,
          y: 20,
          width: 800,
          height: 600,
          name: 'ch0',
          hierarchyPath: 'FilterBank/ch0',
        ),
      ],
      ports: const [],
      edges: const [],
      width: 840,
      height: 640,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchematicCanvas(
            layout: layout,
            incomingSignalPaths: incomingSignals,
            onExpandWire: (scopeId, wireName) async {
              expansionRequest = (scopeId, wireName);
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    incomingSignals.value = ['FilterBank/ch0/dataOut'];
    await tester.pump();
    await tester.pump();

    expect(expansionRequest, ('ch0', 'dataOut'));
  });

  testWidgets('expands and collapses a marked FilterBank port', (tester) async {
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            requiresConnectivity: true,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialLayout = engine.layouts.single;
    final port = initialLayout.ports.firstWhere(
      (candidate) => initialLayout.interiorHiddenPortIds.contains(candidate.id),
    );

    Offset interiorMarkerPosition(SchematicPortData candidate) =>
        switch (candidate.side) {
          'WEST' => Offset(
              candidate.x + candidate.width + 3,
              candidate.y + candidate.height / 2,
            ),
          'EAST' => Offset(candidate.x - 3, candidate.y + candidate.height / 2),
          'NORTH' => Offset(
              candidate.x + candidate.width / 2,
              candidate.y + candidate.height + 3,
            ),
          _ => Offset(candidate.x + candidate.width / 2, candidate.y - 3),
        };
    final canvasState = canvasKey.currentState!;
    final screenPosition =
        interiorMarkerPosition(port) * canvasState.currentScale +
            canvasState.currentOffset;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(screenPosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(engine.layouts.last.edges, isNotEmpty);

    final expandedPort = engine.layouts.last.ports.firstWhere(
      (candidate) => candidate.id == port.id,
    );
    final expandedScreenPosition =
        interiorMarkerPosition(expandedPort) * canvasState.currentScale +
            canvasState.currentOffset;
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        position: expandedScreenPosition,
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(expandedScreenPosition);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    expect(engine.layouts.last.interiorHiddenPortIds, contains(port.id));
  });

  testWidgets('recovers from rejected and invalid FilterBank port expansion', (
    tester,
  ) async {
    final hostKey = GlobalKey<_AssetViewerHostState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            key: hostKey,
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialLayout = engine.layouts.single;
    final port = initialLayout.ports.firstWhere(
      (candidate) => initialLayout.interiorHiddenPortIds.contains(candidate.id),
    );
    final hostState = hostKey.currentState!;

    final invalidExpansion = await hostState.expandPort(
      port.instanceId,
      'missing-filterbank-port',
    );

    expect(invalidExpansion, isNull);
    expect(hostState._isToggleIdle, isTrue);
    expect(engine.elkGraphs, hasLength(1));

    engine.nextResult = SchematicLayoutResult(
      instances: const [],
      ports: const [],
      edges: const [],
      width: 0,
      height: 0,
      error: 'simulated port layout rejection',
    );
    final rejectedExpansion = await hostState.expandPort(
      port.instanceId,
      port.id,
    );
    await tester.pump();
    expect(rejectedExpansion, isNull);
    expect(rejectedExpansion, isNull);
    expect(hostState._isToggleIdle, isTrue);
    expect(engine.elkGraphs, hasLength(2));
    expect(find.byType(SchematicCanvas), findsOneWidget);

    final recoveredExpansion = await hostState.expandPort(
      port.instanceId,
      port.id,
    );
    await tester.pump();
    expect(recoveredExpansion, isNotNull);
    expect(recoveredExpansion, isNotNull);
    expect(hostState._isToggleIdle, isTrue);
    expect(engine.elkGraphs, hasLength(3));
  });

  testWidgets('clicks a FilterBank port to expand and collapse one level', (
    tester,
  ) async {
    final canvasKey = GlobalKey<SchematicCanvasState>();
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            canvasKey: canvasKey,
            engine: engine,
            requiresConnectivity: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final initialLayout = engine.layouts.single;
    final port = initialLayout.ports.firstWhere(
      (candidate) => initialLayout.interiorHiddenPortIds.contains(candidate.id),
    );
    Offset interiorMarkerPosition(SchematicPortData candidate) =>
        switch (candidate.side) {
          'WEST' => Offset(
              candidate.x + candidate.width + 3,
              candidate.y + candidate.height / 2,
            ),
          'EAST' => Offset(candidate.x - 3, candidate.y + candidate.height / 2),
          'NORTH' => Offset(
              candidate.x + candidate.width / 2,
              candidate.y + candidate.height + 3,
            ),
          _ => Offset(candidate.x + candidate.width / 2, candidate.y - 3),
        };
    final canvasState = canvasKey.currentState!;
    final screenPosition =
        interiorMarkerPosition(port) * canvasState.currentScale +
            canvasState.currentOffset;

    await tester.tapAt(screenPosition);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(engine.layouts.last.edges, isNotEmpty);

    final expandedPort = engine.layouts.last.ports.firstWhere(
      (candidate) => candidate.id == port.id,
    );
    final expandedScreenPosition =
        interiorMarkerPosition(expandedPort) * canvasState.currentScale +
            canvasState.currentOffset;
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        position: expandedScreenPosition,
      ),
    );
    await tester.pump();
    await tester.tapAt(expandedScreenPosition);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(3));
    expect(engine.layouts.last.interiorHiddenPortIds, contains(port.id));
  });

  testWidgets(
    'shift-clicking ch1 output expands inward before marker detects internals',
    (tester) async {
      final canvasKey = GlobalKey<SchematicCanvasState>();
      final engine = _ProjectedLayoutEngine(hideInitialInteriorMarkers: true);

      await tester.pumpWidget(
        BlocProvider(
          create: (_) => SchematicThemeCubit(),
          child: MaterialApp(
            home: _AssetViewerHost(
              assetPath: 'assets/FilterBank.rohd.json',
              canvasKey: canvasKey,
              engine: engine,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();

      final initialLayout = engine.layouts.single;
      final ch1 = initialLayout.instances.firstWhere(
        (instance) =>
            instance.instanceName == 'ch1' ||
            instance.name.split(' (').first == 'ch1',
      );
      final port = initialLayout.ports.firstWhere(
        (candidate) =>
            candidate.instanceId == ch1.id &&
            candidate.name == 'dataOut' &&
            !initialLayout.interiorHiddenPortIds.contains(candidate.id) &&
            initialLayout.exteriorHiddenPortIds.contains(candidate.id),
      );

      final exteriorMarkerPosition = switch (port.side) {
        'WEST' => Offset(port.x + port.width - 3, port.y + port.height / 2),
        'EAST' => Offset(port.x + 3, port.y + port.height / 2),
        'NORTH' => Offset(port.x + port.width / 2, port.y + port.height - 3),
        _ => Offset(port.x + port.width / 2, port.y + 3),
      };
      final canvasState = canvasKey.currentState!;
      final screenPosition = exteriorMarkerPosition * canvasState.currentScale +
          canvasState.currentOffset;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(screenPosition);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(engine.elkGraphs, hasLength(2));
      expect(
        engine.layouts.last.exteriorHiddenPortIds,
        isNot(contains(port.id)),
      );
      expect(
        engine.layouts.last.interiorHiddenPortIds,
        isNot(contains(port.id)),
      );
    },
  );

  testWidgets('selects a FilterBank search result with batch expansion', (
    tester,
  ) async {
    final engine = _FakeLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

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

    expect(find.byType(WireSearchOverlay), findsNothing);
    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'FilterBank/ch1/mac');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsNothing);
    expect(engine.elkGraphs, hasLength(3));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs[1])));
  });

  testWidgets('expands a root FilterBank signal from search', (tester) async {
    final engine = _ProjectedLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'channelOut');
    await tester.pump();

    final result = find.ancestor(
      of: find.text('channelOut'),
      matching: find.byType(InkWell),
    );
    expect(result, findsWidgets);

    await tester.tap(result.first);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsNothing);
    expect(engine.elkGraphs, hasLength(2));
    expect(
      engine.layouts.last.edges.any((edge) => edge.wireId == 'channelOut'),
      isTrue,
    );
  });

  testWidgets('navigates FilterBank search results with the keyboard', (
    tester,
  ) async {
    final engine = _FakeLayoutEngine();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: engine,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'FilterBank/ch0');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'FilterBank/ch0/');

    await tester.enterText(find.byType(TextField), 'FilterBank/ch0/m');
    await tester.pump();

    final counter = find.byWidgetPredicate(
      (widget) => widget is Text && (widget.data?.startsWith('1/') ?? false),
    );
    expect(counter, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data?.startsWith('2/') ?? false),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(counter, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsNothing);
    expect(engine.elkGraphs, hasLength(2));
    expect(engine.elkGraphs.last, isNot(equals(engine.elkGraphs.first)));
  });

  testWidgets('opens wire search with the FilterBank canvas shortcut', (
    tester,
  ) async {
    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: _AssetViewerHost(
            assetPath: 'assets/FilterBank.rohd.json',
            engine: _FakeLayoutEngine(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not-a-real-filterbank-net');
    await tester.pump();

    expect(find.textContaining('No blocks or wires found'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byType(WireSearchOverlay), findsNothing);
  });
}

class _AssetViewerHost extends StatefulWidget {
  final String assetPath;
  final GlobalKey<SchematicCanvasState>? canvasKey;
  final SchematicLayoutEngine engine;
  final SchematicExpansionMode? expansionMode;
  final ValueNotifier<List<String>?>? incomingSignalPaths;
  final void Function(List<String> signalPaths)? onSendSignals;
  final ({String value, bool computed, String signalId})? Function(
    String wireName,
  )? signalValueLookup;
  final GoToSourceCallback? onGoToSource;
  final AvailableSourceFormats? availableSourceFormats;
  final bool requiresConnectivity;

  const _AssetViewerHost({
    required this.assetPath,
    required this.engine,
    this.canvasKey,
    this.expansionMode,
    this.incomingSignalPaths,
    this.onSendSignals,
    this.signalValueLookup,
    this.onGoToSource,
    this.availableSourceFormats,
    this.requiresConnectivity = false,
    super.key,
  });

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('assetPath', assetPath))
      ..add(
        DiagnosticsProperty<GlobalKey<SchematicCanvasState>?>(
          'canvasKey',
          canvasKey,
        ),
      )
      ..add(DiagnosticsProperty<SchematicLayoutEngine>('engine', engine))
      ..add(
        DiagnosticsProperty<SchematicExpansionMode?>(
          'expansionMode',
          expansionMode,
        ),
      )
      ..add(
        DiagnosticsProperty<ValueNotifier<List<String>?>?>(
          'incomingSignalPaths',
          incomingSignalPaths,
        ),
      )
      ..add(
        ObjectFlagProperty<void Function(List<String>)?>.has(
          'onSendSignals',
          onSendSignals,
        ),
      )
      ..add(
        ObjectFlagProperty<
            ({bool computed, String signalId, String value})? Function(
              String wireName,
            )?>.has('signalValueLookup', signalValueLookup),
      )
      ..add(
        ObjectFlagProperty<GoToSourceCallback?>.has(
          'onGoToSource',
          onGoToSource,
        ),
      )
      ..add(
        ObjectFlagProperty<AvailableSourceFormats?>.has(
          'availableSourceFormats',
          availableSourceFormats,
        ),
      )
      ..add(
        DiagnosticsProperty<bool>('requiresConnectivity', requiresConnectivity),
      );
  }

  @override
  State<_AssetViewerHost> createState() => _AssetViewerHostState();
}

class _AssetViewerHostState extends BaseSchematicViewerState<_AssetViewerHost> {
  bool _connectivityLoaded = false;

  bool get _isToggleIdle => !isToggling && pendingToggleNodeId == null;

  @override
  SchematicLayoutEngine createLayoutEngine() => widget.engine;

  @override
  void Function(List<String> signalPaths)? get onSendSignals =>
      widget.onSendSignals;

  @override
  ({String value, bool computed, String signalId})? Function(String wireName)?
      get signalValueLookup => widget.signalValueLookup;

  @override
  GoToSourceCallback? get onGoToSource => widget.onGoToSource;

  @override
  AvailableSourceFormats? get availableSourceFormats =>
      widget.availableSourceFormats;

  @override
  ValueNotifier<List<String>?>? get incomingSignalPaths =>
      widget.incomingSignalPaths;

  @override
  bool get hasExternalSignalListeners => widget.onSendSignals != null;

  @override
  bool needsConnectivity(String nodeId) =>
      widget.requiresConnectivity && !_connectivityLoaded;

  @override
  Future<bool> ensureConnectivity(String nodeId) async {
    if (!widget.requiresConnectivity) {
      return false;
    }
    _connectivityLoaded = true;
    return true;
  }

  @override
  void loadInitialSchematic() {
    unawaited(_loadFixture());
  }

  Future<void> _loadFixture() async {
    final json = File(widget.assetPath).readAsStringSync();
    setFileName(widget.assetPath);
    await computeLayout(json, expansionMode: widget.expansionMode);
  }

  Future<SchematicLayoutResult?> expandFirstFilterBankNode() {
    final node = schematicAdapter!.schematic.nodeMap.values.firstWhere(
      (candidate) => candidate.isExpandable,
    );
    return handleNodeToggle(node.id);
  }

  Future<SchematicLayoutResult?> convertToBlocksOnly(String nodeId) =>
      handleConvertToBlocksOnly(nodeId);

  Future<SchematicLayoutResult?> collapsePartial(String nodeId) =>
      handleCollapsePartial(nodeId);

  Future<SchematicLayoutResult?> expandPort(String nodeId, String portId) =>
      handlePortExpand(nodeId, portId);

  Future<SchematicLayoutResult?> collapsePort(String nodeId, String portId) =>
      handlePortCollapse(nodeId, portId);

  Future<SchematicLayoutResult?> collapsePortThrough(
    String nodeId,
    String portId,
  ) =>
      handlePortCollapseThrough(nodeId, portId);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: isLoading
            ? buildLoadingIndicator()
            : error != null
                ? buildErrorDisplay()
                : buildSchematicCanvas(canvasKey: widget.canvasKey),
      );
}

class _FakeLayoutEngine implements SchematicLayoutEngine {
  final List<String> elkGraphs = <String>[];
  final SchematicLayoutResult? result;
  final Exception? exception;

  _FakeLayoutEngine({this.result, this.exception});

  @override
  bool get isAvailable => true;

  @override
  SchematicDependencyStatus checkDependencies() =>
      SchematicDependencyStatus.fromJson(const {'elk': true});

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) async {
    elkGraphs.add(elkGraphJson);
    final exception = this.exception;
    if (exception != null) {
      throw exception;
    }
    return result ??
        SchematicLayoutResult(
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

class _ProjectedLayoutEngine implements SchematicLayoutEngine {
  final List<String> elkGraphs = <String>[];
  final List<SchematicLayoutResult> layouts = <SchematicLayoutResult>[];
  final bool hideInitialInteriorMarkers;
  final bool variedPortSides;
  SchematicLayoutResult? nextResult;

  _ProjectedLayoutEngine({
    this.hideInitialInteriorMarkers = false,
    this.variedPortSides = false,
  });

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
    final result = nextResult;
    if (result != null) {
      nextResult = null;
      return result;
    }
    final graph = jsonDecode(elkGraphJson) as Map<String, dynamic>;
    _projectNode(graph, 0, 0);
    _projectEdges(graph);
    final extracted = ElkLayoutExtractor.extract(graph);
    final layout = hideInitialInteriorMarkers && layouts.isEmpty
        ? SchematicLayoutResult(
            instances: extracted.instances,
            ports: extracted.ports,
            edges: extracted.edges,
            width: extracted.width,
            height: extracted.height,
            error: extracted.error,
            exteriorHiddenPortIds: extracted.exteriorHiddenPortIds,
            interiorHiddenPortIds: const {},
            unconnectedPortIds: extracted.unconnectedPortIds,
            interiorUnconnectedPortIds: extracted.interiorUnconnectedPortIds,
          )
        : extracted;
    layouts.add(layout);
    return layout;
  }

  void _projectNode(Map<String, dynamic> node, double x, double y) {
    node
      ..['x'] = x
      ..['y'] = y
      ..['width'] = 260.0
      ..['height'] = 180.0;

    final ports = node['ports'];
    if (ports is List) {
      for (var index = 0; index < ports.length; index++) {
        final port = ports[index] as Map<String, dynamic>;
        final properties =
            (port['properties'] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        final side = variedPortSides
            ? const ['WEST', 'EAST', 'NORTH', 'SOUTH'][index % 4]
            : properties['side'];
        properties['side'] = side;
        if (side == 'NORTH' || side == 'SOUTH') {
          port
            ..['x'] = 28.0 + index * 18.0
            ..['y'] = side == 'NORTH' ? 0.0 : 173.0
            ..['width'] = 13.0
            ..['height'] = 7.0;
        } else {
          port
            ..['x'] = side == 'WEST' ? 0.0 : 253.0
            ..['y'] = 28.0 + index * 18.0
            ..['width'] = 7.0
            ..['height'] = 13.0;
        }
      }
    }

    final children = node['children'];
    if (children is List) {
      for (var index = 0; index < children.length; index++) {
        _projectNode(
          children[index] as Map<String, dynamic>,
          40.0 + (index % 3) * 300.0,
          60.0 + (index ~/ 3) * 240.0,
        );
      }
    }

    node['width'] =
        children is List && children.isNotEmpty ? 1000.0 : node['width'];
    node['height'] =
        children is List && children.isNotEmpty ? 800.0 : node['height'];
  }

  void _projectEdges(Map<String, dynamic> node) {
    final portLocations = <String, Offset>{};
    void addPorts(Map<String, dynamic> owner, Offset offset) {
      final ports = owner['ports'];
      if (ports is List) {
        for (final port in ports) {
          if (port is! Map<String, dynamic>) {
            continue;
          }
          final id = port['id'];
          if (id is! String) {
            continue;
          }
          final x = (port['x'] as num?)?.toDouble() ?? 0.0;
          final y = (port['y'] as num?)?.toDouble() ?? 0.0;
          final width = (port['width'] as num?)?.toDouble() ?? 0.0;
          final height = (port['height'] as num?)?.toDouble() ?? 0.0;
          portLocations[id] = offset + Offset(x + width / 2, y + height / 2);
        }
      }

      final children = owner['children'];
      if (children is List) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            final x = (child['x'] as num?)?.toDouble() ?? 0.0;
            final y = (child['y'] as num?)?.toDouble() ?? 0.0;
            addPorts(child, offset + Offset(x, y));
          }
        }
      }
    }

    addPorts(node, Offset.zero);
    final children = node['children'];
    final edges = node['edges'];
    if (edges is List) {
      for (var index = 0; index < edges.length; index++) {
        final edge = edges[index];
        if (edge is! Map<String, dynamic>) {
          continue;
        }
        final source = portLocations[edge['sourcePort']];
        final target = portLocations[edge['targetPort']];
        if (source == null || target == null) {
          continue;
        }
        final laneX = (source.dx + target.dx) / 2 + 24 + (index % 5) * 28;
        final laneY = 24.0 + (index % 4) * 34;
        edge['sections'] = [
          {
            'startPoint': {'x': source.dx, 'y': source.dy},
            'bendPoints': [
              {'x': laneX, 'y': source.dy},
              {'x': laneX, 'y': laneY},
              {'x': target.dx, 'y': laneY},
            ],
            'endPoint': {'x': target.dx, 'y': target.dy},
          },
        ];
      }
    }

    if (children is List) {
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          _projectEdges(child);
        }
      }
    }
  }

  @override
  void dispose() {}
}

class _PortOrientationLayoutEngine implements SchematicLayoutEngine {
  final bool showMarkers;
  final List<String> elkGraphs = <String>[];
  late final SchematicLayoutResult layout = _createLayout(showMarkers);

  _PortOrientationLayoutEngine({this.showMarkers = true});

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
    return layout;
  }

  static SchematicLayoutResult _createLayout(bool showMarkers) {
    const moduleX = 180.0;
    const moduleY = 140.0;
    const moduleWidth = 520.0;
    const moduleHeight = 420.0;
    const sides = <String>['WEST', 'EAST', 'NORTH', 'SOUTH'];
    const directions = <String>['INPUT', 'OUTPUT', 'INOUT'];
    final ports = <SchematicPortData>[];

    for (var directionIndex = 0;
        directionIndex < directions.length;
        directionIndex++) {
      for (var sideIndex = 0; sideIndex < sides.length; sideIndex++) {
        final side = sides[sideIndex];
        final id = '${directions[directionIndex]}_$side';
        final lane = 85.0 + directionIndex * 105.0;
        final (x, y, width, height) = switch (side) {
          'WEST' => (moduleX - 7, moduleY + lane, 7.0, 13.0),
          'EAST' => (moduleX + moduleWidth, moduleY + lane, 7.0, 13.0),
          'NORTH' => (moduleX + lane, moduleY - 7, 13.0, 7.0),
          'SOUTH' => (moduleX + lane, moduleY + moduleHeight, 13.0, 7.0),
          _ => throw StateError('Unexpected port side $side'),
        };
        ports.add(
          SchematicPortData.fromJson({
            'id': id,
            'nodeId': 'FilterBank/oriented_ports',
            'x': x,
            'y': y,
            'width': width,
            'height': height,
            'name': id.toLowerCase(),
            'direction': directions[directionIndex],
            'side': side,
            'signalWidth': directionIndex + 1,
          }),
        );
      }
    }

    final edges = <SchematicEdgeData>[];
    for (var index = 0; index < sides.length; index++) {
      final sourcePort = ports[4 + index];
      final targetPort = ports[(index + 2) % sides.length];
      final source = _portBoundary(sourcePort);
      final target = _portBoundary(targetPort);
      final junction = SchematicPoint(
        (source.dx + target.dx) / 2,
        (source.dy + target.dy) / 2,
      );
      edges.add(
        SchematicEdgeData.fromJson({
          'id': 'routed_bus_$index',
          'source': 'FilterBank/oriented_ports',
          'sourcePort': sourcePort.id,
          'target': 'FilterBank/oriented_ports',
          'targetPort': targetPort.id,
          'points': [
            {'x': source.dx, 'y': source.dy},
            {'x': junction.x, 'y': source.dy},
            {'x': junction.x, 'y': junction.y},
            {'x': target.dx, 'y': junction.y},
            {'x': target.dx, 'y': target.dy},
          ],
          'junctionPoints': [
            {'x': junction.x, 'y': junction.y},
          ],
          'dots': [
            {'x': junction.x, 'y': junction.y},
          ],
          'name': 'filter_bus_$index',
          'parentName': 'filter_bus_$index',
          'cssClass': 'bus',
          'signalWidth': 8,
          'scopeHierarchyPath': 'FilterBank/oriented_ports',
        }),
      );
    }

    final markerIds = ports.map((port) => port.id).toSet();
    return SchematicLayoutResult(
      instances: [
        SchematicInstanceData.fromJson({
          'id': 'FilterBank',
          'x': 40,
          'y': 40,
          'width': 800,
          'height': 640,
          'name': 'FilterBank',
          'children': ['FilterBank/oriented_ports'],
          'hasChildren': true,
          'isExpanded': true,
          'hierarchyPath': 'FilterBank',
        }),
        SchematicInstanceData.fromJson({
          'id': 'FilterBank/oriented_ports',
          'x': moduleX,
          'y': moduleY,
          'width': moduleWidth,
          'height': moduleHeight,
          'name': 'oriented_ports',
          'bodyText': 'FilterBank port orientation\nand routed bus fixture',
          'children': <String>[],
          'hasChildren': true,
          'isExpanded': true,
          'isPartiallyExpanded': true,
          'hasHiddenNonPrimitiveChildren': true,
          'hasNonPrimitiveChildren': true,
          'hierarchyPath': 'FilterBank/oriented_ports',
        }),
        SchematicInstanceData.fromJson({
          'id': 'external_status',
          'x': 735,
          'y': 260,
          'width': 90,
          'height': 35,
          'name': 'external_status',
          'isExternalPort': true,
          'cssClass': 'external-port',
          'portLabelWidth': 48,
          'hierarchyPath': 'FilterBank/external_status',
        }),
      ],
      ports: ports,
      edges: edges,
      width: 880,
      height: 720,
      exteriorHiddenPortIds: showMarkers ? markerIds : const {},
      interiorHiddenPortIds: showMarkers ? markerIds : const {},
      unconnectedPortIds: showMarkers ? markerIds : const {},
      interiorUnconnectedPortIds: showMarkers ? markerIds : const {},
    );
  }

  static Offset _portBoundary(SchematicPortData port) => switch (port.side) {
        'WEST' => Offset(port.x + port.width, port.y + port.height / 2),
        'EAST' => Offset(port.x, port.y + port.height / 2),
        'NORTH' => Offset(port.x + port.width / 2, port.y + port.height),
        'SOUTH' => Offset(port.x + port.width / 2, port.y),
        _ => throw StateError('Unexpected port side ${port.side}'),
      };

  @override
  void dispose() {}
}
