// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// flutter_schematic_viewer_page_test.dart
// Extension viewer tests with deterministic host dependencies.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show AppBarOverlay;
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_extension_client.dart'
    show RohdExtensionClient, RohdFormatInfo, RohdModuleInfo, RohdSourceFormat;
import 'package:rohd_schematic_viewer/src/ui/flutter_schematic_viewer_page.dart';

void main() {
  testWidgets(
    'loads and reloads injected FilterBank data in the extension page',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final engine = _RecordingLayoutEngine();

      await tester.pumpWidget(
        BlocProvider(
          create: (_) => SchematicThemeCubit(),
          child: MaterialApp(
            home: FlutterSchematicViewerPage(
              initialSchematicJson:
                  File('assets/FilterBank.rohd.json').readAsStringSync(),
              layoutEngine: engine,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SchematicCanvas), findsOneWidget);
      expect(engine.elkGraphs, hasLength(1));
      expect(engine.elkGraphs.single, contains('FilterBank'));
      expect(find.byTooltip('Unpin top bar'), findsOneWidget);
      expect(
        tester.widget<AppBarOverlay>(find.byType(AppBarOverlay)).autoHide,
        isFalse,
      );
      final canvasState = tester.state<SchematicCanvasState>(
        find.byType(SchematicCanvas),
      );
      const preservedOffset = Offset(180, 120);
      canvasState.setView(offset: preservedOffset, scale: 1.75);
      final anchorBeforeToggle = _schematicAnchor(tester, canvasState);

      await tester.tap(find.byTooltip('Unpin top bar'));
      await tester.pump();

      expect(find.byTooltip('Pin top bar'), findsOneWidget);
      expect(
        tester.widget<AppBarOverlay>(find.byType(AppBarOverlay)).autoHide,
        isTrue,
      );
      expect(canvasState.currentScale, 1.75);
      expect(_schematicAnchor(tester, canvasState), anchorBeforeToggle);

      await tester.tap(find.byTooltip('Pin top bar'));
      await tester.pump();

      expect(canvasState.currentScale, 1.75);
      expect(canvasState.currentOffset, preservedOffset);
      expect(_schematicAnchor(tester, canvasState), anchorBeforeToggle);

      await tester.tap(find.byTooltip('Reload current schematic'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(engine.elkGraphs, hasLength(2));
      expect(engine.elkGraphs.last, equals(engine.elkGraphs.first));
    },
  );

  testWidgets('handles FilterBank updates from an extension host', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final engine = _RecordingLayoutEngine();
    final host = _FakeExtensionHost();
    final client = _FakeExtensionClient();
    final filterBankJson =
        File('assets/FilterBank.rohd.json').readAsStringSync();

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: FlutterSchematicViewerPage(
            initialSchematicJson: filterBankJson,
            layoutEngine: engine,
            extensionHost: host.asHost(),
            extensionClient: client,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(client.pingCount, 1);
    expect(client.queriedModules, ['FilterBank']);
    expect(host.readyNotifications, 1);

    await tester.tap(find.byTooltip('Reload current schematic'));
    await tester.pump();
    expect(host.reloadRequests, 1);

    host.emitReload(filterBankJson);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(engine.elkGraphs, hasLength(2));
    expect(client.queriedModules, ['FilterBank', 'FilterBank']);

    host.emitError('disk unavailable');
    await tester.pump();

    expect(find.text('Error'), findsOneWidget);
    expect(
      find.textContaining('Reload failed: disk unavailable'),
      findsOneWidget,
    );

    host.emitReload(filterBankJson);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(engine.elkGraphs, hasLength(3));
  });

  testWidgets('navigates FilterBank signal source from the extension canvas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final engine = _RecordingLayoutEngine();
    final host = _FakeExtensionHost();
    final client = _FakeExtensionClient()
      ..frames = [
        {'file': '/workspace/filter_bank.dart', 'line': 42, 'col': 3},
      ];

    await tester.pumpWidget(
      BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: MaterialApp(
          home: FlutterSchematicViewerPage(
            initialSchematicJson:
                File('assets/FilterBank.rohd.json').readAsStringSync(),
            layoutEngine: engine,
            extensionHost: host.asHost(),
            extensionClient: client,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    final canvasState = tester.state<SchematicCanvasState>(
      find.byType(SchematicCanvas),
    );
    final localWirePosition =
        const Offset(500, 300) * canvasState.currentScale +
            canvasState.currentOffset;
    final wirePosition =
        (tester.renderObject(find.byType(SchematicCanvas)) as RenderBox)
                .localToGlobal(localWirePosition) +
            const Offset(0, 8);
    await tester.tapAt(wirePosition);
    await tester.pump();
    await tester.tapAt(
      wirePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.text('Go to ROHD Source'), findsOneWidget);
    expect(find.text('Go to SV Source'), findsOneWidget);
    expect(find.text('Send Signal'), findsNothing);

    Navigator.of(tester.element(find.byType(SchematicCanvas)))
        .pop('goto_source:rohd');
    await tester.pump();
    await tester.pump();

    expect(client.lookupRequests.single.format, 'rohd');
    expect(client.lookupRequests.single.signals, [
      {'module': 'FilterBank', 'name': 'dataOut'},
    ]);
    expect(client.openedLocations.single, (
      file: '/workspace/filter_bank.dart',
      line: 42,
      col: 3,
    ));

    client.frames = [
      {'file': '/workspace/filter_bank.dart', 'line': 42, 'col': 3},
      {
        'file': '/workspace/filter_bank.sv',
        'line': 87,
        'col': 1,
        'desc': 'generated output',
      },
    ];
    await tester.tapAt(
      wirePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(SchematicCanvas)))
        .pop('goto_source:sv');
    await tester.pump();
    await tester.pump();

    expect(find.text('filter_bank.dart:42'), findsOneWidget);
    expect(find.text('filter_bank.sv:87  generated output'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop(1);
    await tester.pump();
    await tester.pump();

    expect(client.openedLocations.last, (
      file: '/workspace/filter_bank.sv',
      line: 87,
      col: 1,
    ));

    host.emitSignalViewerAvailability(canSendSignals: true);
    await tester.pump();
    await tester.tapAt(
      wirePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.text('Send Signal'), findsOneWidget);
    Navigator.of(tester.element(find.byType(SchematicCanvas))).pop('send');
    await tester.pump();
    expect(host.sentSignalPaths, [
      ['FilterBank/dataOut'],
    ]);

    client.frames = const [];
    await tester.tapAt(
      wirePosition,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(SchematicCanvas)))
        .pop('goto_source:rohd');
    await tester.pump();
    await tester.pump();

    expect(find.text('No source locations found'), findsOneWidget);
  });
}

Offset _schematicAnchor(WidgetTester tester, SchematicCanvasState canvasState) {
  final canvasBox =
      tester.renderObject(find.byType(SchematicCanvas)) as RenderBox;
  const schematicPoint = Offset(100, 80);
  return canvasBox.localToGlobal(
    schematicPoint * canvasState.currentScale + canvasState.currentOffset,
  );
}

class _FakeExtensionHost {
  late void Function(String jsonData) _onReload;
  void Function(String error)? _onError;
  void Function({required bool canSendSignals})? _onSignalViewerAvailability;
  int reloadRequests = 0;
  int readyNotifications = 0;
  final List<List<String>> sentSignalPaths = [];

  FlutterSchematicExtensionHost asHost() => FlutterSchematicExtensionHost(
        isWebview: true,
        requestReload: () {
          reloadRequests++;
          return true;
        },
        listenForMessages: ({
          required onReload,
          onError,
          onSignalViewerAvailability,
          onIncomingSignals,
        }) {
          _onReload = onReload;
          _onError = onError;
          _onSignalViewerAvailability = onSignalViewerAvailability;
        },
        notifySignalViewerReady: () {
          readyNotifications++;
          return true;
        },
        sendSignals: ({required signalPaths}) {
          sentSignalPaths.add(signalPaths);
          return true;
        },
      );

  void emitReload(String jsonData) => _onReload(jsonData);

  void emitError(String error) => _onError!(error);

  void emitSignalViewerAvailability({required bool canSendSignals}) =>
      _onSignalViewerAvailability!(canSendSignals: canSendSignals);
}

class _FakeExtensionClient implements RohdExtensionClient {
  @override
  final ValueNotifier<bool> isAvailable = ValueNotifier<bool>(true);

  @override
  final ValueNotifier<RohdModuleInfo?> currentModuleInfo =
      ValueNotifier<RohdModuleInfo?>(null);

  int pingCount = 0;
  final List<String> queriedModules = <String>[];
  List<Map<String, dynamic>> frames = const [];
  final List<({String format, List<Map<String, String>> signals})>
      lookupRequests = [];
  final List<({String file, int line, int col})> openedLocations = [];

  @override
  Future<bool> ping() async {
    pingCount++;
    return true;
  }

  @override
  Future<RohdModuleInfo> queryModule(
    String module, {
    List<String>? instancePath,
  }) async {
    queriedModules.add(module);
    const info = RohdModuleInfo(
      extensionAvailable: true,
      formats: {
        RohdSourceFormat.rohd: RohdFormatInfo(available: true, fileFound: true),
        RohdSourceFormat.sv: RohdFormatInfo(available: true, fileFound: true),
      },
    );
    currentModuleInfo.value = info;
    return info;
  }

  @override
  Future<List<Map<String, dynamic>>> lookupSignalFrames({
    required List<Map<String, String>> signals,
    String? format,
  }) async {
    lookupRequests.add((format: format ?? '', signals: signals));
    return frames;
  }

  @override
  void openSourceLocation({
    required String file,
    required int line,
    int col = 0,
  }) {
    openedLocations.add((file: file, line: line, col: col));
  }

  @override
  void dispose() {
    isAvailable.dispose();
    currentModuleInfo.dispose();
  }
}

class _RecordingLayoutEngine implements SchematicLayoutEngine {
  final List<String> elkGraphs = <String>[];

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
          width: 1000,
          height: 800,
          name: 'FilterBank',
          hasChildren: true,
          isExpanded: true,
          hierarchyPath: 'FilterBank',
        ),
      ],
      ports: const [],
      edges: [
        SchematicEdgeData(
          id: 'dataOut',
          name: 'dataOut',
          points: [SchematicPoint(200, 300), SchematicPoint(800, 300)],
          scopeHierarchyPath: 'FilterBank',
        ),
      ],
      width: 1040,
      height: 840,
    );
  }

  @override
  void dispose() {}
}
