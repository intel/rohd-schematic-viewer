// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// multi_instance_highlight_test.dart
// Verify that selecting a wire in one multi-instantiated block does NOT
// highlight the identically-named wire in sibling instances.
//
// 2026 June
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

/// Build a minimal ELK JSON with two sibling instances of the same module,
/// each containing an edge with the same parent-name (wireId) but belonging
/// to a different hierarchy scope.
Map<String, dynamic> _buildMultiInstanceElk() {
  // Two instances: "ch0/macTap1" and "ch1/macTap1", each owning an edge
  // whose hwMeta.parent.hwMeta.name == "accumIn_stage2_i".
  Map<String, dynamic> makeChild(String chId, String macId) {
    final scopePath = 'FilterBank/$chId/$macId';
    return <String, dynamic>{
      'id': '${chId}_$macId',
      'x': 10.0,
      'y': 20.0,
      'width': 100.0,
      'height': 50.0,
      'hierarchyNodeId': scopePath,
      'hwMeta': <String, dynamic>{
        'name': macId,
        'cls': 'MacUnit',
        'bodyText': '',
      },
      'ports': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': '${chId}_${macId}_pIn',
          'x': 0.0,
          'y': 10.0,
          'width': 7.0,
          'height': 13.0,
          'hwMeta': <String, dynamic>{'name': 'accumIn_stage2_i'},
          'direction': 'INPUT',
          'properties': <String, dynamic>{'side': 'WEST'},
        },
        <String, dynamic>{
          'id': '${chId}_${macId}_pOut',
          'x': 100.0,
          'y': 10.0,
          'width': 7.0,
          'height': 13.0,
          'hwMeta': <String, dynamic>{'name': 'accumOut'},
          'direction': 'OUTPUT',
          'properties': <String, dynamic>{'side': 'EAST'},
        },
      ],
      'edges': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': '${chId}_${macId}_e1',
          'source': '${chId}_$macId',
          'sourcePort': '${chId}_${macId}_pOut',
          'target': '${chId}_$macId',
          'targetPort': '${chId}_${macId}_pIn',
          'hwMeta': <String, dynamic>{
            'name': 'accumIn_stage2_i',
            'signalWidth': 16,
            'parent': <String, dynamic>{
              'id': 'net_accum',
              'hwMeta': <String, dynamic>{'name': 'accumIn_stage2_i'},
            },
          },
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'startPoint': <String, dynamic>{'x': 110.0, 'y': 30.0},
              'endPoint': <String, dynamic>{'x': 10.0, 'y': 30.0},
            },
          ],
        },
      ],
    };
  }

  return <String, dynamic>{
    'id': 'root',
    'x': 0.0,
    'y': 0.0,
    'width': 500.0,
    'height': 400.0,
    'children': <Map<String, dynamic>>[
      // ch0/macTap1
      makeChild('ch0', 'macTap1'),
      // ch1/macTap1 — sibling instance of the same module
      <String, dynamic>{
        ...makeChild('ch1', 'macTap1'),
        // offset the second instance so positions don't collide
        'y': 120.0,
      },
    ],
  };
}

void main() {
  group('Multi-instance wire highlighting', () {
    late SchematicLayoutResult layout;

    setUp(() {
      layout = ElkLayoutExtractor.extract(_buildMultiInstanceElk());
    });

    test('edges with same wireId have distinct scopeHierarchyPath', () {
      // Both children should produce edges with the same wireId
      // (parentName == "accumIn_stage2_i") but different
      // scopeHierarchyPath values.
      final accumEdges =
          layout.edges.where((e) => e.wireId == 'accumIn_stage2_i').toList();

      expect(
        accumEdges,
        hasLength(2),
        reason: 'Expected two edges named "accumIn_stage2_i" '
            '(one per instance)',
      );

      final scopePaths = accumEdges.map((e) => e.scopeHierarchyPath).toSet();
      expect(
        scopePaths,
        hasLength(2),
        reason: 'Each instance edge must carry a unique '
            'scopeHierarchyPath',
      );

      expect(scopePaths, contains('FilterBank/ch0/macTap1'));
      expect(scopePaths, contains('FilterBank/ch1/macTap1'));
    });

    test('scope-aware filter selects only the clicked instance edge', () {
      final accumEdges =
          layout.edges.where((e) => e.wireId == 'accumIn_stage2_i').toList();
      expect(accumEdges.length, greaterThanOrEqualTo(2));

      // Simulate clicking the ch0 instance edge
      final clickedEdge = accumEdges.firstWhere(
        (e) => e.scopeHierarchyPath == 'FilterBank/ch0/macTap1',
      );
      final selectedWireId = clickedEdge.wireId;
      final selectedScopePath = clickedEdge.scopeHierarchyPath;

      // Build the scope-paths map as the click handler does
      final selectedWireScopePaths = <String, String?>{
        selectedWireId: selectedScopePath,
      };

      // For every edge in the layout, check highlight logic
      for (final edge in layout.edges) {
        final wireId = edge.wireId;
        final isHighlightedWithScope =
            selectedWireScopePaths.containsKey(wireId) &&
                (selectedWireScopePaths[wireId] == null ||
                    edge.scopeHierarchyPath == selectedWireScopePaths[wireId]);

        if (edge.scopeHierarchyPath == 'FilterBank/ch0/macTap1' &&
            wireId == 'accumIn_stage2_i') {
          expect(
            isHighlightedWithScope,
            isTrue,
            reason: 'Edge in ch0/macTap1 scope should be highlighted',
          );
        } else if (edge.scopeHierarchyPath == 'FilterBank/ch1/macTap1' &&
            wireId == 'accumIn_stage2_i') {
          expect(
            isHighlightedWithScope,
            isFalse,
            reason: 'Edge in ch1/macTap1 scope must NOT be highlighted '
                'when ch0/macTap1 was clicked',
          );
        }
      }
    });

    test('unscoped selectedWireIds highlights ALL instances (the bug)', () {
      // This test documents the buggy behaviour: when no scope check
      // is applied, every edge with matching wireId lights up.
      final accumEdges =
          layout.edges.where((e) => e.wireId == 'accumIn_stage2_i').toList();

      // Simulate the old (broken) selectedWireIds check
      final selectedWireIds = <String>{'accumIn_stage2_i'};

      final highlighted =
          accumEdges.where((e) => selectedWireIds.contains(e.wireId)).toList();

      // Without scope filtering, both instances match — this is the bug
      expect(
        highlighted,
        hasLength(2),
        reason: 'Without scope filtering, all instances are matched',
      );
    });

    test('point-based proximity check discriminates chains per instance', () {
      // Simulate the painter's proximity-based scope approach:
      // collect adjusted-edge points for the in-scope edges only,
      // then verify that out-of-scope edge points are far away.
      final accumEdges =
          layout.edges.where((e) => e.wireId == 'accumIn_stage2_i').toList();
      expect(accumEdges, hasLength(2));

      final ch0Edge = accumEdges.firstWhere(
        (e) => e.scopeHierarchyPath == 'FilterBank/ch0/macTap1',
      );
      final ch1Edge = accumEdges.firstWhere(
        (e) => e.scopeHierarchyPath == 'FilterBank/ch1/macTap1',
      );

      // Build scope offsets from ch0 edge points (as the painter does)
      final scopeOffsets = ch0Edge.points.map((p) => Offset(p.x, p.y)).toList();

      // ch0 edge points should be near (within tolerance) their own offsets
      const tolerance = 1.0;
      final ch0Near = ch0Edge.points.any(
        (cp) => scopeOffsets.any(
          (sp) =>
              (cp.x - sp.dx).abs() < tolerance &&
              (cp.y - sp.dy).abs() < tolerance,
        ),
      );
      expect(
        ch0Near,
        isTrue,
        reason: 'ch0 edge points must match their own scope offsets',
      );

      // ch1 edge points should NOT be near ch0 scope offsets
      // (instances are at different spatial positions)
      final ch1Near = ch1Edge.points.any(
        (cp) => scopeOffsets.any(
          (sp) =>
              (cp.x - sp.dx).abs() < tolerance &&
              (cp.y - sp.dy).abs() < tolerance,
        ),
      );
      expect(
        ch1Near,
        isFalse,
        reason: 'ch1 edge points must NOT match ch0 scope offsets — '
            'instances are at different positions',
      );
    });
  });
}
