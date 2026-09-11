// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// layout_navigation_services_test.dart
// Focused tests for layout navigation helpers.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/services/layout_hierarchy_bridge.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_wire_zoom.dart';

void main() {
  group('SchematicWireZoom', () {
    test('returns null when the wire is absent', () {
      final result = SchematicWireZoom.computeWireZoom(
        layout: _layout(edges: const []),
        wireId: 'missing',
        viewportSize: const Size(800, 600),
      );

      expect(result, isNull);
    });

    test('focuses and centers a small matching wire', () {
      final result = SchematicWireZoom.computeWireZoom(
        layout: _layout(edges: [_edge('signal', 100, 200, 200, 200)]),
        wireId: 'signal',
        viewportSize: const Size(800, 600),
      );

      expect(result, isNotNull);
      expect(result!.isFocusedZoom, isTrue);
      expect(result.scale, 3);
      expect(result.wireBounds, const Rect.fromLTRB(80, 180, 220, 220));
      expect(result.offset, const Offset(-50, -300));
    });

    test('fits a large scoped wire and ignores sibling scopes', () {
      final layout = SchematicLayoutResult(
        instances: [
          SchematicInstanceData(
              id: 'scope',
              x: 0,
              y: 0,
              width: 1,
              height: 1,
              name: 'scope',
              children: const ['child']),
          SchematicInstanceData(
              id: 'child', x: 0, y: 0, width: 1, height: 1, name: 'child'),
          SchematicInstanceData(
              id: 'sibling', x: 0, y: 0, width: 1, height: 1, name: 'sibling'),
        ],
        ports: [
          _port('scope-out', 'scope'),
          _port('child-in', 'child'),
          _port('sibling-out', 'sibling'),
        ],
        edges: [
          _edge(
            'wide',
            50,
            50,
            950,
            950,
            sourcePort: 'scope-out',
            targetPort: 'child-in',
          ),
          _edge(
            'wide',
            1,
            1,
            2,
            2,
            sourcePort: 'sibling-out',
          ),
        ],
        width: 1000,
        height: 1000,
      );

      final result = SchematicWireZoom.computeWireZoom(
        layout: layout,
        wireId: 'wide',
        scopeNodeId: 'scope',
        viewportSize: const Size(800, 600),
      );

      expect(result, isNotNull);
      expect(result!.isFocusedZoom, isFalse);
      expect(result.wireBounds, const Rect.fromLTRB(30, 30, 970, 970));
      expect(result.scale, closeTo(560 / 940, 0.0001));
    });
  });

  group('LayoutHierarchyBridge', () {
    final hierarchy = _hierarchy();

    test('uses mapped hierarchy paths for scope checks', () {
      final bridge = LayoutHierarchyBridge(
        hierarchy: hierarchy,
        layout: _hierarchicalLayout(),
        instanceIdToOccurrenceId: const {
          'parent': 'Top/parent',
          'child': 'Top/parent/child',
          'sibling': 'Top/sibling',
        },
      );

      expect(bridge.isInstanceInScope('child', 'parent'), isTrue);
      expect(bridge.isInstanceInScope('sibling', 'parent'), isFalse);
      expect(bridge.isInstanceInScope(null, 'parent'), isFalse);
    });

    test('falls back to the layout parent map when paths are unavailable', () {
      final bridge = LayoutHierarchyBridge(
        hierarchy: hierarchy,
        layout: _hierarchicalLayout(),
        instanceIdToOccurrenceId: const {},
      );

      expect(bridge.isInstanceInScope('child', 'parent'), isTrue);
      expect(bridge.isInstanceInScope('sibling', 'parent'), isFalse);
    });
  });
}

SchematicLayoutResult _layout({required List<SchematicEdgeData> edges}) =>
    SchematicLayoutResult(
      instances: const [],
      ports: const [],
      edges: edges,
      width: 1000,
      height: 800,
    );

SchematicEdgeData _edge(
  String name,
  double startX,
  double startY,
  double endX,
  double endY, {
  String? sourcePort,
  String? targetPort,
}) =>
    SchematicEdgeData(
      id: '$name-$startX',
      name: name,
      sourcePort: sourcePort,
      targetPort: targetPort,
      points: [SchematicPoint(startX, startY), SchematicPoint(endX, endY)],
    );

SchematicPortData _port(String id, String instanceId) => SchematicPortData(
      id: id,
      instanceId: instanceId,
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      name: id,
    );

SchematicLayoutResult _hierarchicalLayout() => SchematicLayoutResult(
      instances: [
        SchematicInstanceData(
          id: 'parent',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          name: 'parent',
          children: const ['child'],
        ),
        SchematicInstanceData(
          id: 'child',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          name: 'child',
        ),
        SchematicInstanceData(
          id: 'sibling',
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          name: 'sibling',
        ),
      ],
      ports: const [],
      edges: const [],
      width: 1,
      height: 1,
    );

HierarchyService _hierarchy() => NetlistHierarchyAdapter.fromJson(
      jsonEncode({
        'modules': {
          'Top': {
            'attributes': {'top': 1},
            'ports': <String, dynamic>{},
            'netnames': <String, dynamic>{},
            'cells': {
              'parent': {'type': 'Parent', 'connections': <String, dynamic>{}},
              'sibling': {
                'type': 'Sibling',
                'connections': <String, dynamic>{}
              },
            },
          },
          'Parent': {
            'ports': <String, dynamic>{},
            'netnames': <String, dynamic>{},
            'cells': {
              'child': {'type': 'Child', 'connections': <String, dynamic>{}},
            },
          },
          'Sibling': {
            'ports': <String, dynamic>{},
            'netnames': <String, dynamic>{}
          },
          'Child': {
            'ports': <String, dynamic>{},
            'netnames': <String, dynamic>{}
          },
        },
      }),
    );
