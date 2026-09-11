// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// port_expand_scope_test.dart
// Verifies that expandPort reveals only the correct children and edges
// for a specific port click, not sibling children connected to a
// different port on the same instance.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';

import 'test_helpers.dart';

/// Build an accumulator-chain graph mimicking FilterChannel's macTap topology.
///
///   parent (FilterChannel)
///     ├── macTap0  (ports: sampleIn=0, accumIn=1, result=2)
///     ├── macTap1  (ports: sampleIn=0, accumIn=1, result=2)
///     └── macTap2  (ports: sampleIn=0, accumIn=1, result=2)
///
///   Hyperedges (accumulator chain):
///     accumIn_0: macTap0:result(2) → macTap1:accumIn(1)
///     accumIn:   macTap1:result(2) → macTap2:accumIn(1)
///     result:    macTap2:result(2) → parent:dataOut(1)
///
SchematicGraph _buildAccumChainGraph() {
  // --- macTap children ---
  final macTap0 = _makeMacTap('macTap0');
  final macTap1 = _makeMacTap('macTap1');
  final macTap2 = _makeMacTap('macTap2');

  // --- Hyperedges ---
  final heAccumIn0 = LayoutHyperedge(
    id: 'parent:h0',
    signal: SignalOccurrence(name: 'accumIn_0', width: 16),
    sources: [('macTap0', 2)], // macTap0:result
    targets: [('macTap1', 1)], // macTap1:accumIn
  );
  final heAccumIn = LayoutHyperedge(
    id: 'parent:h1',
    signal: SignalOccurrence(name: 'accumIn', width: 16),
    sources: [('macTap1', 2)], // macTap1:result
    targets: [('macTap2', 1)], // macTap2:accumIn
  );
  final heResult = LayoutHyperedge(
    id: 'parent:h2',
    signal: SignalOccurrence(name: 'result', width: 16),
    sources: [('macTap2', 2)], // macTap2:result
    targets: [('parent', 1)], // parent:dataOut
  );

  // --- parent node ---
  final parent = makeTestNode(
    'parent',
    hwMeta: const HwMeta(name: 'ch0'),
    ports: [
      ElkPort(
        id: 'parent:0',
        hwMeta: const HwMeta(name: 'sampleIn'),
        direction: 'INPUT',
        side: 'WEST',
      ),
      ElkPort(
        id: 'parent:1',
        hwMeta: const HwMeta(name: 'dataOut'),
        direction: 'OUTPUT',
        side: 'EAST',
        index: 1,
      ),
    ],
    hiddenChildren: [macTap0, macTap1, macTap2],
    hyperedges: [heAccumIn0, heAccumIn, heResult],
  );
  macTap0.parent = parent;
  macTap1.parent = parent;
  macTap2.parent = parent;

  return SchematicGraph(
    root: parent,
    nodeMap: {
      'parent': parent,
      'macTap0': macTap0,
      'macTap1': macTap1,
      'macTap2': macTap2,
    },
  );
}

LayoutNode _makeMacTap(String name) {
  // Give each macTap a hidden child so expandNonPrimitives treats them
  // as non-primitive (blocks-only mode will reveal them).
  final dummy = makeTestNode(
    '$name.inner',
    hwMeta: HwMeta(name: '${name}_inner'),
  );
  return makeTestNode(
    name,
    hwMeta: HwMeta(name: name),
    ports: [
      ElkPort(
        id: '$name:0',
        hwMeta: const HwMeta(name: 'sampleIn'),
        direction: 'INPUT',
        side: 'WEST',
      ),
      ElkPort(
        id: '$name:1',
        hwMeta: const HwMeta(name: 'accumIn'),
        direction: 'INPUT',
        side: 'WEST',
        index: 1,
      ),
      ElkPort(
        id: '$name:2',
        hwMeta: const HwMeta(name: 'result'),
        direction: 'OUTPUT',
        side: 'EAST',
        index: 2,
      ),
    ],
    hiddenChildren: [dummy],
  );
}

void main() {
  group('expandPort scope correctness', () {
    late SchematicGraph graph;

    setUp(() {
      // Expand in blocks-only mode: all three macTaps become visible
      // children (in partialChildIds) but no edges are shown.
      graph = _buildAccumChainGraph()
        ..expandNonPrimitives('parent', includeEdges: false);
      final parent = graph.nodeMap['parent']!;
      // Verify blocks-only mode is active
      expect(
        parent.partialChildIds,
        containsAll(['macTap0', 'macTap1', 'macTap2']),
        reason: 'blocks-only should make all macTaps visible',
      );
      expect(
        parent.partialHyperedgeIds,
        isEmpty,
        reason: 'blocks-only should not show any edges',
      );
    });

    test('finds only unambiguous direct port drivers', () {
      expect(
        graph.directDriverSignalPath('accumIn_0', 'ch0'),
        equals('macTap0/result'),
      );

      final parent = graph.nodeMap['parent']!;
      parent.hyperedges!.add(
        LayoutHyperedge(
          id: 'parent:inputDriver',
          signal: SignalOccurrence(name: 'inputDriven', width: 16),
          sources: [('parent', 0)],
          targets: [('macTap0', 0)],
        ),
      );

      expect(
        graph.directDriverSignalPath('inputDriven', 'ch0'),
        equals('ch0/sampleIn'),
      );

      parent.hyperedges!.add(
        LayoutHyperedge(
          id: 'parent:ambiguousDriver',
          signal: SignalOccurrence(name: 'inputDriven', width: 16),
          sources: [('macTap1', 2)],
          targets: [('macTap2', 0)],
        ),
      );

      expect(graph.directDriverSignalPath('inputDriven', 'ch0'), isNull);
      expect(graph.directDriverSignalPath('missing', 'ch0'), isNull);
    });

    test('clicking macTap0/result reveals only accumIn_0 hyperedge', () {
      // macTap0:result → macTap1:accumIn (via accumIn_0)
      final expanded = graph.expandPort('parent', 'macTap0:2');
      expect(expanded, isTrue);

      final parent = graph.nodeMap['parent']!;
      expect(
        parent.partialHyperedgeIds,
        contains('parent:h0'),
        reason: 'Should reveal accumIn_0 hyperedge',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h1')),
        reason: 'Should NOT reveal accumIn hyperedge',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h2')),
        reason: 'Should NOT reveal result hyperedge',
      );
    });

    test('clicking macTap1/result reveals only accumIn hyperedge', () {
      // macTap1:result → macTap2:accumIn (via accumIn)
      final expanded = graph.expandPort('parent', 'macTap1:2');
      expect(expanded, isTrue);

      final parent = graph.nodeMap['parent']!;
      expect(
        parent.partialHyperedgeIds,
        contains('parent:h1'),
        reason: 'Should reveal accumIn hyperedge',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h0')),
        reason: 'Should NOT reveal accumIn_0 hyperedge',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h2')),
        reason: 'Should NOT reveal result hyperedge',
      );
    });

    test('clicking macTap2/result reveals only result hyperedge', () {
      // macTap2:result → parent:dataOut (via result hyperedge)
      final expanded = graph.expandPort('parent', 'macTap2:2');
      expect(expanded, isTrue);

      final parent = graph.nodeMap['parent']!;
      expect(
        parent.partialHyperedgeIds,
        contains('parent:h2'),
        reason: 'Should reveal result hyperedge',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h0')),
        reason: 'Should NOT reveal accumIn_0',
      );
      expect(
        parent.partialHyperedgeIds,
        isNot(contains('parent:h1')),
        reason: 'Should NOT reveal accumIn',
      );
    });
  });
}
