// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_schematic_synthesizer_test.dart
// Tests hierarchy-only schematic expansion behavior.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

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

void main() {
  testWidgets('reloads when the asset path changes with the same key', (
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
    late StateSetter updateParent;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateParent = setState;
            return EmbeddedSchematicViewer.fromAsset(
              key: viewerKey,
              assetPath: assetPath,
            );
          },
        ),
      ),
    );
    await _pumpUntilText(tester, 'Unexpected character');

    updateParent(() {
      assetPath = 'assets/second-schematic.json';
    });
    await _pumpUntilText(tester, 'Unexpected end of input');

    expect(find.textContaining('Unexpected character'), findsNothing);
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
