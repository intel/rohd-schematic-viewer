// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// indexed_file_viewer_test.dart
// Hierarchy-first file startup and on-demand expansion regression tests.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

// Test harness properties are inspected directly.
// ignore_for_file: diagnostic_describe_all_properties

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';
import 'package:rohd_schematic_viewer/src/services/indexed_netlist_loader.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';

Map<String, dynamic> _module(String type, {bool top = false}) => {
      'attributes': {if (top) 'top': 1},
      'ports': {
        'a': {
          'direction': 'input',
          'bits': [2]
        },
        'z': {
          'direction': 'output',
          'bits': [3]
        },
      },
      'cells': <String, dynamic>{
        'child': {
          'type': type,
          'port_directions': {'a': 'input', 'z': 'output'},
          'connections': {
            'a': [2],
            'z': [3]
          },
        },
      },
      'netnames': {
        'a': {
          'bits': [2]
        },
        'z': {
          'bits': [3]
        },
      },
    };

void main() {
  late _Source source;
  late GlobalKey<_ViewerState> key;

  setUp(() {
    source = _Source(jsonEncode({
      'modules': {
        'Top': _module('Child', top: true),
        'Child': _module('Grandchild'),
        'Grandchild': _module(r'$buf'),
        'Unrelated': _module(r'$not'),
      },
    }));
    key = GlobalKey<_ViewerState>();
  });

  Future<_ViewerState> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key)),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  Future<void> toggle(
    WidgetTester tester,
    _ViewerState state,
    String nodeId, {
    bool recursive = false,
  }) async {
    final action = recursive
        ? state.handleNodeToggleRecursive(nodeId)
        : state.handleNodeToggle(nodeId);
    await tester.pumpAndSettle();
    await action;
  }

  testWidgets('disk startup completes hierarchy-only before calling layout',
      (tester) async {
    await tester.runAsync(() async {
      final localFile = Platform.environment['NETLIST_TEST_FILE'] ?? '';
      final String path;
      if (localFile.isEmpty) {
        final directory =
            await Directory.systemTemp.createTemp('indexed-startup-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/netlist.json');
        await file.writeAsString(jsonEncode({
          'modules': {
            'Top': _module('Child', top: true),
            'Child': _module(r'$buf'),
          },
        }));
        path = file.path;
      } else {
        path = localFile;
      }
      final disk = _ReadTrackingSource(FileNetlistByteSource(XFile(path)));
      final clock = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(home: _Viewer(source: disk, key: key)),
      );
      final state = key.currentState!;
      while (state.loading && clock.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      expect(state.loading, isFalse, reason: 'Startup must finish, not spin');
      expect(state.errorMessage, isNull);
      expect(disk.reads, [(0, null)],
          reason: 'Startup must not request any module connectivity');
      expect(state.rendered.instances, isNotEmpty);
      expect(state.loadingMessages, contains('Building hierarchy...'));
      expect(state.loadingMessages, contains('Preparing initial layout...'));
      expect(state.loadingMessages, contains('Computing initial layout...'));
      expect(state.loadingMessages.any((m) => m.startsWith('Indexing netlist')),
          isTrue);
      final modules = (jsonDecode(state.currentJson)
          as Map<String, dynamic>)['modules'] as Map<String, dynamic>;
      for (final module in modules.values.cast<Map<String, dynamic>>()) {
        final cells = module['cells'] as Map<String, dynamic>? ?? {};
        expect(
            cells.values
                .cast<Map<String, dynamic>>()
                .every((cell) => !cell.containsKey('connections')),
            isTrue);
      }
      // A caller can profile its own local file without checking it in.
      debugPrint('Hierarchy-only disk startup: '
          '${clock.elapsedMilliseconds} ms; '
          '${state.adapter.schematic.nodeMap.length} nodes; '
          '${disk.reads.length} streaming scan(s)');
    });
  });

  testWidgets('a stalled file read keeps a shareable phase heartbeat',
      (tester) async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      logs.add(message ?? '');
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };
    try {
      source.pause = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(home: _Viewer(source: source, key: key)),
      );
      expect(find.textContaining('Indexing netlist'), findsOneWidget);
      expect(logs.any((m) => m.contains('[bounded-reader-v2]')), isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(
          logs.any((m) =>
              m.contains('[FileLoad]') &&
              m.contains('Still waiting: Indexing netlist') &&
              m.contains('Waiting for source bytes')),
          isTrue);
      expect(find.textContaining('Elapsed:'), findsOneWidget);
      source.pause!.complete();
      await tester.pumpAndSettle();
      expect(key.currentState!.loading, isFalse);
      expect(key.currentState!.errorMessage, isNull);
      expect(logs.any((m) => m.contains('Startup complete')), isTrue);
    } finally {
      debugPrint = originalDebugPrint;
    }
  });

  for (final stage in ['size', 'timestamp']) {
    testWidgets('a stalled file $stage reports an error instead of spinning',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: _Viewer(
            source: FileNetlistByteSource(_StalledMetadataFile(stage)),
            key: key,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(key.currentState!.loading, isFalse);
      expect(key.currentState!.errorMessage,
          contains('Timed out reading netlist file $stage'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a stalled read cannot hide its timeout behind cancellation',
      (tester) async {
    final file = _StalledReadFile();
    try {
      await tester.pumpWidget(MaterialApp(
        home: _Viewer(source: FileNetlistByteSource(file), key: key),
      ));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 2));
      expect(key.currentState!.loading, isFalse);
      expect(key.currentState!.errorMessage, contains('Timed out'));
      expect(tester.takeException(), isNull);
    } finally {
      file.cancellation.complete();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a read error is not hidden behind stalled cancellation',
      (tester) async {
    final file = _StalledReadFile(failImmediately: true);
    try {
      await tester.pumpWidget(MaterialApp(
        home: _Viewer(source: FileNetlistByteSource(file), key: key),
      ));
      await tester.pump(const Duration(seconds: 2));
      expect(key.currentState!.loading, isFalse);
      expect(
          key.currentState!.errorMessage, contains('Synthetic read failure'));
      expect(key.currentState!.errorMessage,
          contains('stream cancellation timed out'));
      expect(tester.takeException(), isNull);
    } finally {
      file.cancellation.complete();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('loads hierarchy only, enriches clicked levels, caches',
      (tester) async {
    final state = await mount(tester);
    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(state.hasConnections('Top'), isFalse);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isFalse);
    expect(state.adapter.schematic.nodeMap['0.0']!.slimConnectedPortIds,
        isNotEmpty);
    expect(
        state.adapter.schematic.nodeMap['0']!.partialChildIds, contains('0.0'));
    expect(state.adapter.schematic.nodeMap['0']!.hyperedges, isNull);
    final topSnapshot = state.adapter.schematic.expansionSnapshot();
    final hierarchy = state.adapter.hierarchy;
    final child = state.adapter.schematic.nodeMap['0.0'];

    await toggle(tester, state, '0.0');
    expect(state.errorMessage, isNull);
    expect(source.reads, hasLength(2));
    expect(state.hasConnections('Top'), isFalse);
    expect(state.hasConnections('Child'), isTrue);
    expect(state.hasConnections('Grandchild'), isFalse);
    expect(state.adapter.hierarchy, same(hierarchy));
    expect(state.adapter.schematic.nodeMap['0.0'], same(child));
    expect(state.adapter.schematic.nodeMap['0.0']!.hyperedges, isNotEmpty);
    expect(state.adapter.schematic.expansionSnapshot().partials.keys,
        containsAll(topSnapshot.partials.keys));

    await toggle(tester, state, '0.0');
    await toggle(tester, state, '0.0');
    expect(source.reads, hasLength(2));
  });

  testWidgets('hydrating a shared definition connects every occurrence',
      (tester) async {
    final top = _module('Child', top: true);
    final cells = top['cells'] as Map<String, dynamic>;
    cells['second'] = cells['child'];
    source = _Source(jsonEncode({
      'modules': {'Top': top, 'Child': _module(r'$buf')},
    }));
    final state = await mount(tester);
    await toggle(tester, state, '0.0');
    final sibling = state.adapter.schematic.nodeMap['0.1']!;
    expect(sibling.isExpanded, isFalse);
    expect(sibling.hyperedges, isNotEmpty);
    await toggle(tester, state, sibling.id);
    expect(state.errorMessage, isNull);
    expect(source.reads, hasLength(2)); // Initial scan + one definition.
  });

  testWidgets(
      'explores a small file design from overview through nested connectivity',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key, showCanvas: true)),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));

    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(
      canvas.layout.instances.map((instance) => instance.id),
      containsAll(['0', '0.0']),
    );

    Future<void> openInCanvas(String nodeId) async {
      canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
      final action = canvas.onNodeToggle!(nodeId);
      await tester.pumpAndSettle();
      await action;
      await tester.pumpAndSettle();
      canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    }

    await openInCanvas('0');
    expect(state.hasConnections('Top'), isTrue);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isFalse);
    expect(
      canvas.layout.instances.map((instance) => instance.id),
      contains('0.0'),
    );

    await openInCanvas('0.0');
    expect(state.hasConnections('Child'), isTrue);
    expect(state.hasConnections('Grandchild'), isFalse);
    expect(
      canvas.layout.instances.map((instance) => instance.id),
      contains('0.0.0'),
    );

    await openInCanvas('0.0.0');
    expect(state.hasConnections('Grandchild'), isTrue);
    expect(state.hasConnections('Unrelated'), isFalse);
    expect(canvas.layout.instances.length, greaterThan(2));
    expect(source.reads, hasLength(4));

    await openInCanvas('0.0');
    await openInCanvas('0.0');
    expect(source.reads, hasLength(4));
    expect(state.errorMessage, isNull);
  });

  testWidgets('traces an inverter input from its port and collapses it',
      (tester) async {
    source = _Source(jsonEncode({
      'modules': {
        'Inverter': {
          'attributes': {'top': 1},
          'ports': {
            'input': {
              'direction': 'input',
              'bits': [2],
            },
            'output': {
              'direction': 'output',
              'bits': [3],
            },
          },
          'cells': {
            'invert': {
              'type': r'$not',
              'parameters': {'A_WIDTH': 1, 'Y_WIDTH': 1},
              'port_directions': {'A': 'input', 'Y': 'output'},
              'connections': {
                'A': [2],
                'Y': [3],
              },
            },
          },
          'netnames': {
            'input': {
              'bits': [2],
            },
            'output': {
              'bits': [3],
            },
          },
        },
      },
    }));
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key, showCanvas: true)),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    final root = state.adapter.schematic.nodeMap['0']!;
    final input = root.elkPorts.singleWhere(
      (port) => port.hwMeta.name == 'input',
    );
    bool hasConnections() {
      final modules = (jsonDecode(state.currentJson)
          as Map<String, dynamic>)['modules'] as Map<String, dynamic>;
      final cells = (modules['Inverter'] as Map<String, dynamic>)['cells']
          as Map<String, dynamic>;
      return (cells['invert'] as Map<String, dynamic>)
          .containsKey('connections');
    }

    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(hasConnections(), isFalse);

    final expansion = canvas.onPortExpand!(root.id, input.id);
    await tester.pumpAndSettle();
    final expanded = await expansion;
    await tester.pumpAndSettle();
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));

    expect(expanded, isNotNull);
    expect(hasConnections(), isTrue);
    expect(source.reads, hasLength(2));
    expect(canvas.layout.instances.map((instance) => instance.id),
        contains('0.0'));

    final collapse = canvas.onPortCollapse!(root.id, input.id);
    await tester.pumpAndSettle();
    final collapsed = await collapse;
    await tester.pumpAndSettle();
    expect(collapsed, isNotNull);
    expect(state.rendered.instances.map((instance) => instance.id), ['0']);
    expect(source.reads, hasLength(2));

    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    final through = canvas.onPortExpandThrough!(root.id, input.id);
    await tester.pumpAndSettle();
    final expandedThrough = await through;
    await tester.pumpAndSettle();
    expect(expandedThrough, isNotNull);
    expect(state.rendered.instances.map((instance) => instance.id),
        contains('0.0'));

    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    final collapseThrough = canvas.onPortCollapseThrough!(root.id, input.id);
    await tester.pumpAndSettle();
    final collapsedThrough = await collapseThrough;
    await tester.pumpAndSettle();
    expect(collapsedThrough, isNotNull);
    expect(state.rendered.instances.map((instance) => instance.id), ['0']);
    expect(state.errorMessage, isNull);
  });

  testWidgets('opens a searched nested signal without loading sibling modules',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key, showCanvas: true)),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(source.reads, [(0, null)]);
    expect(state.hasConnections('Top'), isFalse);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isFalse);

    final canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    final navigation = canvas.onExpandPath!(
      ['child', 'child'],
      targetWireName: 'z',
    );
    await tester.pumpAndSettle();
    final result = await navigation;
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(state.errorMessage, isNull);
    expect(state.hasConnections('Top'), isFalse);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isTrue);
    expect(state.hasConnections('Unrelated'), isFalse);
    expect(source.reads, hasLength(2));
    expect(
      state.rendered.instances.map((instance) => instance.id),
      containsAll(['0', '0.0', '0.0.0']),
    );
  });

  testWidgets('reveals the searched top-level output without opening its block',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key, showCanvas: true)),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));

    expect(state.hasConnections('Top'), isFalse);
    final reveal = canvas.onExpandWire!('0', 'z');
    await tester.pumpAndSettle();
    final result = await reveal;
    await tester.pumpAndSettle();
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));

    expect(result, isNotNull);
    expect(state.errorMessage, isNull);
    expect(state.hasConnections('Top'), isTrue);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isFalse);
    expect(state.hasConnections('Unrelated'), isFalse);
    expect(source.reads, hasLength(2));
    expect(canvas.layout.instances.map((instance) => instance.id),
        containsAll(['0', '0.0']));
  });

  testWidgets('file expansion paints read, decode, and hierarchy phases',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: _Viewer(source: source, key: key, showCanvas: true)),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(
        state.loadingMessages.any(
            (message) => message.startsWith('Indexing netlist: 0.0/0.0 MB,')),
        isTrue);
    source.pauseAfterChunk = Completer<void>();
    final action = state.handleNodeToggle('0.0');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(state.busy, isTrue);
    expect(find.textContaining('Loading connectivity (1/1):'), findsOneWidget);
    expect(find.textContaining('/0.0 MB'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    source.pauseAfterChunk!.complete();
    await tester.pumpAndSettle();
    await action;
    expect(
        state.connectivityMessages,
        containsAllInOrder([
          'Loading connectivity (1/1)...',
          'Decoding connectivity (1/1)...',
          'Connecting loaded modules...',
        ]));
    expect(state.busy, isFalse);
    expect(state.errorMessage, isNull);
  });

  testWidgets('loads root connectivity only when root wires are requested',
      (tester) async {
    final state = await mount(tester);
    expect(source.reads, [(0, null)]);

    await toggle(tester, state, '0');
    expect(state.errorMessage, isNull);
    expect(source.reads, hasLength(2));
    expect(state.hasConnections('Top'), isTrue);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.adapter.schematic.nodeMap['0']!.hyperedges, isNotEmpty);

    await toggle(tester, state, '0');
    await toggle(tester, state, '0');
    expect(source.reads, hasLength(2));
  });

  testWidgets('opaque blocks retain controls and hide constants and selects',
      (tester) async {
    final top = _module('Empty', top: true);
    (top['cells'] as Map<String, dynamic>).addAll({
      'external': {
        'type': 'External',
        'port_directions': {'A': 'input', 'Y': 'output'},
        'connections': {
          'A': [2, 3],
          'Y': [3],
        },
      },
      'constant': {
        'type': r'$const',
        'parameters': {'WIDTH': 1, 'VALUE': '1'},
        'port_directions': {'Y': 'output'},
        'connections': {
          'Y': [2],
        },
      },
      'select': {
        'type': r'$slice',
        'parameters': {'A_WIDTH': 2, 'Y_WIDTH': 1, 'OFFSET': 0},
        'port_directions': {'A': 'input', 'Y': 'output'},
        'connections': {
          'A': [2, 3],
          'Y': [3],
        },
      },
    });
    final json = jsonEncode({
      'modules': {
        'Top': top,
        'Empty': {
          'ports': {
            'a': {
              'direction': 'input',
              'bits': [2],
            },
            'z': {
              'direction': 'output',
              'bits': [3],
            },
          },
          'cells': <String, dynamic>{},
        },
      },
    });
    source = _Source(json);
    final state = await mount(tester);

    void expectBlocksOnly() {
      expect(state.rendered.instances.map((n) => n.id),
          unorderedEquals(['0', '0.0', '0.1']));
      final root = state.rendered.instances.singleWhere((n) => n.id == '0');
      expect(root.hasChildren, isTrue);
      expect(root.isPartiallyExpanded, isTrue);
      expect(root.hasNonPrimitiveChildren, isTrue);
      expect(state.rendered.edges, isEmpty);
      for (final block in state.rendered.instances.where((n) => n.id != '0')) {
        expect(block.hasChildren, isFalse);
      }
    }

    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(state.hasConnections('Top'), isFalse);
    expectBlocksOnly();
    expect(
        state.adapter.schematic.nodeMap['0.1']!.elkPorts.first.hwMeta
            .signalWidth,
        2);

    await toggle(tester, state, '0');
    expect(state.errorMessage, isNull);
    expect(state.hasConnections('Top'), isTrue);
    expect(source.reads, hasLength(2));
    expect(
        state.rendered.instances.map((n) => n.id), containsAll(['0.2', '0.3']));
    expect(
        state.rendered.instances
            .singleWhere((n) => n.id == '0')
            .hasNonPrimitiveChildren,
        isTrue);

    final blocks = state.handleConvertToBlocksOnly('0');
    await tester.pumpAndSettle();
    await blocks;
    expectBlocksOnly();
    expect(source.reads, hasLength(2));

    final collapse = state.handleCollapsePartial('0');
    await tester.pumpAndSettle();
    await collapse;
    final root = state.rendered.instances.singleWhere((n) => n.id == '0');
    expect(root.hasChildren, isTrue);
    expect(root.isExpanded, isFalse);
    expect(root.hasHiddenNonPrimitiveChildren, isTrue);
    expect(source.reads, hasLength(2));

    // Non-file callers keep their existing primitive-only fallback.
    expect(
        NetlistSchematicAdapter.fromJson(json)
            .schematic
            .nodeMap['0']!
            .isExpanded,
        isTrue);
  });

  testWidgets('primitive-only files start collapsed instead of exposing gates',
      (tester) async {
    source = _Source(jsonEncode({
      'modules': {'Top': _module(r'$slice', top: true)},
    }));
    final state = await mount(tester);
    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(state.rendered.instances.map((n) => n.id), ['0']);
    final root = state.rendered.instances.single;
    expect(root.hasChildren, isTrue);
    expect(root.isExpanded, isFalse);
    expect(root.hasHiddenNonPrimitiveChildren, isFalse);
    await toggle(tester, state, '0');
    expect(state.errorMessage, isNull);
    expect(source.reads, hasLength(2));
    expect(state.rendered.instances.map((n) => n.id), contains('0.0'));
  });

  testWidgets('blocks-only recursive expansion does not fetch connectivity',
      (tester) async {
    final state = await mount(tester);
    final action = state.handleExpandNonPrimitivesRecursive('0');
    await tester.pumpAndSettle();
    await action;
    expect(state.errorMessage, isNull);
    expect(source.reads, [(0, null)]);
    expect(state.hasConnections('Top'), isFalse);
    expect(state.hasConnections('Child'), isFalse);
    expect(state.hasConnections('Grandchild'), isFalse);
  });

  testWidgets('recursive expansion reads descendants but not unrelated modules',
      (tester) async {
    final state = await mount(tester);
    await toggle(tester, state, '0.0', recursive: true);
    expect(state.errorMessage, isNull);
    expect(state.hasConnections('Child'), isTrue);
    expect(state.hasConnections('Grandchild'), isTrue);
    expect(state.hasConnections('Unrelated'), isFalse);
    expect(state.hasConnections('Top'), isFalse);
    expect(source.reads, hasLength(3));
  });

  testWidgets('connectivity read failure is visible and clears the busy state',
      (tester) async {
    final state = await mount(tester);
    source.fail = true;
    await toggle(tester, state, '0.0');
    expect(state.errorMessage, contains('Failed to load connectivity'));
    expect(state.busy, isFalse);
    expect(state.hasConnections('Child'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale file load cannot replace a newer design',
      (tester) async {
    final state = await mount(tester);
    final delayed = _Source(
      jsonEncode({
        'modules': {'Old': _module(r'$buf', top: true)}
      }),
    )..pause = Completer<void>();
    final stale = state.loadFile(delayed);
    await tester.pump();
    final replacement = _Source(
      jsonEncode({
        'modules': {'New': _module(r'$buf', top: true)}
      }),
    );
    final latest = state.loadFile(replacement);
    await tester.pumpAndSettle();
    await latest;
    delayed.pause!.complete();
    await tester.pumpAndSettle();
    await stale;
    expect(state.adapter.schematic.nodeMap['0']!.definition, 'New');
    expect(state.errorMessage, isNull);
  });
}

class _Source extends NetlistByteSource {
  _Source(String json) : bytes = utf8.encode(json);

  final List<int> bytes;
  final List<(int, int?)> reads = [];
  bool fail = false;
  Completer<void>? pause;
  Completer<void>? pauseAfterChunk;

  @override
  int get totalBytes => bytes.length;

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    reads.add((start, end));
    if (fail) {
      throw const FormatException('File changed; reload');
    }
    await pause?.future;
    yield bytes.sublist(start, end);
    await pauseAfterChunk?.future;
  }
}

class _ReadTrackingSource extends NetlistByteSource {
  _ReadTrackingSource(this.source);

  final NetlistByteSource source;
  final List<(int, int?)> reads = [];

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) {
    reads.add((start, end));
    return source.openRead(start, end);
  }
}

class _StalledMetadataFile extends XFile {
  _StalledMetadataFile(this.stage) : super('unused');

  final String stage;

  @override
  Future<int> length() =>
      stage == 'size' ? Completer<int>().future : Future.value(1);

  @override
  Future<DateTime> lastModified() => stage == 'timestamp'
      ? Completer<DateTime>().future
      : Future.value(DateTime.utc(2026));
}

class _StalledReadFile extends XFile {
  _StalledReadFile({this.failImmediately = false}) : super('unused');

  final Completer<void> cancellation = Completer<void>();
  final bool failImmediately;

  @override
  Future<int> length() async => 1;

  @override
  Future<DateTime> lastModified() async => DateTime.utc(2026);

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    final controller =
        StreamController<Uint8List>(onCancel: () => cancellation.future);
    addTearDown(controller.close);
    if (failImmediately) {
      controller.addError(const FormatException('Synthetic read failure'));
    }
    return controller.stream;
  }
}

class _Viewer extends StatefulWidget {
  const _Viewer({required this.source, this.showCanvas = false, super.key});

  final NetlistByteSource source;
  final bool showCanvas;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends BaseSchematicViewerState<_Viewer> {
  NetlistSchematicAdapter get adapter => schematicAdapter!;
  String? get errorMessage => error;
  bool get busy => isToggling;
  bool get loading => isLoading;
  String get currentJson => schematicJson!;
  final List<String> loadingMessages = [];
  final List<String> connectivityMessages = [];
  SchematicLayoutResult get rendered => layout!;

  bool hasConnections(String name) {
    final json = jsonDecode(schematicJson!) as Map<String, dynamic>;
    final modules = json['modules'] as Map<String, dynamic>;
    final module = modules[name] as Map<String, dynamic>;
    final cells = module['cells'] as Map<String, dynamic>;
    return (cells['child'] as Map<String, dynamic>).containsKey('connections');
  }

  Future<void> loadFile(NetlistByteSource source) => loadIndexedFile(source);

  @override
  Future<void> loadInitialSchematic() => loadIndexedFile(widget.source);

  @override
  SchematicLayoutEngine createLayoutEngine() => _LayoutEngine();

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      loadingMessages.add(loadingMessage);
    }
    if (isToggling) {
      connectivityMessages.add(togglingLabel);
    }
    if (!isLoading && widget.showCanvas) {
      return BlocProvider(
        create: (_) => SchematicThemeCubit(),
        child: buildSchematicCanvas(),
      );
    }
    return isLoading
        ? buildLoadingIndicator()
        : isToggling
            ? buildLoadingIndicator(message: togglingLabel)
            : const SizedBox();
  }
}

class _LayoutEngine implements SchematicLayoutEngine {
  @override
  bool get isAvailable => true;

  @override
  SchematicDependencyStatus checkDependencies() =>
      SchematicDependencyStatus(elk: true);

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) async =>
      ElkLayoutExtractor.extract(
        jsonDecode(elkGraphJson) as Map<String, dynamic>,
      );

  @override
  void dispose() {}
}
