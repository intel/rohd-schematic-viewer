// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// layout_generation_test.dart
// Tests stale asynchronous layout request handling.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show Completer;
import 'dart:convert' show jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_expansion_mode.dart';

void main() {
  testWidgets('newer layout request wins when older request finishes last', (
    tester,
  ) async {
    final engine = _ControlledLayoutEngine();
    final hostKey = GlobalKey<_GenerationHostState>();

    await tester.pumpWidget(
      MaterialApp(home: _GenerationHost(key: hostKey, engine: engine)),
    );

    final state = hostKey.currentState!;
    final oldJson = _netlist('OldTop');
    final newJson = _netlist('NewTop');

    final oldRequest =
        state._load(oldJson, SchematicExpansionMode.fullyExpanded);
    await _pumpUntilRequestCount(tester, engine, 1);

    final newRequest = state._load(
      newJson,
      SchematicExpansionMode.fullyExpanded,
    );
    await _pumpUntilRequestCount(tester, engine, 2);

    engine._requests[1].complete(_layout('new-layout'));
    await tester.pump();
    await newRequest;

    engine._requests[0].complete(_layout('old-layout'));
    await tester.pump();
    await oldRequest;

    expect(state._committedJson, newJson);
    expect(state._adapterRootName, 'NewTop');
    expect(state._committedLayout!.instances.single.id, 'new-layout');
  });
}

Future<void> _pumpUntilRequestCount(
  WidgetTester tester,
  _ControlledLayoutEngine engine,
  int count,
) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 1));
    if (engine._requests.length >= count) {
      return;
    }
  }
  fail(
    'Timed out waiting for $count layout requests; '
    'received ${engine._requests.length}.',
  );
}

String _netlist(String moduleName) => jsonEncode({
      'modules': {
        moduleName: {
          'attributes': {'top': 1},
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
      },
    });

SchematicLayoutResult _layout(String id) => SchematicLayoutResult(
      instances: [
        SchematicInstanceData(
          id: id,
          x: 0,
          y: 0,
          width: 100,
          height: 80,
          name: id,
        ),
      ],
      ports: const [],
      edges: const [],
      width: 100,
      height: 80,
    );

class _GenerationHost extends StatefulWidget {
  final SchematicLayoutEngine _engine;

  const _GenerationHost({
    required SchematicLayoutEngine engine,
    super.key,
  }) : _engine = engine;

  @override
  State<_GenerationHost> createState() => _GenerationHostState();
}

class _GenerationHostState extends BaseSchematicViewerState<_GenerationHost> {
  int _generation = 0;

  String? get _committedJson => schematicJson;
  SchematicLayoutResult? get _committedLayout => layout;
  String? get _adapterRootName => schematicAdapter?.hierarchy.root.name;

  @override
  SchematicLayoutEngine createLayoutEngine() => widget._engine;

  @override
  void loadInitialSchematic() {}

  Future<void> _load(String json, SchematicExpansionMode expansionMode) {
    final generation = ++_generation;
    return computeLayout(
      json,
      expansionMode: expansionMode,
      shouldCommit: () => generation == _generation,
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ControlledLayoutEngine implements SchematicLayoutEngine {
  final List<Completer<SchematicLayoutResult>> _requests = [];

  @override
  bool get isAvailable => true;

  @override
  SchematicDependencyStatus checkDependencies() =>
      SchematicDependencyStatus(elk: true);

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) {
    final request = Completer<SchematicLayoutResult>();
    _requests.add(request);
    return request.future;
  }

  @override
  void dispose() {}
}
