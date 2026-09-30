// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_schematic_synthesizer_test.dart
// Tests hierarchy-only schematic expansion behavior.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show Completer;
import 'dart:convert' show utf8;
import 'dart:typed_data' show ByteData, Uint8List;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/hierarchy_schematic_synthesizer.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';
import 'package:rohd_schematic_viewer/src/ui/embedded_schematic_viewer.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_expansion_mode.dart';

HierarchyService _buildHierarchy() => BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'top',
        definition: 'Top',
        children: [
          HierarchyOccurrence(
            name: 'u1',
            definition: 'Middle',
            children: [
              HierarchyOccurrence(name: 'leaf', definition: 'Leaf'),
            ],
          ),
        ],
      ),
    );

HierarchyService _buildSelectionHierarchy() => BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'top',
        definition: 'Top',
        children: [
          HierarchyOccurrence(
            name: 'u1',
            definition: 'First',
            children: [
              HierarchyOccurrence(name: 'firstLeaf', definition: 'FirstLeaf'),
            ],
          ),
          HierarchyOccurrence(
            name: 'u2',
            definition: 'Second',
            children: [
              HierarchyOccurrence(
                name: 'secondLeaf',
                definition: 'SecondLeaf',
              ),
            ],
          ),
        ],
      ),
    );

SchematicInstanceData _instance(
  SchematicCanvas canvas,
  String id,
) =>
    canvas.layout.instances.singleWhere((instance) => instance.id == id);

Future<SchematicCanvas> _pumpUntilCanvas(
  WidgetTester tester,
  bool Function(SchematicCanvas canvas) matches,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    final canvasFinder = find.byType(SchematicCanvas);
    if (canvasFinder.evaluate().length == 1) {
      final canvas = tester.widget<SchematicCanvas>(canvasFinder);
      if (matches(canvas)) {
        return canvas;
      }
    }
  }
  fail('Timed out waiting for the expected hierarchy-only layout.');
}

Future<void> _pumpUntilText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 10));
    if (find.textContaining(text).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for text containing "$text".');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() matches,
  String description,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (matches()) {
      return;
    }
  }
  fail('Timed out waiting for $description.');
}

void main() {
  testWidgets('reloads a changed asset path after becoming visible', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMessageHandler('flutter/assets', (message) async {
            final path = utf8.decode(
              message!.buffer.asUint8List(
                message.offsetInBytes,
                message.lengthInBytes,
              ),
            );
            final contents = path.contains('first') ? 'not-json' : '{';
            return ByteData.sublistView(
              Uint8List.fromList(utf8.encode(contents)),
            );
          });
    addTearDown(
      () => messenger.setMockMessageHandler('flutter/assets', null),
    );

    const viewerKey = ValueKey('asset-viewer');
    var assetPath = 'assets/first-schematic.json';
    var isVisible = true;
    late StateSetter updateParent;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateParent = setState;
            return EmbeddedSchematicViewer.fromAsset(
              key: viewerKey,
              assetPath: assetPath,
              isVisible: isVisible,
            );
          },
        ),
      ),
    );
    await _pumpUntilText(tester, 'Unexpected character');

    updateParent(() => isVisible = false);
    await tester.pump();

    updateParent(() {
      assetPath = 'assets/second-schematic.json';
    });
    await tester.pump();

    updateParent(() => isVisible = true);
    await _pumpUntilText(tester, 'Unexpected end of input');

    expect(find.textContaining('Unexpected character'), findsNothing);
  });

  testWidgets('ignores a stale module fetch after a newer selection', (
    tester,
  ) async {
    final hierarchy = _buildSelectionHierarchy();
    final firstFetch = Completer<Map<String, dynamic>?>();
    final requestedDefinitions = <String>[];
    HierarchyOccurrence? selectedModule;
    late StateSetter updateParent;

    Future<Map<String, dynamic>?> fetchModule(String definition) {
      requestedDefinitions.add(definition);
      if (definition == 'First') {
        return firstFetch.future;
      }
      if (definition == 'Second') {
        return Future<Map<String, dynamic>?>.value();
      }
      fail('Unexpected module fetch: $definition');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateParent = setState;
            return EmbeddedSchematicViewer.fromHierarchy(
              externalHierarchy: hierarchy,
              selectedModule: selectedModule,
              fetchModuleNetlist: fetchModule,
            );
          },
        ),
      ),
    );
    await _pumpUntilCanvas(
      tester,
      (canvas) => canvas.layout.instances.any(
        (instance) => instance.id == 'top/u1',
      ),
    );

    updateParent(() => selectedModule = hierarchy.root.children[0]);
    await _pumpUntil(
      tester,
      () => requestedDefinitions.contains('First'),
      'the first module fetch',
    );

    updateParent(() => selectedModule = hierarchy.root.children[1]);
    final newestCanvas = await _pumpUntilCanvas(
      tester,
      (canvas) {
        final ids = canvas.layout.instances.map((instance) => instance.id);
        return ids.contains('top/u2') && ids.contains('top/u2/secondLeaf');
      },
    );
    expect(
      newestCanvas.layout.instances.map((instance) => instance.id),
      isNot(contains('top/u1')),
    );

    // A stale extraction would surface this malformed module as an error.
    firstFetch.complete(<String, dynamic>{
      'First': <String, dynamic>{'ports': 'not-a-map'},
    });
    for (var attempt = 0; attempt < 5; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    final survivingCanvas = tester.widget<SchematicCanvas>(
      find.byType(SchematicCanvas),
    );
    expect(
      survivingCanvas.layout.instances.map((instance) => instance.id),
      containsAll(<String>['top/u2', 'top/u2/secondLeaf']),
    );
    expect(find.text('Error'), findsNothing);
    expect(requestedDefinitions, orderedEquals(<String>['First', 'Second']));
  });

  test('hierarchy synthesizer can collapse its target root', () {
    final synthesizer = HierarchySchematicSynthesizer(_buildHierarchy());

    final collapsed = synthesizer.synthesize(expandRoot: false);
    final defaultView = synthesizer.synthesize();
    final recursivelyExpanded = synthesizer.synthesize(
      expandedNodes: {'top/u1'},
    );

    expect(collapsed.instances, hasLength(1));
    expect(collapsed.instances.single.id, 'top');
    expect(collapsed.instances.single.isExpanded, isFalse);
    expect(
      defaultView.instances.map((instance) => instance.id),
      containsAll(<String>['top', 'top/u1']),
    );
    expect(
      defaultView.instances.any((instance) => instance.id == 'top/u1/leaf'),
      isFalse,
    );
    expect(
      recursivelyExpanded.instances.map((instance) => instance.id),
      containsAll(<String>['top', 'top/u1', 'top/u1/leaf']),
    );
  });

  testWidgets('fromHierarchy applies controlled expansion mode updates', (
    tester,
  ) async {
    final hierarchy = _buildHierarchy();
    var mode = SchematicExpansionMode.collapsed;
    late StateSetter updateParent;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateParent = setState;
            return EmbeddedSchematicViewer.fromHierarchy(
              externalHierarchy: hierarchy,
              expansionMode: mode,
            );
          },
        ),
      ),
    );

    var canvas = await _pumpUntilCanvas(
      tester,
      (candidate) => candidate.layout.instances.length == 1,
    );
    expect(_instance(canvas, 'top').isExpanded, isFalse);

    final collapsedLayout = canvas.layout;
    updateParent(() => mode = SchematicExpansionMode.defaultView);
    canvas = await _pumpUntilCanvas(
      tester,
      (candidate) =>
          candidate.layout.instances.length == 2 &&
          !identical(candidate.layout, collapsedLayout),
    );
    expect(_instance(canvas, 'top').isExpanded, isTrue);
    expect(_instance(canvas, 'top/u1').isExpanded, isFalse);

    updateParent(() => mode = SchematicExpansionMode.blocksOnly);
    canvas = await _pumpUntilCanvas(
      tester,
      (candidate) => candidate.layout.instances.length == 3,
    );
    expect(_instance(canvas, 'top').isExpanded, isTrue);
    expect(_instance(canvas, 'top/u1').isExpanded, isTrue);

    final blocksOnlyLayout = canvas.layout;
    updateParent(() => mode = SchematicExpansionMode.fullyExpanded);
    canvas = await _pumpUntilCanvas(
      tester,
      (candidate) =>
          candidate.layout.instances.length == 3 &&
          !identical(candidate.layout, blocksOnlyLayout),
    );
    expect(_instance(canvas, 'top').isExpanded, isTrue);
    expect(_instance(canvas, 'top/u1').isExpanded, isTrue);
  });

  testWidgets('fromHierarchy applies an initial selected module', (
    tester,
  ) async {
    final hierarchy = _buildHierarchy();

    await tester.pumpWidget(
      MaterialApp(
        home: EmbeddedSchematicViewer.fromHierarchy(
          externalHierarchy: hierarchy,
          selectedModule: hierarchy.root.children.single,
        ),
      ),
    );

    final canvas = await _pumpUntilCanvas(
      tester,
      (candidate) {
        final ids =
            candidate.layout.instances.map((instance) => instance.id).toSet();
        return ids.containsAll({'top/u1', 'top/u1/leaf'}) &&
            !ids.contains('top');
      },
    );
    expect(_instance(canvas, 'top/u1').isExpanded, isTrue);
  });

  testWidgets(
    'fromHierarchy applies selection with expansion mode in one rebuild',
    (tester) async {
      final hierarchy = _buildHierarchy();
      HierarchyOccurrence? selectedModule;
      var mode = SchematicExpansionMode.collapsed;
      late StateSetter updateParent;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updateParent = setState;
              return EmbeddedSchematicViewer.fromHierarchy(
                externalHierarchy: hierarchy,
                selectedModule: selectedModule,
                expansionMode: mode,
              );
            },
          ),
        ),
      );
      await _pumpUntilCanvas(
        tester,
        (canvas) => canvas.layout.instances.length == 1,
      );

      updateParent(() {
        selectedModule = hierarchy.root.children.single;
        mode = SchematicExpansionMode.defaultView;
      });

      final canvas = await _pumpUntilCanvas(
        tester,
        (candidate) {
          final ids =
              candidate.layout.instances.map((instance) => instance.id).toSet();
          return ids.containsAll({'top/u1', 'top/u1/leaf'}) &&
              !ids.contains('top');
        },
      );
      expect(_instance(canvas, 'top/u1').isExpanded, isTrue);
    },
  );

  testWidgets(
    'fromHierarchy applies combined selection and mode after deferral',
    (tester) async {
      final hierarchy = _buildHierarchy();
      HierarchyOccurrence? selectedModule;
      var mode = SchematicExpansionMode.collapsed;
      var isVisible = false;
      late StateSetter updateParent;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updateParent = setState;
              return EmbeddedSchematicViewer.fromHierarchy(
                externalHierarchy: hierarchy,
                selectedModule: selectedModule,
                expansionMode: mode,
                isVisible: isVisible,
              );
            },
          ),
        ),
      );
      await tester.pump();

      updateParent(() {
        selectedModule = hierarchy.root.children.single;
        mode = SchematicExpansionMode.defaultView;
      });
      await tester.pump();

      updateParent(() => isVisible = true);
      final canvas = await _pumpUntilCanvas(
        tester,
        (candidate) {
          final ids =
              candidate.layout.instances.map((instance) => instance.id).toSet();
          return ids.containsAll({'top/u1', 'top/u1/leaf'}) &&
              !ids.contains('top');
        },
      );
      expect(_instance(canvas, 'top/u1').isExpanded, isTrue);
    },
  );
}
