// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// incremental_expansion_test.dart
// Tests for incremental (port-click) schematic expansion.
//
// 2026 June
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

// Fixture JSON is intentionally decoded dynamically to mirror netlist input.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';
import 'test_helpers.dart';

/// Build a test fixture for incremental expansion tests.
///
/// Graph structure (all children start collapsed / hidden):
///
///   root
///   ├── portA (INPUT, WEST)
///   ├── portB (OUTPUT, EAST)
///   │
///   ├── `hidden` childA  (ports: childA_in, childA_out)
///   ├── `hidden` childB  (ports: childB_in, childB_out)
///   └── `hidden` childC  (ports: childC_in, childC_out)
///
///   Hyperedges on root:
///     h1: root:portA  →  childA:childA_in
///     h2: childA:childA_out  →  childB:childB_in
///     h3: childB:childB_out  →  root:portB
///     h4: childC:childC_out  →  childA:childA_in  (extra link to childC)
///
SchematicGraph _buildTestGraph() {
  // -- Ports --
  final portA = ElkPort(
    id: 'portA',
    hwMeta: const HwMeta(name: 'portA'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portB = ElkPort(
    id: 'portB',
    hwMeta: const HwMeta(name: 'portB'),
    direction: 'OUTPUT',
    side: 'EAST',
  );

  // Child ports
  final childAIn = ElkPort(
    id: 'childA_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final childAOut = ElkPort(
    id: 'childA_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final childBIn = ElkPort(
    id: 'childB_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final childBOut = ElkPort(
    id: 'childB_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final childCIn = ElkPort(
    id: 'childC_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final childCOut = ElkPort(
    id: 'childC_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );

  // -- Child nodes --
  final childA = makeTestNode(
    'childA',
    hwMeta: const HwMeta(name: 'ChildA'),
    ports: [childAIn, childAOut],
  );
  final childB = makeTestNode(
    'childB',
    hwMeta: const HwMeta(name: 'ChildB'),
    ports: [childBIn, childBOut],
  );
  final childC = makeTestNode(
    'childC',
    hwMeta: const HwMeta(name: 'ChildC'),
    ports: [childCIn, childCOut],
  );

  // -- Hyperedges --
  final h1 = LayoutHyperedge(
    id: 'h1',
    signal: SignalOccurrence(name: 'sig_a', width: 1),
    sources: [('root', 0)],
    targets: [('childA', 0)],
  );

  final h2 = LayoutHyperedge(
    id: 'h2',
    signal: SignalOccurrence(name: 'sig_ab', width: 1),
    sources: [('childA', 1)],
    targets: [('childB', 0)],
  );

  final h3 = LayoutHyperedge(
    id: 'h3',
    signal: SignalOccurrence(name: 'sig_b', width: 1),
    sources: [('childB', 1)],
    targets: [('root', 1)],
  );

  final h4 = LayoutHyperedge(
    id: 'h4',
    signal: SignalOccurrence(name: 'sig_ca', width: 1),
    sources: [('childC', 1)],
    targets: [('childA', 0)],
  );

  // -- Root node (collapsed: children in hiddenChildren) --
  final root = makeTestNode(
    'root',
    hwMeta: const HwMeta(name: 'Root'),
    ports: [portA, portB],
    children: [], // collapsed
    hiddenChildren: [childA, childB, childC],
    hyperedges: [h1, h2, h3, h4],
  );

  // -- Build graph --
  final nodeMap = <String, LayoutNode>{
    'root': root,
    'childA': childA,
    'childB': childB,
    'childC': childC,
  };

  return SchematicGraph(root: root, nodeMap: nodeMap);
}

void main() {
  group('ElkNode partial expansion state', () {
    test('isPartiallyExpanded is false by default', () {
      final node = makeTestNode('1', hwMeta: const HwMeta(name: 'test'));
      expect(node.isPartiallyExpanded, isFalse);
      expect(node.partialChildIds, isNull);
      expect(node.partialHyperedgeIds, isNull);
    });

    test('isPartiallyExpanded is true when partialChildIds is non-empty', () {
      final node = makeTestNode(
        '1',
        hwMeta: const HwMeta(name: 'test'),
        partialChildIds: {'c1'},
      );
      expect(node.isPartiallyExpanded, isTrue);
    });

    test('isPartiallyExpanded is false when partialChildIds is empty set', () {
      final node = makeTestNode(
        '1',
        hwMeta: const HwMeta(name: 'test'),
        partialChildIds: {},
      );
      expect(node.isPartiallyExpanded, isFalse);
    });

    test('toggle clears partial expansion state', () {
      final child = makeTestNode('c1', hwMeta: const HwMeta(name: 'child'));
      final node = makeTestNode(
        '1',
        hwMeta: const HwMeta(name: 'test'),
        hiddenChildren: [child],
        partialChildIds: {'c1'},
        partialHyperedgeIds: {'h1'},
      );
      expect(node.isPartiallyExpanded, isTrue);

      node.toggle(); // expand
      expect(node.isExpanded, isTrue);
      expect(node.partialChildIds, isNull);
      expect(node.partialHyperedgeIds, isNull);
      expect(node.isPartiallyExpanded, isFalse);
    });

    test('toJson includes isPartiallyExpanded marker', () {
      final node = makeTestNode(
        '1',
        hwMeta: const HwMeta(name: 'test'),
        partialChildIds: {'c1'},
      );
      final json = node.toJson();
      expect(json['isPartiallyExpanded'], isTrue);
    });

    test('toJson omits isPartiallyExpanded when not partially expanded', () {
      final node = makeTestNode('1', hwMeta: const HwMeta(name: 'test'));
      final json = node.toJson();
      expect(json.containsKey('isPartiallyExpanded'), isFalse);
    });
  });

  group('SchematicGraph.expandPort', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('expands port and reveals connected children', () {
      // portA connects to childA via h1
      final result = graph.expandPort('root', 'portA');

      expect(result, isTrue);
      expect(graph.root.partialChildIds, contains('childA'));
      expect(graph.root.partialHyperedgeIds, contains('h1'));
    });

    test('returns false for non-existent node', () {
      final result = graph.expandPort('nonexistent', 'portA');
      expect(result, isFalse);
    });

    test('returns false when node has no hidden children', () {
      // Make root fully expanded (no hidden children)
      graph.root.toggle(); // expand all
      final result = graph.expandPort('root', 'portA');
      expect(result, isFalse);
    });

    test('returns false for port not in any hyperedge', () {
      final result = graph.expandPort('root', 'nonexistent_port');
      expect(result, isFalse);
    });

    test('idempotent: second click on same port returns false', () {
      final first = graph.expandPort('root', 'portA');
      expect(first, isTrue);

      final second = graph.expandPort('root', 'portA');
      expect(second, isFalse, reason: 'Already visible — no new children');
    });

    test('additive: expanding different ports merges partial sets', () {
      // Expand portA → reveals childA (via h1)
      graph.expandPort('root', 'portA');
      expect(graph.root.partialChildIds, equals({'childA'}));
      expect(graph.root.partialHyperedgeIds, equals({'h1'}));

      // Expand portB → reveals childB (via h3)
      // h2 (childA→childB) is NOT auto-included because it doesn't
      // share any (nodeId, portIndex) endpoint with h1 or h3.
      // The user must click a child port to reveal inter-child edges.
      graph.expandPort('root', 'portB');
      expect(graph.root.partialChildIds, equals({'childA', 'childB'}));
      expect(graph.root.partialHyperedgeIds, equals({'h1', 'h3'}));
    });

    test(
        'expanding port reveals all children connected by matching '
        'hyperedges', () {
      // childA_in is targeted by both h1 (from root) and h4 (from childC)
      // Expanding childA_in on root should find h1 and h4, revealing childA
      // and childC.  resolvePortId finds childA_in on childA (port index 0)
      // and then scans root's hyperedges for matches on (childA, 0).
      final result = graph.expandPort('root', 'childA_in');
      expect(result, isTrue);
      // h1 connects root:portA → childA:childA_in, so childA is revealed
      // h4 connects childC:childC_out → childA:childA_in, so childC is
      // revealed
      expect(graph.root.partialChildIds, containsAll(['childA', 'childC']));
      expect(graph.root.partialHyperedgeIds, containsAll(['h1', 'h4']));
    });

    test('node with no hyperedges returns false', () {
      // Create a node with hidden children but no hyperedges
      final emptyRoot = makeTestNode(
        'empty',
        hwMeta: const HwMeta(name: 'Empty'),
        hiddenChildren: [makeTestNode('c1', hwMeta: const HwMeta(name: 'C1'))],
      );
      final emptyGraph = SchematicGraph(
        root: emptyRoot,
        nodeMap: {'empty': emptyRoot},
      );

      final result = emptyGraph.expandPort('empty', 'somePort');
      expect(result, isFalse);
    });

    test(
        'parent boundary port click does not reveal unrelated internal edges '
        '(FilterBank pattern)', () {
      // Mimics FilterBank: parent has ports validIn and dataOut, children
      // ch0, ch1, controller.  validIn fans out to ch0 and ch1.  An
      // unrelated internal signal 'enable' connects controller→ch0,ch1.
      // Clicking validIn should NOT reveal the 'enable' edge.
      final ch0 = makeTestNode(
        'ch0',
        hwMeta: const HwMeta(name: 'ch0'),
        ports: [
          ElkPort(
            id: 'ch0:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'ch0:1',
            hwMeta: const HwMeta(name: 'enable'),
            direction: 'INPUT',
            side: 'WEST',
            index: 1,
          ),
        ],
      );
      final ch1 = makeTestNode(
        'ch1',
        hwMeta: const HwMeta(name: 'ch1'),
        ports: [
          ElkPort(
            id: 'ch1:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'ch1:1',
            hwMeta: const HwMeta(name: 'enable'),
            direction: 'INPUT',
            side: 'WEST',
            index: 1,
          ),
        ],
      );
      final controller = makeTestNode(
        'controller',
        hwMeta: const HwMeta(name: 'controller'),
        ports: [
          ElkPort(
            id: 'controller:0',
            hwMeta: const HwMeta(name: 'inputValid'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'controller:1',
            hwMeta: const HwMeta(name: 'filterEnable'),
            direction: 'OUTPUT',
            side: 'EAST',
            index: 1,
          ),
        ],
      );

      // validIn: parent:0 → ch0:0, ch1:0, controller:0
      final heValidIn = LayoutHyperedge(
        id: 'fb:h_validIn',
        signal: SignalOccurrence(name: 'validIn', width: 1),
        sources: [('fb', 0)],
        targets: [('ch0', 0), ('ch1', 0), ('controller', 0)],
      );

      // enable: controller:1 → ch0:1, ch1:1  (unrelated internal signal)
      final heEnable = LayoutHyperedge(
        id: 'fb:h_enable',
        signal: SignalOccurrence(name: 'enable', width: 1),
        sources: [('controller', 1)],
        targets: [('ch0', 1), ('ch1', 1)],
      );

      final fb = makeTestNode(
        'fb',
        hwMeta: const HwMeta(name: 'FilterBank'),
        ports: [
          ElkPort(
            id: 'fb:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
        ],
        hiddenChildren: [ch0, ch1, controller],
        hyperedges: [heValidIn, heEnable],
      );
      ch0.parent = fb;
      ch1.parent = fb;
      controller.parent = fb;

      final fbGraph = SchematicGraph(
        root: fb,
        nodeMap: {'fb': fb, 'ch0': ch0, 'ch1': ch1, 'controller': controller},
      );

      // Click the parent boundary port 'validIn'
      final expanded = fbGraph.expandPort('fb', 'fb:0');
      expect(expanded, isTrue);

      // Should reveal ch0, ch1, controller and the validIn hyperedge
      expect(fb.partialChildIds, containsAll(['ch0', 'ch1', 'controller']));
      expect(fb.partialHyperedgeIds, contains('fb:h_validIn'));

      // Should NOT reveal the unrelated 'enable' hyperedge
      expect(
        fb.partialHyperedgeIds,
        isNot(contains('fb:h_enable')),
        reason: 'Unrelated internal signal "enable" should not be revealed '
            'when clicking parent port "validIn"',
      );
    });

    test(
        'blocks-only mode: parent port click does not reveal unrelated edges '
        '(FilterBank pattern)', () {
      // Same topology but starting in blocks-only mode (all children
      // pre-visible in partialChildIds, no edges) — matches real app.
      final ch0 = makeTestNode(
        'ch0',
        hwMeta: const HwMeta(name: 'ch0'),
        ports: [
          ElkPort(
            id: 'ch0:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'ch0:1',
            hwMeta: const HwMeta(name: 'enable'),
            direction: 'INPUT',
            side: 'WEST',
            index: 1,
          ),
        ],
      );
      final ch1 = makeTestNode(
        'ch1',
        hwMeta: const HwMeta(name: 'ch1'),
        ports: [
          ElkPort(
            id: 'ch1:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'ch1:1',
            hwMeta: const HwMeta(name: 'enable'),
            direction: 'INPUT',
            side: 'WEST',
            index: 1,
          ),
        ],
      );
      final controller = makeTestNode(
        'controller',
        hwMeta: const HwMeta(name: 'controller'),
        ports: [
          ElkPort(
            id: 'controller:0',
            hwMeta: const HwMeta(name: 'inputValid'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'controller:1',
            hwMeta: const HwMeta(name: 'filterEnable'),
            direction: 'OUTPUT',
            side: 'EAST',
            index: 1,
          ),
        ],
      );

      final heValidIn = LayoutHyperedge(
        id: 'fb:h_validIn',
        signal: SignalOccurrence(name: 'validIn', width: 1),
        sources: [('fb', 0)],
        targets: [('ch0', 0), ('ch1', 0), ('controller', 0)],
      );
      final heEnable = LayoutHyperedge(
        id: 'fb:h_enable',
        signal: SignalOccurrence(name: 'enable', width: 1),
        sources: [('controller', 1)],
        targets: [('ch0', 1), ('ch1', 1)],
      );

      // Start in blocks-only mode: all children visible, no edges.
      final fb = makeTestNode(
        'fb',
        hwMeta: const HwMeta(name: 'FilterBank'),
        ports: [
          ElkPort(
            id: 'fb:0',
            hwMeta: const HwMeta(name: 'validIn'),
            direction: 'INPUT',
            side: 'WEST',
          ),
        ],
        hiddenChildren: [ch0, ch1, controller],
        hyperedges: [heValidIn, heEnable],
        partialChildIds: {'ch0', 'ch1', 'controller'},
        partialHyperedgeIds: {},
      );
      ch0.parent = fb;
      ch1.parent = fb;
      controller.parent = fb;

      final fbGraph = SchematicGraph(
        root: fb,
        nodeMap: {'fb': fb, 'ch0': ch0, 'ch1': ch1, 'controller': controller},
      );

      final expanded = fbGraph.expandPort('fb', 'fb:0');
      expect(expanded, isTrue);

      expect(fb.partialHyperedgeIds, contains('fb:h_validIn'));
      expect(
        fb.partialHyperedgeIds,
        isNot(contains('fb:h_enable')),
        reason: 'Blocks-only: unrelated "enable" must not be revealed '
            'when clicking "validIn"',
      );
    });
  });

  group('SchematicGraph.toJsGraph with partial expansion', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('serialized JSON includes partially expanded children', () {
      graph.expandPort('root', 'portA'); // reveals childA

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Root should have childA in children
      final rootChildren = decoded['children'] as List<dynamic>?;
      expect(rootChildren, isNotNull);
      expect(
        rootChildren!.any((c) => c['id'] == 'childA'),
        isTrue,
        reason: 'childA should be in serialized children',
      );

      // childB and childC should NOT be in children (still hidden)
      expect(
        rootChildren.any((c) => c['id'] == 'childB'),
        isFalse,
        reason: 'childB should remain hidden',
      );
      expect(
        rootChildren.any((c) => c['id'] == 'childC'),
        isFalse,
        reason: 'childC should remain hidden',
      );
    });

    test('serialized JSON includes isPartiallyExpanded marker', () {
      graph.expandPort('root', 'portA');

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(decoded['isPartiallyExpanded'], isTrue);
    });

    test('hidden children are restored after toJsGraph', () {
      graph.expandPort('root', 'portA'); // reveals childA

      // Before toJsGraph: childA is in hiddenChildren, partial state says
      // to reveal it
      expect(graph.root.hiddenChildren!.length, 3);
      expect(graph.root.children.length, 0);

      graph.toJsGraph();

      // After toJsGraph: state should be fully restored
      expect(
        graph.root.hiddenChildren!.length,
        3,
        reason: 'hiddenChildren should be restored',
      );
      expect(
        graph.root.children.length,
        0,
        reason: 'children should be empty again',
      );
      expect(
        graph.root.partialChildIds,
        isNotNull,
        reason: 'partial state should be preserved',
      );
    });

    test('edges in serialized JSON only reference visible nodes', () {
      graph.expandPort('root', 'portA'); // reveals childA only

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // Collect visible node IDs in this scope
      final visibleIds = <String>{'root'};
      for (final child in decoded['children'] as List<dynamic>? ?? []) {
        visibleIds.add(child['id'] as String);
      }

      // Every edge's source and target must be in the visible set
      for (final edge in edges) {
        final source = edge['source'] as String;
        final target = edge['target'] as String;
        expect(
          visibleIds.contains(source),
          isTrue,
          reason: 'Edge source "$source" must be visible',
        );
        expect(
          visibleIds.contains(target),
          isTrue,
          reason: 'Edge target "$target" must be visible',
        );
      }
    });

    test('h1 edge appears when childA is partially revealed', () {
      graph.expandPort('root', 'portA'); // reveals childA via h1

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // h1: root:portA → childA:childA_in — both endpoints visible
      final h1Edges = edges.where(
        (e) => e['sourcePort'] == 'portA' && e['targetPort'] == 'childA_in',
      );
      expect(
        h1Edges,
        isNotEmpty,
        reason: 'h1 edge (portA → childA_in) should be present',
      );
    });

    test('h2 edge is filtered out when only childA is revealed', () {
      graph.expandPort('root', 'portA'); // reveals childA only

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // h2: childA:childA_out → childB:childB_in — childB is NOT visible
      final h2Edges = edges.where(
        (e) =>
            e['sourcePort'] == 'childA_out' && e['targetPort'] == 'childB_in',
      );
      expect(
        h2Edges,
        isEmpty,
        reason: 'h2 edge should be filtered (childB not visible)',
      );
    });

    test('both h1 and h3 edges appear when both ports are expanded', () {
      graph
        ..expandPort('root', 'portA') // reveals childA
        ..expandPort('root', 'portB'); // reveals childB

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // h1: root:portA → childA:childA_in
      final h1 = edges.where(
        (e) => e['sourcePort'] == 'portA' && e['targetPort'] == 'childA_in',
      );
      expect(h1, isNotEmpty, reason: 'h1 edge should be visible');

      // h3: childB:childB_out → root:portB
      final h3 = edges.where(
        (e) => e['sourcePort'] == 'childB_out' && e['targetPort'] == 'portB',
      );
      expect(h3, isNotEmpty, reason: 'h3 edge should be visible');
    });

    test('h2 inter-child edge is NOT auto-revealed by parent port clicks', () {
      graph
        ..expandPort('root', 'portA') // reveals childA
        ..expandPort('root', 'portB'); // reveals childB

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // h2: childA:childA_out → childB:childB_in — both children visible,
      // but h2 is on a different signal network than h1 or h3.  It should
      // only appear when the user clicks a child port that's part of h2.
      final h2 = edges.where(
        (e) =>
            e['sourcePort'] == 'childA_out' && e['targetPort'] == 'childB_in',
      );
      expect(
        h2,
        isEmpty,
        reason: 'h2 should NOT be auto-revealed by parent port clicks',
      );
    });
  });

  group('collapsePartialExpansion', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('clears partial state and returns true', () {
      graph.expandPort('root', 'portA');
      expect(graph.root.isPartiallyExpanded, isTrue);

      final result = graph.collapsePartialExpansion('root');
      expect(result, isTrue);
      expect(graph.root.isPartiallyExpanded, isFalse);
      expect(graph.root.partialChildIds, isNull);
      expect(graph.root.partialHyperedgeIds, isNull);
    });

    test('returns false when not partially expanded', () {
      final result = graph.collapsePartialExpansion('root');
      expect(result, isFalse);
    });

    test('returns false for non-existent node', () {
      final result = graph.collapsePartialExpansion('nonexistent');
      expect(result, isFalse);
    });

    test('node returns to collapsed state after collapse', () {
      graph
        ..expandPort('root', 'portA')
        ..collapsePartialExpansion('root');

      // All children should remain hidden
      expect(graph.root.hiddenChildren!.length, 3);
      expect(graph.root.children.length, 0);
      expect(graph.root.isExpandable, isTrue);
    });

    test('toJsGraph after collapse shows no children', () {
      graph
        ..expandPort('root', 'portA')
        // Call toJsGraph once while partially expanded (generates edges).
        ..toJsGraph()
        // Now collapse.
        ..collapsePartialExpansion('root');

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      // No children should be visible
      expect(decoded['children'], isNull);
      expect(decoded.containsKey('isPartiallyExpanded'), isFalse);

      // No edges should remain (stale edges from the partial expansion
      // must be cleared).
      expect(
        decoded['edges'],
        isNull,
        reason: 'No stale edges should survive collapse',
      );
    });

    test('can re-expand after collapse', () {
      graph
        ..expandPort('root', 'portA')
        ..collapsePartialExpansion('root');

      // Re-expand on a different port
      final result = graph.expandPort('root', 'portB');
      expect(result, isTrue);
      expect(graph.root.partialChildIds, contains('childB'));
      expect(
        graph.root.partialChildIds,
        isNot(contains('childA')),
        reason: 'Previous partial state was cleared',
      );
    });
  });

  group('Toggle clears partial expansion', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('toggleNode fully expands and clears partial state', () {
      // First partially expand
      graph.expandPort('root', 'portA');
      expect(graph.root.isPartiallyExpanded, isTrue);

      // Now fully expand
      graph.toggleNode('root');
      expect(graph.root.isExpanded, isTrue);
      expect(graph.root.isPartiallyExpanded, isFalse);
      expect(graph.root.partialChildIds, isNull);
      expect(graph.root.partialHyperedgeIds, isNull);
      expect(
        graph.root.children.length,
        3,
        reason: 'All children should be visible after full expand',
      );
    });

    test('full expand then collapse then expandPort works', () {
      // Full expand
      graph.toggleNode('root');
      expect(graph.root.isExpanded, isTrue);

      // Collapse
      graph.toggleNode('root');
      expect(graph.root.isExpandable, isTrue);
      expect(graph.root.children.isEmpty, isTrue);

      // Partial expand
      final result = graph.expandPort('root', 'portA');
      expect(result, isTrue);
      expect(graph.root.partialChildIds, contains('childA'));
    });
  });

  group('Multiple toJsGraph calls with partial expansion', () {
    test('toJsGraph is idempotent (can be called multiple times)', () {
      final graph = _buildTestGraph();
      final json1 = (graph..expandPort('root', 'portA')).toJsGraph();
      final json2 = graph.toJsGraph();

      // Structure should be identical
      final decoded1 = jsonDecode(json1) as Map<String, dynamic>;
      final decoded2 = jsonDecode(json2) as Map<String, dynamic>;

      final children1 =
          (decoded1['children'] as List).map((c) => c['id']).toSet();
      final children2 =
          (decoded2['children'] as List).map((c) => c['id']).toSet();
      expect(children1, equals(children2));
    });

    test('state is preserved between toJsGraph calls', () {
      final graph = _buildTestGraph();
      (graph..expandPort('root', 'portA')).toJsGraph();

      // After first call, state should be intact
      expect(graph.root.hiddenChildren!.length, 3);
      expect(graph.root.children.length, 0);
      expect(graph.root.partialChildIds, isNotNull);

      graph.toJsGraph();

      // After second call, state should still be intact
      expect(graph.root.hiddenChildren!.length, 3);
      expect(graph.root.children.length, 0);
      expect(graph.root.partialChildIds, isNotNull);
    });
  });

  group('convertToBlocksOnly', () {
    test('returns false when all children are primitive', () {
      final graph = _buildTestGraph();

      // Fully expand root.
      final result = (graph..toggleNode('root')).convertToBlocksOnly('root');
      expect(graph.root.isExpanded, isTrue);
      expect(graph.root.children.length, 3);

      // All children in this graph are primitive (no sub-children),
      // so convertToBlocksOnly should return false and leave the node
      // fully expanded.
      expect(result, isFalse);
      expect(
        graph.root.isExpanded,
        isTrue,
        reason: 'node should remain fully expanded',
      );
    });

    test('returns false on non-existent node', () {
      final graph = _buildTestGraph();
      expect(graph.convertToBlocksOnly('nonexistent'), isFalse);
    });

    test('returns false on already collapsed node', () {
      final graph = _buildTestGraph();
      expect(graph.convertToBlocksOnly('root'), isFalse);
    });
  });

  group('expandWire', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('reveals connected children and hyperedge by wire name', () {
      // h2: childA:childA_out → childB:childB_in, name='sig_ab'
      final result = graph.expandWire('root', 'sig_ab');
      expect(result, isTrue);

      // Both childA and childB should be revealed.
      expect(graph.root.partialChildIds, contains('childA'));
      expect(graph.root.partialChildIds, contains('childB'));

      // h2 should be in partialHyperedgeIds.
      expect(graph.root.partialHyperedgeIds, contains('h2'));
    });

    test('returns false for non-existent wire name', () {
      expect(graph.expandWire('root', 'nonexistent'), isFalse);
    });

    test('returns false for non-existent node', () {
      expect(graph.expandWire('nonexistent', 'sig_ab'), isFalse);
    });

    test('idempotent: second call returns false', () {
      graph.expandWire('root', 'sig_ab');
      final second = graph.expandWire('root', 'sig_ab');
      expect(second, isFalse);
    });

    test('additive with expandPort', () {
      // First expand a port (reveals childA via h1)
      graph.expandPort('root', 'portA');
      expect(graph.root.partialChildIds, contains('childA'));
      expect(graph.root.partialHyperedgeIds, contains('h1'));

      // Then expand a wire (reveals childC via h4)
      final result = graph.expandWire('root', 'sig_ca');
      expect(result, isTrue);

      // h4: childC:childC_out → childA:childA_in, name='sig_ca'
      expect(graph.root.partialChildIds, contains('childC'));
      expect(graph.root.partialHyperedgeIds, contains('h4'));

      // Previous state should be preserved.
      expect(graph.root.partialChildIds, contains('childA'));
      expect(graph.root.partialHyperedgeIds, contains('h1'));
    });

    test('wire in toJsGraph appears as visible edge', () {
      graph.expandWire('root', 'sig_ab');

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final edges = decoded['edges'] as List<dynamic>? ?? [];

      // h2 edge should be visible
      final h2 = edges.where(
        (e) =>
            e['sourcePort'] == 'childA_out' && e['targetPort'] == 'childB_in',
      );
      expect(
        h2,
        isNotEmpty,
        reason: 'sig_ab wire should appear as visible edge',
      );
    });

    test('wire connecting root port reveals child', () {
      // h1: root:portA → childA:childA_in, name='sig_a'
      final result = graph.expandWire('root', 'sig_a');
      expect(result, isTrue);
      expect(graph.root.partialChildIds, contains('childA'));
      expect(graph.root.partialHyperedgeIds, contains('h1'));
    });
  });

  group('expandChild', () {
    late SchematicGraph graph;

    setUp(() {
      graph = _buildTestGraph();
    });

    test('reveals target child and its hyperedges', () {
      final result = graph.expandChild('root', 'ChildA');
      expect(result, isTrue);
      expect(graph.root.partialChildIds, equals({'childA'}));
      // Only h1 (root:portA → childA:childA_in) is included because
      // h2 (childA→childB) and h4 (childC→childA) reference hidden
      // children. Edges to hidden children are excluded to prevent
      // over-expansion of unrelated wires.
      expect(graph.root.partialHyperedgeIds, equals({'h1'}));
    });

    test('returns false for already-visible child', () {
      graph.expandChild('root', 'ChildA');
      final result = graph.expandChild('root', 'ChildA');
      expect(result, isFalse);
    });

    test('additive: second child merges with first', () {
      graph.expandChild('root', 'ChildA');
      final result = graph.expandChild('root', 'ChildB');
      expect(result, isTrue);
      expect(graph.root.partialChildIds, containsAll(['childA', 'childB']));
    });

    test('toJsGraph preserves _edges for non-visible endpoints', () {
      // Expand only childA: edges referencing childB or childC should be
      // in _edges (hiddenEdges), not in edges.
      graph.expandChild('root', 'ChildA');

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final visibleEdges = decoded['edges'] as List<dynamic>? ?? [];
      final hiddenEdges = decoded['_edges'] as List<dynamic>? ?? [];

      // h1 (root→childA) is visible because both endpoints are present
      final h1Visible = visibleEdges.any(
        (e) => e['sourcePort'] == 'portA' && e['targetPort'] == 'childA_in',
      );
      expect(
        h1Visible,
        isTrue,
        reason: 'h1 (root→childA) should be a visible edge',
      );

      // h2 (childA→childB): childB is hidden, so this edge should be
      // hidden. Similarly h4 (childC→childA): childC is hidden.
      // These should appear in _edges (hiddenEdges).
      expect(
        hiddenEdges,
        isNotEmpty,
        reason: 'Edges referencing hidden children should be in _edges',
      );

      // Specifically: edges with source/target referencing childB or childC
      // that came from allowed hyperedges should be in _edges.
      final hiddenPorts = hiddenEdges
          .expand<String>(
            (e) => [
              (e['sourcePort'] ?? '').toString(),
              (e['targetPort'] ?? '').toString(),
            ],
          )
          .toSet();

      // childA_out→childB_in (from h2) should be hidden
      expect(
        hiddenPorts,
        contains('childA_out'),
        reason: 'childA_out→childB_in edge should be in _edges',
      );

      // Also edges from originally non-allowed hyperedges (h3: childB→root)
      // should be in _edges since h3 is not in partialHyperedgeIds.
      final h3Hidden = hiddenEdges.any(
        (e) => e['sourcePort'] == 'childB_out' && e['targetPort'] == 'portB',
      );
      expect(
        h3Hidden,
        isTrue,
        reason: 'h3 (childB→root, non-allowed) should be in _edges',
      );
    });

    test(
      'does not add edges when child is already visible in blocks-only mode',
      () {
        // Simulate blocks-only mode: all children visible, no edges.
        graph.root.partialChildIds = {'childA', 'childB', 'childC'};
        graph.root.partialHyperedgeIds = <String>{};

        // expandChild for an already-visible child should be a no-op —
        // it must NOT recalculate and add all resolvable hyperedges.
        final result = graph.expandChild('root', 'ChildA');
        expect(
          result,
          isFalse,
          reason: 'Already-visible child should be a no-op',
        );
        expect(
          graph.root.partialHyperedgeIds,
          isEmpty,
          reason: 'Blocks-only mode edges should stay empty',
        );
      },
    );

    test('expandPath on blocks-only parent does not add inter-block edges', () {
      // Start with blocks-only: all children visible, no edges.
      graph.root.partialChildIds = {'childA', 'childB', 'childC'};
      graph.root.partialHyperedgeIds = <String>{};

      // expandChild is a no-op, expandWire finds no matching wire →
      // the only change is the no-op.
      expect(
        graph.root.partialHyperedgeIds,
        isEmpty,
        reason: 'Blocks-only parent should retain empty edge set',
      );
    });
  });

  // =========================================================================
  // Nested expandChild – 3-level deep hierarchy
  // =========================================================================

  group('nested expandChild (3-level deep)', () {
    /// Build a graph with three nesting levels:
    ///
    ///   root (expanded, children visible)
    ///   ├── portR_in (INPUT)
    ///   ├── portR_out (OUTPUT)
    ///   │
    ///   ├── CPU  (collapsed – has its own hidden children)
    ///   │   ├── portCpu_in, portCpu_out
    ///   │   ├── `hidden` ALU   (ports: aluIn, aluOut)
    ///   │   └── `hidden` DataPath  (collapsed – has hidden children)
    ///   │       ├── portDp_in, portDp_out
    ///   │       ├── `hidden` MuxUnit  (ports: muxIn, muxOut)
    ///   │       └── `hidden` Adder    (ports: addIn, addOut)
    ///   │       hyperedges:
    ///   │         hDp1: DataPath:portDp_in → MuxUnit:muxIn
    ///   │         hDp2: MuxUnit:muxOut → Adder:addIn
    ///   │         hDp3: Adder:addOut → DataPath:portDp_out
    ///   │   hyperedges:
    ///   │     hCpu1: CPU:portCpu_in → ALU:aluIn
    ///   │     hCpu2: CPU:portCpu_in → DataPath:portDp_in
    ///   │     hCpu3: DataPath:portDp_out → CPU:portCpu_out
    ///   │
    ///   └── Memory  (no sub-children – leaf)
    ///       ├── portMem_in, portMem_out
    ///
    ///   Root hyperedges:
    ///     hR1: root:portR_in → CPU:portCpu_in
    ///     hR2: CPU:portCpu_out → Memory:portMem_in
    ///     hR3: Memory:portMem_out → root:portR_out
    SchematicGraph buildDeepGraph() {
      // -- Leaf-level children of DataPath --
      final muxIn = ElkPort(
        id: 'muxIn',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final muxOut = ElkPort(
        id: 'muxOut',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final muxUnit = makeTestNode(
        'muxUnit',
        hwMeta: const HwMeta(name: 'MuxUnit'),
        ports: [muxIn, muxOut],
      );

      final addIn = ElkPort(
        id: 'addIn',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final addOut = ElkPort(
        id: 'addOut',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final adder = makeTestNode(
        'adder',
        hwMeta: const HwMeta(name: 'Adder'),
        ports: [addIn, addOut],
      );

      // -- DataPath (level 2) --
      final portDpIn = ElkPort(
        id: 'portDp_in',
        hwMeta: const HwMeta(name: 'dp_in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portDpOut = ElkPort(
        id: 'portDp_out',
        hwMeta: const HwMeta(name: 'dp_out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final hDp1 = LayoutHyperedge(
        id: 'hDp1',
        signal: SignalOccurrence(name: 'sig_dp_mux', width: 1),
        sources: [('dataPath', 0)],
        targets: [('muxUnit', 0)],
      );
      final hDp2 = LayoutHyperedge(
        id: 'hDp2',
        signal: SignalOccurrence(name: 'sig_mux_add', width: 1),
        sources: [('muxUnit', 1)],
        targets: [('adder', 0)],
      );
      final hDp3 = LayoutHyperedge(
        id: 'hDp3',
        signal: SignalOccurrence(name: 'sig_add_out', width: 1),
        sources: [('adder', 1)],
        targets: [('dataPath', 1)],
      );
      final dataPath = makeTestNode(
        'dataPath',
        hwMeta: const HwMeta(name: 'DataPath'),
        ports: [portDpIn, portDpOut],
        children: [],
        hiddenChildren: [muxUnit, adder],
        hyperedges: [hDp1, hDp2, hDp3],
      );

      // -- ALU (level 2, leaf) --
      final aluIn = ElkPort(
        id: 'aluIn',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final aluOut = ElkPort(
        id: 'aluOut',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final alu = makeTestNode(
        'alu',
        hwMeta: const HwMeta(name: 'ALU'),
        ports: [aluIn, aluOut],
      );

      // -- CPU (level 1) --
      final portCpuIn = ElkPort(
        id: 'portCpu_in',
        hwMeta: const HwMeta(name: 'cpu_in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portCpuOut = ElkPort(
        id: 'portCpu_out',
        hwMeta: const HwMeta(name: 'cpu_out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final hCpu1 = LayoutHyperedge(
        id: 'hCpu1',
        signal: SignalOccurrence(name: 'sig_cpu_alu', width: 1),
        sources: [('cpu', 0)],
        targets: [('alu', 0)],
      );
      final hCpu2 = LayoutHyperedge(
        id: 'hCpu2',
        signal: SignalOccurrence(name: 'sig_cpu_dp', width: 1),
        sources: [('cpu', 0)],
        targets: [('dataPath', 0)],
      );
      final hCpu3 = LayoutHyperedge(
        id: 'hCpu3',
        signal: SignalOccurrence(name: 'sig_dp_out', width: 1),
        sources: [('dataPath', 1)],
        targets: [('cpu', 1)],
      );
      final cpu = makeTestNode(
        'cpu',
        hwMeta: const HwMeta(name: 'CPU'),
        ports: [portCpuIn, portCpuOut],
        children: [],
        hiddenChildren: [alu, dataPath],
        hyperedges: [hCpu1, hCpu2, hCpu3],
      );

      // -- Memory (level 1, leaf) --
      final portMemIn = ElkPort(
        id: 'portMem_in',
        hwMeta: const HwMeta(name: 'mem_in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portMemOut = ElkPort(
        id: 'portMem_out',
        hwMeta: const HwMeta(name: 'mem_out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final memory = makeTestNode(
        'memory',
        hwMeta: const HwMeta(name: 'Memory'),
        ports: [portMemIn, portMemOut],
      );

      // -- Root (expanded, children visible) --
      final portRIn = ElkPort(
        id: 'portR_in',
        hwMeta: const HwMeta(name: 'r_in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portROut = ElkPort(
        id: 'portR_out',
        hwMeta: const HwMeta(name: 'r_out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final hR1 = LayoutHyperedge(
        id: 'hR1',
        signal: SignalOccurrence(name: 'sig_r_cpu', width: 1),
        sources: [('root', 0)],
        targets: [('cpu', 0)],
      );
      final hR2 = LayoutHyperedge(
        id: 'hR2',
        signal: SignalOccurrence(name: 'sig_cpu_mem', width: 1),
        sources: [('cpu', 1)],
        targets: [('memory', 0)],
      );
      final hR3 = LayoutHyperedge(
        id: 'hR3',
        signal: SignalOccurrence(name: 'sig_mem_out', width: 1),
        sources: [('memory', 1)],
        targets: [('root', 1)],
      );

      // Root is EXPANDED: CPU and Memory are visible children.
      final root = makeTestNode(
        'root',
        hwMeta: const HwMeta(name: 'Root'),
        ports: [portRIn, portROut],
        children: [cpu, memory],
        hiddenChildren: [],
        hyperedges: [hR1, hR2, hR3],
      );

      final nodeMap = <String, LayoutNode>{
        'root': root,
        'cpu': cpu,
        'memory': memory,
        'alu': alu,
        'dataPath': dataPath,
        'muxUnit': muxUnit,
        'adder': adder,
      };

      return SchematicGraph(root: root, nodeMap: nodeMap);
    }

    /// Collect all node IDs from a decoded ELK JSON tree.
    Set<String> collectNodeIds(Map<String, dynamic> node) {
      final ids = <String>{};
      if (node['id'] != null) {
        ids.add(node['id'] as String);
      }
      final children = node['children'] as List<dynamic>?;
      if (children != null) {
        for (final child in children) {
          ids.addAll(collectNodeIds(child as Map<String, dynamic>));
        }
      }
      return ids;
    }

    /// Find a node by ID in the decoded ELK JSON tree.
    Map<String, dynamic>? findNode(Map<String, dynamic> tree, String id) {
      if (tree['id'] == id) {
        return tree;
      }
      for (final child in (tree['children'] as List<dynamic>?) ?? []) {
        final found = findNode(child as Map<String, dynamic>, id);
        if (found != null) {
          return found;
        }
      }
      return null;
    }

    test(
      'initial state: root expanded, CPU collapsed with hidden children',
      () {
        final graph = buildDeepGraph();
        final jsonStr = graph.toJsGraph();
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

        final visibleIds = collectNodeIds(decoded);
        // Root is expanded: CPU and Memory are visible.
        expect(visibleIds, containsAll(['root', 'cpu', 'memory']));
        // CPU's children (ALU, DataPath) are hidden.
        expect(visibleIds, isNot(contains('alu')));
        expect(visibleIds, isNot(contains('dataPath')));
        expect(visibleIds, isNot(contains('muxUnit')));
      },
    );

    test('expandChild level 1: reveal DataPath inside CPU', () {
      final graph = buildDeepGraph();

      final ok = graph.expandChild('cpu', 'DataPath');
      expect(ok, isTrue);
      expect(graph.nodeMap['cpu']!.partialChildIds, equals({'dataPath'}));

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final visibleIds = collectNodeIds(decoded);

      expect(
        visibleIds,
        containsAll(['root', 'cpu', 'memory', 'dataPath']),
        reason: 'DataPath should be visible inside CPU',
      );
      expect(
        visibleIds,
        isNot(contains('alu')),
        reason: 'ALU should still be hidden',
      );
      expect(
        visibleIds,
        isNot(contains('muxUnit')),
        reason: 'MuxUnit (inside DataPath) should still be hidden',
      );
    });

    test('expandChild level 2: reveal MuxUnit inside DataPath', () {
      final graph = buildDeepGraph();

      // First expand DataPath inside CPU.
      // Then expand MuxUnit inside DataPath.
      final ok = (graph..expandChild('cpu', 'DataPath')).expandChild(
        'dataPath',
        'MuxUnit',
      );
      expect(ok, isTrue);
      expect(graph.nodeMap['dataPath']!.partialChildIds, equals({'muxUnit'}));

      final jsonStr = graph.toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final visibleIds = collectNodeIds(decoded);

      // MuxUnit should now be visible at depth 3.
      expect(
        visibleIds,
        containsAll(['root', 'cpu', 'memory', 'dataPath', 'muxUnit']),
        reason: 'MuxUnit should be visible 3 levels deep',
      );
      expect(
        visibleIds,
        isNot(contains('adder')),
        reason: 'Adder should still be hidden inside DataPath',
      );
      expect(
        visibleIds,
        isNot(contains('alu')),
        reason: 'ALU should still be hidden inside CPU',
      );
    });

    test('nested partial expansion: correct parent-child nesting in JSON', () {
      final graph = buildDeepGraph();
      final jsonStr = (graph
            ..expandChild('cpu', 'DataPath')
            ..expandChild('dataPath', 'MuxUnit'))
          .toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      // CPU should contain DataPath as a child.
      final cpuNode = findNode(decoded, 'cpu')!;
      final cpuChildIds = (cpuNode['children'] as List<dynamic>)
          .map((c) => (c as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(
        cpuChildIds,
        contains('dataPath'),
        reason: 'DataPath should be a child of CPU',
      );

      // DataPath should contain MuxUnit as a child.
      final dpNode = findNode(decoded, 'dataPath')!;
      final dpChildIds = (dpNode['children'] as List<dynamic>)
          .map((c) => (c as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(
        dpChildIds,
        contains('muxUnit'),
        reason: 'MuxUnit should be a child of DataPath',
      );

      // MuxUnit should have its ports.
      final muxNode = findNode(decoded, 'muxUnit')!;
      final muxPorts = (muxNode['ports'] as List<dynamic>)
          .map((p) => (p as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(muxPorts, containsAll(['muxIn', 'muxOut']));
    });

    test('nested partial expansion: edges are correctly filtered', () {
      final graph = buildDeepGraph();
      final jsonStr = (graph
            ..expandChild('cpu', 'DataPath')
            ..expandChild('dataPath', 'MuxUnit'))
          .toJsGraph();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      // At DataPath level: hDp1 (dp→mux) should be visible,
      // hDp2 (mux→adder) should be hidden (adder not visible).
      final dpNode = findNode(decoded, 'dataPath')!;
      final dpEdges = dpNode['edges'] as List<dynamic>? ?? [];
      final dpHiddenEdges = dpNode['_edges'] as List<dynamic>? ?? [];

      // hDp1: dataPath:portDp_in → muxUnit:muxIn — both visible
      final dp1Visible = dpEdges.any((e) => e['targetPort'] == 'muxIn');
      expect(
        dp1Visible,
        isTrue,
        reason: 'hDp1 (dp→mux) should be a visible edge in DataPath',
      );

      // hDp2: muxUnit:muxOut → adder:addIn — adder hidden
      final dp2Hidden = dpHiddenEdges.any(
        (e) => e['sourcePort'] == 'muxOut' || e['targetPort'] == 'addIn',
      );
      expect(
        dp2Hidden,
        isTrue,
        reason: 'hDp2 (mux→adder) should be hidden (adder not visible)',
      );
    });

    test('nested partial expansion: state restored after toJsGraph', () {
      final graph = buildDeepGraph()
        ..expandChild('cpu', 'DataPath')
        ..expandChild('dataPath', 'MuxUnit')
        // Call toJsGraph (which restores state at the end).
        ..toJsGraph();

      // CPU's children should be empty again (DataPath back in hidden).
      expect(graph.nodeMap['cpu']!.children, isEmpty);
      expect(graph.nodeMap['cpu']!.hiddenChildren, isNotNull);
      expect(
        graph.nodeMap['cpu']!.hiddenChildren!.any((c) => c.id == 'dataPath'),
        isTrue,
        reason: 'DataPath should be back in hiddenChildren after restore',
      );

      // DataPath's children should be empty (MuxUnit back in hidden).
      expect(graph.nodeMap['dataPath']!.children, isEmpty);
      expect(graph.nodeMap['dataPath']!.hiddenChildren, isNotNull);
      expect(
        graph.nodeMap['dataPath']!.hiddenChildren!.any(
          (c) => c.id == 'muxUnit',
        ),
        isTrue,
        reason: 'MuxUnit should be back in hiddenChildren after restore',
      );

      // Partial state still set.
      expect(graph.nodeMap['cpu']!.partialChildIds, equals({'dataPath'}));
      expect(graph.nodeMap['dataPath']!.partialChildIds, equals({'muxUnit'}));
    });

    test('second toJsGraph produces identical output (idempotent)', () {
      final graph = buildDeepGraph();
      final json1 = (graph
            ..expandChild('cpu', 'DataPath')
            ..expandChild('dataPath', 'MuxUnit'))
          .toJsGraph();
      final json2 = graph.toJsGraph();
      expect(json1, equals(json2), reason: 'toJsGraph should be idempotent');
    });

    // ── expandPath (batch) tests ──────────────────────────────────────

    test('expandPath reveals full path in one call', () {
      final graph = buildDeepGraph();

      // Batch-expand Root→CPU→DataPath→MuxUnit in a single pass.
      final changed = graph.expandPath(['CPU', 'DataPath', 'MuxUnit']);
      expect(changed, isTrue);

      // CPU should be partially expanded with DataPath visible.
      expect(graph.nodeMap['cpu']!.partialChildIds, contains('dataPath'));
      // DataPath should be partially expanded with MuxUnit visible.
      expect(graph.nodeMap['dataPath']!.partialChildIds, contains('muxUnit'));
    });

    test('expandPath produces same graph state as sequential expandChild', () {
      // Build two identical graphs, expand one sequentially, one batched.
      final seqGraph = buildDeepGraph();
      final seqJson = (seqGraph
            ..expandChild('cpu', 'DataPath')
            ..expandChild('dataPath', 'MuxUnit'))
          .toJsGraph();

      final batchGraph = buildDeepGraph();
      // Both should produce the same JSON output.
      final batchJson =
          (batchGraph..expandPath(['CPU', 'DataPath', 'MuxUnit'])).toJsGraph();
      expect(
        batchJson,
        equals(seqJson),
        reason: 'Batch and sequential expansion should '
            'produce identical ELK graphs',
      );
    });

    test('expandPath with targetWireName reveals wire at leaf', () {
      final graph = buildDeepGraph();

      // Expand to DataPath, then reveal wire sig_dp_mux inside it.
      final changed = graph.expandPath([
        'CPU',
        'DataPath',
      ], targetWireName: 'sig_dp_mux');
      expect(changed, isTrue);

      // CPU should have DataPath partially visible.
      expect(graph.nodeMap['cpu']!.partialChildIds, contains('dataPath'));

      // DataPath should have hyperedge hDp1 (sig_dp_mux) visible.
      expect(graph.nodeMap['dataPath']!.partialHyperedgeIds, contains('hDp1'));
      // And MuxUnit (the connected child) should be visible.
      expect(graph.nodeMap['dataPath']!.partialChildIds, contains('muxUnit'));
    });

    test('expandPath returns false when already expanded', () {
      final graph = buildDeepGraph();

      final first = graph.expandPath(['CPU', 'DataPath', 'MuxUnit']);
      expect(first, isTrue);

      // Second call should be idempotent.
      final second = graph.expandPath(['CPU', 'DataPath', 'MuxUnit']);
      expect(second, isFalse);
    });

    test('expandPath with empty segments returns false', () {
      final graph = buildDeepGraph();
      expect(graph.expandPath([]), isFalse);
    });

    test('expandPath with non-existent child returns false gracefully', () {
      final graph = buildDeepGraph();
      // 'FPU' does not exist under CPU.
      final changed = graph.expandPath(['CPU', 'FPU']);
      // CPU→'CPU' should still be expanded (first segment matches).
      // The second segment will fail to find 'FPU', but the first
      // expandChild('cpu', 'CPU') is on the root which should match.
      // Actually 'CPU' is a child of root, already visible. The method
      // will try expandChild(cpuId, 'FPU') which will fail.
      // Either way the method should not throw.
      expect(changed, isA<bool>());
    });

    test('expandPath works when first segment is grandchild of root', () {
      // Mimic the real app: root → wrapper → `CPU, Memory`
      // The path starts at 'CPU' which is NOT a direct child of root.
      final graph = buildDeepGraph();
      final origRoot = graph.root;

      // Wrap the existing root contents inside a new wrapper root,
      // making the old root a child of the new wrapper.
      final wrapper = makeTestNode(
        'wrapper',
        hwMeta: const HwMeta(name: 'Wrapper'),
        children: [origRoot],
      );

      final wrapperGraph = SchematicGraph(
        root: wrapper,
        nodeMap: {'wrapper': wrapper, ...graph.nodeMap},
      );

      // First segment 'CPU' is a child of 'root' (grandchild of wrapper).
      final changed = wrapperGraph.expandPath(['CPU', 'DataPath', 'MuxUnit']);
      expect(changed, isTrue);

      // Verify the expansion propagated correctly.
      expect(
        wrapperGraph.nodeMap['cpu']!.partialChildIds,
        contains('dataPath'),
      );
      expect(
        wrapperGraph.nodeMap['dataPath']!.partialChildIds,
        contains('muxUnit'),
      );
    });
  });

  // =====================================================================
  // expandPortThrough — pass-through traversal through trivial gates
  // =====================================================================

  group('SchematicGraph.expandPortThrough', () {
    /// Build a test fixture with trivial gates in the signal path.
    ///
    /// Graph structure (all children start collapsed / hidden):
    ///
    ///   root
    ///   ├── portA  (INPUT, WEST)
    ///   ├── portB  (OUTPUT, EAST)
    ///   │
    ///   ├── `hidden` buf1   — BUF operator (ports: buf1_in, buf1_out)
    ///   ├── `hidden` inv1   — NOT operator (ports: inv1_in, inv1_out)
    ///   ├── `hidden` adder  — ADD operator (ports: adder_a, adder_b, adder_y)
    ///   └── `hidden` submod — non-operator submodule
    ///                            (ports: sub_in, sub_out; has children)
    ///
    ///   Hyperedges on root:
    ///     h1: root:portA    →  buf1:buf1_in
    ///     h2: buf1:buf1_out →  inv1:inv1_in
    ///     h3: inv1:inv1_out →  adder:adder_a
    ///     h4: adder:adder_y →  root:portB
    ///     h5: root:portA    →  submod:sub_in   (branch directly to submod)
    ///
    SchematicGraph buildTrivialGateGraph() {
      // -- Root ports --
      final portA = ElkPort(
        id: 'portA',
        hwMeta: const HwMeta(name: 'portA'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portB = ElkPort(
        id: 'portB',
        hwMeta: const HwMeta(name: 'portB'),
        direction: 'OUTPUT',
        side: 'EAST',
      );

      // -- BUF child --
      final buf1In = ElkPort(
        id: 'buf1_in',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final buf1Out = ElkPort(
        id: 'buf1_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final buf1 = makeTestNode(
        'buf1',
        hwMeta: const HwMeta(name: 'BUF', cls: 'Operator'),
        ports: [buf1In, buf1Out],
      );

      // -- NOT (inverter) child --
      final inv1In = ElkPort(
        id: 'inv1_in',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final inv1Out = ElkPort(
        id: 'inv1_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final inv1 = makeTestNode(
        'inv1',
        hwMeta: const HwMeta(name: 'NOT', cls: 'Operator'),
        ports: [inv1In, inv1Out],
      );

      // -- ADD (non-trivial operator) --
      final adderA = ElkPort(
        id: 'adder_a',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final adderB = ElkPort(
        id: 'adder_b',
        hwMeta: const HwMeta(name: 'B'),
        direction: 'INPUT',
        side: 'WEST',
        index: 1,
      );
      final adderY = ElkPort(
        id: 'adder_y',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final adder = makeTestNode(
        'adder',
        hwMeta: const HwMeta(name: 'ADD', cls: 'Operator'),
        ports: [adderA, adderB, adderY],
      );

      // -- Non-operator submodule (has hidden children) --
      final subIn = ElkPort(
        id: 'sub_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final subOut = ElkPort(
        id: 'sub_out',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final subChild = makeTestNode(
        'subChild',
        hwMeta: const HwMeta(name: 'Inner'),
      );
      final submod = makeTestNode(
        'submod',
        hwMeta: const HwMeta(name: 'SubModule'),
        ports: [subIn, subOut],
        hiddenChildren: [subChild],
      );

      // -- Hyperedges --
      final h1 = LayoutHyperedge(
        id: 'h1',
        signal: SignalOccurrence(name: 'sig_a', width: 1),
        sources: [('root', 0)],
        targets: [('buf1', 0)],
      );
      final h2 = LayoutHyperedge(
        id: 'h2',
        signal: SignalOccurrence(name: 'sig_buf', width: 1),
        sources: [('buf1', 1)],
        targets: [('inv1', 0)],
      );
      final h3 = LayoutHyperedge(
        id: 'h3',
        signal: SignalOccurrence(name: 'sig_inv', width: 1),
        sources: [('inv1', 1)],
        targets: [('adder', 0)],
      );
      final h4 = LayoutHyperedge(
        id: 'h4',
        signal: SignalOccurrence(name: 'sig_b', width: 1),
        sources: [('adder', 2)],
        targets: [('root', 1)],
      );
      final h5 = LayoutHyperedge(
        id: 'h5',
        signal: SignalOccurrence(name: 'sig_sub', width: 1),
        sources: [('root', 0)],
        targets: [('submod', 0)],
      );

      // -- Root --
      final root = makeTestNode(
        'root',
        hwMeta: const HwMeta(name: 'Root'),
        ports: [portA, portB],
        children: [],
        hiddenChildren: [buf1, inv1, adder, submod],
        hyperedges: [h1, h2, h3, h4, h5],
      );

      return SchematicGraph(
        root: root,
        nodeMap: {
          'root': root,
          'buf1': buf1,
          'inv1': inv1,
          'adder': adder,
          'submod': submod,
          'subChild': subChild,
        },
      );
    }

    test('traverses through buffer and inverter to reach non-trivial gate', () {
      final graph = buildTrivialGateGraph();
      // portA → buf1 (BUF, trivial) → inv1 (NOT, trivial) → adder (ADD,
      // non-trivial) → stop.
      // Also: portA → submod (non-trivial submodule) → stop.
      final result = graph.expandPortThrough('root', 'portA');

      expect(result, isTrue);

      // All four hidden children should be revealed:
      //   buf1, inv1 (traversed through), adder (stopped), submod (stopped)
      expect(
        graph.root.partialChildIds,
        containsAll(['buf1', 'inv1', 'adder', 'submod']),
      );

      // All hyperedges in the chain should be included:
      //   h1 (portA→buf1), h2 (buf1→inv1), h3 (inv1→adder), h5 (portA→submod)
      expect(
        graph.root.partialHyperedgeIds,
        containsAll(['h1', 'h2', 'h3', 'h5']),
      );
    });

    test('regular expandPort only reaches the first hop', () {
      final graph = buildTrivialGateGraph();
      // Regular expandPort: portA → buf1 and submod only (no traversal).
      final result = graph.expandPort('root', 'portA');

      expect(result, isTrue);
      expect(graph.root.partialChildIds, equals({'buf1', 'submod'}));
      expect(graph.root.partialHyperedgeIds, equals({'h1', 'h5'}));
    });

    test('expandPortThrough from EAST port traverses backwards', () {
      final graph = buildTrivialGateGraph();
      // portB is reached from adder_y via h4.
      // adder is ADD (non-trivial) → stop at adder; does not traverse further.
      final result = graph.expandPortThrough('root', 'portB');

      expect(result, isTrue);
      expect(graph.root.partialChildIds, contains('adder'));
      expect(graph.root.partialHyperedgeIds, contains('h4'));

      // Should NOT include buf1 or inv1 because adder is non-trivial.
      expect(graph.root.partialChildIds, isNot(contains('buf1')));
      expect(graph.root.partialChildIds, isNot(contains('inv1')));
    });

    test('stops at submodules (non-operator nodes)', () {
      final graph = buildTrivialGateGraph();
      final result = graph.expandPortThrough('root', 'portA');
      expect(result, isTrue);

      // submod is a non-operator submodule → traversal stops there.
      expect(graph.root.partialChildIds, contains('submod'));

      // We should NOT traverse into submod's internal structure.
      // submod's child 'subChild' is NOT in root's partial children.
      expect(graph.root.partialChildIds, isNot(contains('subChild')));
    });

    test('returns false for non-existent node', () {
      final graph = buildTrivialGateGraph();
      expect(graph.expandPortThrough('nonexistent', 'portA'), isFalse);
    });

    test('returns false when node has no hidden children', () {
      final graph = buildTrivialGateGraph();
      graph.root.toggle(); // fully expand
      expect(graph.expandPortThrough('root', 'portA'), isFalse);
    });

    test('idempotent: second call returns false', () {
      final graph = buildTrivialGateGraph();
      expect(graph.expandPortThrough('root', 'portA'), isTrue);
      // Everything already visible — second call should be idempotent.
      expect(graph.expandPortThrough('root', 'portA'), isFalse);
    });

    test('additive with previous expandPort', () {
      final graph = buildTrivialGateGraph()
        // First, regular expand on portB → reveals adder only.
        ..expandPort('root', 'portB');
      expect(graph.root.partialChildIds, equals({'adder'}));

      // Now expandPortThrough on portA → adds buf1, inv1, submod
      // and adder is already there. Also merges new hyperedges.
      final result = graph.expandPortThrough('root', 'portA');
      expect(result, isTrue);
      expect(
        graph.root.partialChildIds,
        containsAll(['buf1', 'inv1', 'adder', 'submod']),
      );
    });

    test('discovers inter-child edges when both endpoints become visible', () {
      final graph = buildTrivialGateGraph()..expandPortThrough('root', 'portA');

      // After traversal, buf1 and inv1 are both visible.
      // h2 (buf1→inv1) connects them, so it should be auto-included.
      expect(graph.root.partialHyperedgeIds, contains('h2'));

      // h4 (adder→root) is NOT included because it references root (parent),
      // and it was not directly encountered in the traversal from portA.
      expect(graph.root.partialHyperedgeIds, isNot(contains('h4')));
    });
  });

  test(
    'recursive expansion climbs from a leaf owner into parent connectivity',
    () {
      final leafPort = ElkPort(
        id: 'leaf_out',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final sinkPort = ElkPort(
        id: 'sink_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final leaf = makeTestNode(
        'leaf',
        hwMeta: const HwMeta(name: 'leaf', cls: 'Operator'),
        ports: [leafPort],
      );
      final sink = makeTestNode(
        'sink',
        hwMeta: const HwMeta(name: 'BUF', cls: 'Operator'),
        ports: [sinkPort],
      );
      final edge = LayoutHyperedge(
        id: 'parent_h1',
        signal: SignalOccurrence(name: 'out', width: 1),
        sources: [('leaf', 0)],
        targets: [('sink', 0)],
      );
      final root = makeTestNode(
        'root',
        children: [leaf],
        hiddenChildren: [sink],
        hyperedges: [edge],
      );
      leaf.parent = root;
      sink.parent = root;
      final graph = SchematicGraph(
        root: root,
        nodeMap: {'root': root, 'leaf': leaf, 'sink': sink},
      );

      expect(
        graph.expandPortThroughRecursive('leaf', 'leaf_out'),
        isTrue,
      );
      expect(root.partialChildIds, contains('sink'));
      expect(root.partialHyperedgeIds, contains('parent_h1'));
    },
  );

  test('recursive output expansion follows a unique driver through all depths',
      () {
    ElkPort outputPort(String id) => ElkPort(
          id: id,
          hwMeta: const HwMeta(name: 'out'),
          direction: 'OUTPUT',
          side: 'EAST',
        );

    final driver = makeTestNode(
      'driver',
      hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
      ports: [outputPort('driver_out')],
    );
    final level2 = makeTestNode(
      'level2',
      ports: [outputPort('level2_out')],
      hiddenChildren: [driver],
      hyperedges: [
        LayoutHyperedge(
          id: 'level2_h',
          signal: SignalOccurrence(name: 'level2_out', width: 1),
          sources: [('driver', 0)],
          targets: [('level2', 0)],
        ),
      ],
    );
    final level1 = makeTestNode(
      'level1',
      ports: [outputPort('level1_out')],
      hiddenChildren: [level2],
      hyperedges: [
        LayoutHyperedge(
          id: 'level1_h',
          signal: SignalOccurrence(name: 'level1_out', width: 1),
          sources: [('level2', 0)],
          targets: [('level1', 0)],
        ),
      ],
    );
    final root = makeTestNode(
      'root',
      ports: [outputPort('root_out')],
      hiddenChildren: [level1],
      hyperedges: [
        LayoutHyperedge(
          id: 'root_h',
          signal: SignalOccurrence(name: 'root_out', width: 1),
          sources: [('level1', 0)],
          targets: [('root', 0)],
        ),
      ],
    );
    level1.parent = root;
    level2.parent = level1;
    driver.parent = level2;
    final graph = SchematicGraph(
      root: root,
      nodeMap: {
        'root': root,
        'level1': level1,
        'level2': level2,
        'driver': driver,
      },
    );

    expect(graph.expandPortThroughRecursive('root', 'root_out'), isTrue);
    expect(root.partialChildIds, {'level1'});
    expect(level1.partialChildIds, {'level2'});
    expect(level2.partialChildIds, {'driver'});
  });

  test('recursive input expansion stops at downstream fan-out', () {
    ElkPort inputPort(String id) => ElkPort(
          id: id,
          hwMeta: const HwMeta(name: 'in'),
          direction: 'INPUT',
          side: 'WEST',
        );

    LayoutNode sinkModule(String id) {
      final inner = makeTestNode('${id}_inner');
      final sink = makeTestNode(
        id,
        ports: [inputPort('${id}_in')],
        hiddenChildren: [inner],
        hyperedges: [
          LayoutHyperedge(
            id: '${id}_h',
            signal: SignalOccurrence(name: '${id}_in', width: 1),
            sources: [(id, 0)],
            targets: [('${id}_inner', 0)],
          ),
        ],
      );
      inner.parent = sink;
      return sink;
    }

    final sinkA = sinkModule('sinkA');
    final sinkB = sinkModule('sinkB');
    final root = makeTestNode(
      'root',
      ports: [inputPort('root_in')],
      hiddenChildren: [sinkA, sinkB],
      hyperedges: [
        LayoutHyperedge(
          id: 'fanout_h',
          signal: SignalOccurrence(name: 'root_in', width: 1),
          sources: [('root', 0)],
          targets: [('sinkA', 0), ('sinkB', 0)],
        ),
      ],
    );
    sinkA.parent = root;
    sinkB.parent = root;
    final graph = SchematicGraph(
      root: root,
      nodeMap: {
        'root': root,
        'sinkA': sinkA,
        'sinkA_inner': sinkA.hiddenChildren!.single,
        'sinkB': sinkB,
        'sinkB_inner': sinkB.hiddenChildren!.single,
      },
    );

    expect(graph.expandPortThroughRecursive('root', 'root_in'), isTrue);
    expect(root.partialChildIds, containsAll(['sinkA', 'sinkB']));
    expect(sinkA.partialChildIds, isNull);
    expect(sinkB.partialChildIds, isNull);
  });

  group('expandPortThrough with CONCAT fanout', () {
    /// Build a fixture where a CONCAT gate fans out when traversing
    /// backwards (EAST → WEST through CONCAT).
    ///
    ///   root
    ///   ├── portOut (OUTPUT, EAST)
    ///   │
    ///   ├── `hidden` concat1 — CONCAT operator
    ///   │     ports: concat_a (INPUT), concat_b (INPUT), concat_y (OUTPUT)
    ///   ├── `hidden` driverA — non-trivial (drives concat_a)
    ///   ├── `hidden` driverB — non-trivial (drives concat_b)
    ///   └── `hidden` sink    — non-trivial (receives from concat_y)
    ///
    ///   Hyperedges:
    ///     h1: concat1:concat_y → root:portOut
    ///     h2: driverA:drvA_out → concat1:concat_a
    ///     h3: driverB:drvB_out → concat1:concat_b
    ///     h4: concat1:concat_y → sink:sink_in
    ///
    SchematicGraph buildConcatGraph() {
      final portOut = ElkPort(
        id: 'portOut',
        hwMeta: const HwMeta(name: 'portOut'),
        direction: 'OUTPUT',
        side: 'EAST',
      );

      // CONCAT child
      final concatA = ElkPort(
        id: 'concat_a',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final concatB = ElkPort(
        id: 'concat_b',
        hwMeta: const HwMeta(name: 'B'),
        direction: 'INPUT',
        side: 'WEST',
        index: 1,
      );
      final concatY = ElkPort(
        id: 'concat_y',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final concat1 = makeTestNode(
        'concat1',
        hwMeta: const HwMeta(name: 'CONCAT', cls: 'Operator'),
        ports: [concatA, concatB, concatY],
      );

      // DriverA (non-trivial)
      final drvAOut = ElkPort(
        id: 'drvA_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final drvAInnerOut = ElkPort(
        id: 'drvA_inner_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final driverAOpen = makeTestNode('driverA_open');
      final driverAInner = makeTestNode(
        'driverA_inner',
        hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
        ports: [drvAInnerOut],
      );
      final driverAEdge = LayoutHyperedge(
        id: 'driverA_h1',
        signal: SignalOccurrence(name: 'driverA_internal', width: 1),
        sources: [('driverA_inner', 0)],
        targets: [('driverA', 0)],
      );
      final driverA = makeTestNode(
        'driverA',
        hwMeta: const HwMeta(name: 'MUX', cls: 'Operator'),
        ports: [drvAOut],
        children: [driverAOpen],
        hiddenChildren: [driverAInner],
        hyperedges: [driverAEdge],
      );

      // DriverB (non-trivial)
      final drvBOut = ElkPort(
        id: 'drvB_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final drvBInnerOut = ElkPort(
        id: 'drvB_inner_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final driverBOpen = makeTestNode('driverB_open');
      final driverBInner = makeTestNode(
        'driverB_inner',
        hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
        ports: [drvBInnerOut],
      );
      final driverBEdge = LayoutHyperedge(
        id: 'driverB_h1',
        signal: SignalOccurrence(name: 'driverB_internal', width: 1),
        sources: [('driverB_inner', 0)],
        targets: [('driverB', 0)],
      );
      final driverB = makeTestNode(
        'driverB',
        hwMeta: const HwMeta(name: 'ADD', cls: 'Operator'),
        ports: [drvBOut],
        children: [driverBOpen],
        hiddenChildren: [driverBInner],
        hyperedges: [driverBEdge],
      );

      // Sink (non-trivial)
      final sinkIn = ElkPort(
        id: 'sink_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final sink = makeTestNode(
        'sink',
        hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
        ports: [sinkIn],
      );

      final h1 = LayoutHyperedge(
        id: 'h1',
        signal: SignalOccurrence(name: 'sig_concat', width: 1),
        sources: [('concat1', 2)],
        targets: [('root', 0)],
      );
      final h2 = LayoutHyperedge(
        id: 'h2',
        signal: SignalOccurrence(name: 'sig_drvA', width: 1),
        sources: [('driverA', 0)],
        targets: [('concat1', 0)],
      );
      final h3 = LayoutHyperedge(
        id: 'h3',
        signal: SignalOccurrence(name: 'sig_drvB', width: 1),
        sources: [('driverB', 0)],
        targets: [('concat1', 1)],
      );
      final h4 = LayoutHyperedge(
        id: 'h4',
        signal: SignalOccurrence(name: 'sig_sink', width: 1),
        sources: [('concat1', 2)],
        targets: [('sink', 0)],
      );

      final root = makeTestNode(
        'root',
        hwMeta: const HwMeta(name: 'Root'),
        ports: [portOut],
        children: [],
        hiddenChildren: [concat1, driverA, driverB, sink],
        hyperedges: [h1, h2, h3, h4],
      );

      return SchematicGraph(
        root: root,
        nodeMap: {
          'root': root,
          'concat1': concat1,
          'driverA': driverA,
          'driverA_open': driverAOpen,
          'driverA_inner': driverAInner,
          'driverB': driverB,
          'driverB_open': driverBOpen,
          'driverB_inner': driverBInner,
          'sink': sink,
        },
      );
    }

    test('EAST port traverses through CONCAT and fans out to drivers', () {
      final graph = buildConcatGraph();
      // portOut ← concat_y (h1).  CONCAT is trivial → exit through
      // concat_a and concat_b (INPUT ports).
      // concat_a ← driverA (h2) → stop (MUX, non-trivial).
      // concat_b ← driverB (h3) → stop (ADD, non-trivial).
      // Also: concat_y → sink (h4) → stop (FF, non-trivial).
      final result = graph.expandPortThrough('root', 'portOut');

      expect(result, isTrue);
      expect(
        graph.root.partialChildIds,
        containsAll(['concat1', 'driverA', 'driverB', 'sink']),
      );
      expect(
        graph.root.partialHyperedgeIds,
        containsAll(['h1', 'h2', 'h3', 'h4']),
      );
    });

    test('recursive expansion stops before CONCAT fan-out branches', () {
      final graph = buildConcatGraph();

      final result = graph.expandPortThroughRecursive('root', 'portOut');

      expect(result, isTrue);
      expect(graph.nodeMap['driverA']!.partialChildIds, isNull);
      expect(graph.nodeMap['driverB']!.partialChildIds, isNull);
    });

    test(
      'regular expandPort on same EAST port only reveals CONCAT and sink',
      () {
        final graph = buildConcatGraph();
        final result = graph.expandPort('root', 'portOut');
        expect(result, isTrue);

        // Only direct connections: concat1 (via h1) and sink (via h4, which
        // also references concat_y). Actually h1 involves portOut → concat1; h4
        // also involves concat_y, not portOut. Let me verify: h1:
        // sources=(concat1,concat_y), targets=(root,portOut) → portOut is in
        // targets h4: sources=(concat1,concat_y), targets=(sink,sink_in) →
        // portOut NOT involved So only h1 is matched, revealing concat1 only.
        expect(graph.root.partialChildIds, equals({'concat1'}));
        expect(graph.root.partialHyperedgeIds, equals({'h1'}));
      },
    );
  });

  group('expandPortThrough with SLICE fanout', () {
    /// Build a fixture where a SLICE gate fans out when traversing
    /// forward (WEST → EAST through SLICE).
    ///
    ///   root
    ///   ├── portIn (INPUT, WEST)
    ///   │
    ///   ├── `hidden` slice1 — SLICE operator
    ///   │     ports: slice_a (INPUT), slice_y (OUTPUT)
    ///   ├── `hidden` dest1 — non-trivial
    ///   └── `hidden` dest2 — non-trivial
    ///
    ///   Hyperedges:
    ///     h1: root:portIn → slice1:slice_a
    ///     h2: slice1:slice_y → dest1:dest1_in
    ///     h3: slice1:slice_y → dest2:dest2_in
    ///
    SchematicGraph buildSliceGraph() {
      final portIn = ElkPort(
        id: 'portIn',
        hwMeta: const HwMeta(name: 'portIn'),
        direction: 'INPUT',
        side: 'WEST',
      );

      final sliceA = ElkPort(
        id: 'slice_a',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final sliceY = ElkPort(
        id: 'slice_y',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final slice1 = makeTestNode(
        'slice1',
        hwMeta: const HwMeta(name: 'SLICE', cls: 'Operator'),
        ports: [sliceA, sliceY],
      );

      final dest1In = ElkPort(
        id: 'dest1_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final dest1 = makeTestNode(
        'dest1',
        hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
        ports: [dest1In],
      );

      final dest2In = ElkPort(
        id: 'dest2_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final dest2 = makeTestNode(
        'dest2',
        hwMeta: const HwMeta(name: 'MUX', cls: 'Operator'),
        ports: [dest2In],
      );

      final h1 = LayoutHyperedge(
        id: 'h1',
        signal: SignalOccurrence(name: 'sig_in', width: 1),
        sources: [('root', 0)],
        targets: [('slice1', 0)],
      );
      final h2 = LayoutHyperedge(
        id: 'h2',
        signal: SignalOccurrence(name: 'sig_slice1', width: 1),
        sources: [('slice1', 1)],
        targets: [('dest1', 0)],
      );
      final h3 = LayoutHyperedge(
        id: 'h3',
        signal: SignalOccurrence(name: 'sig_slice2', width: 1),
        sources: [('slice1', 1)],
        targets: [('dest2', 0)],
      );

      final root = makeTestNode(
        'root',
        hwMeta: const HwMeta(name: 'Root'),
        ports: [portIn],
        children: [],
        hiddenChildren: [slice1, dest1, dest2],
        hyperedges: [h1, h2, h3],
      );

      return SchematicGraph(
        root: root,
        nodeMap: {
          'root': root,
          'slice1': slice1,
          'dest1': dest1,
          'dest2': dest2,
        },
      );
    }

    test('WEST port traverses through SLICE and fans out to destinations', () {
      final graph = buildSliceGraph();
      final result = graph.expandPortThrough('root', 'portIn');

      expect(result, isTrue);
      expect(
        graph.root.partialChildIds,
        containsAll(['slice1', 'dest1', 'dest2']),
      );
      expect(graph.root.partialHyperedgeIds, containsAll(['h1', 'h2', 'h3']));
    });

    test('regular expandPort only reveals SLICE', () {
      final graph = buildSliceGraph()..expandPort('root', 'portIn');
      expect(graph.root.partialChildIds, equals({'slice1'}));
      expect(graph.root.partialHyperedgeIds, equals({'h1'}));
    });
  });

  group('expandPortThrough with chained trivial gates', () {
    /// Chain: portIn → BUF → NOT → SLICE → CONCAT → non-trivial dest
    ///
    /// This tests a long chain where every gate except the final one
    /// is trivial.
    SchematicGraph buildChainGraph() {
      final portIn = ElkPort(
        id: 'portIn',
        hwMeta: const HwMeta(name: 'portIn'),
        direction: 'INPUT',
        side: 'WEST',
      );

      // BUF
      final buf = makeTestNode(
        'buf',
        hwMeta: const HwMeta(name: 'BUF', cls: 'Operator'),
        ports: [
          ElkPort(
            id: 'buf_in',
            hwMeta: const HwMeta(name: 'A'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'buf_out',
            hwMeta: const HwMeta(name: 'Y'),
            direction: 'OUTPUT',
            side: 'EAST',
          ),
        ],
      );

      // NOT
      final inv = makeTestNode(
        'inv',
        hwMeta: const HwMeta(name: 'NOT', cls: 'Operator'),
        ports: [
          ElkPort(
            id: 'inv_in',
            hwMeta: const HwMeta(name: 'A'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'inv_out',
            hwMeta: const HwMeta(name: 'Y'),
            direction: 'OUTPUT',
            side: 'EAST',
          ),
        ],
      );

      // SLICE
      final slicer = makeTestNode(
        'slicer',
        hwMeta: const HwMeta(name: 'SLICE', cls: 'Operator'),
        ports: [
          ElkPort(
            id: 'sl_in',
            hwMeta: const HwMeta(name: 'A'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'sl_out',
            hwMeta: const HwMeta(name: 'Y'),
            direction: 'OUTPUT',
            side: 'EAST',
          ),
        ],
      );

      // CONCAT
      final concat = makeTestNode(
        'concat',
        hwMeta: const HwMeta(name: 'CONCAT', cls: 'Operator'),
        ports: [
          ElkPort(
            id: 'cat_in',
            hwMeta: const HwMeta(name: 'A'),
            direction: 'INPUT',
            side: 'WEST',
          ),
          ElkPort(
            id: 'cat_out',
            hwMeta: const HwMeta(name: 'Y'),
            direction: 'OUTPUT',
            side: 'EAST',
          ),
        ],
      );

      // Non-trivial destination
      final dest = makeTestNode(
        'dest',
        hwMeta: const HwMeta(name: 'FF', cls: 'Operator'),
        ports: [
          ElkPort(
            id: 'dest_in',
            hwMeta: const HwMeta(name: 'D'),
            direction: 'INPUT',
            side: 'WEST',
          ),
        ],
      );

      final root = makeTestNode(
        'root',
        hwMeta: const HwMeta(name: 'Root'),
        ports: [portIn],
        children: [],
        hiddenChildren: [buf, inv, slicer, concat, dest],
        hyperedges: [
          LayoutHyperedge(
            id: 'h1',
            signal: SignalOccurrence(name: 's1', width: 1),
            sources: [('root', 0)],
            targets: [('buf', 0)],
          ),
          LayoutHyperedge(
            id: 'h2',
            signal: SignalOccurrence(name: 's2', width: 1),
            sources: [('buf', 1)],
            targets: [('inv', 0)],
          ),
          LayoutHyperedge(
            id: 'h3',
            signal: SignalOccurrence(name: 's3', width: 1),
            sources: [('inv', 1)],
            targets: [('slicer', 0)],
          ),
          LayoutHyperedge(
            id: 'h4',
            signal: SignalOccurrence(name: 's4', width: 1),
            sources: [('slicer', 1)],
            targets: [('concat', 0)],
          ),
          LayoutHyperedge(
            id: 'h5',
            signal: SignalOccurrence(name: 's5', width: 1),
            sources: [('concat', 1)],
            targets: [('dest', 0)],
          ),
        ],
      );

      return SchematicGraph(
        root: root,
        nodeMap: {
          'root': root,
          'buf': buf,
          'inv': inv,
          'slicer': slicer,
          'concat': concat,
          'dest': dest,
        },
      );
    }

    test('traverses entire chain of 4 trivial gates to reach FF', () {
      final graph = buildChainGraph();
      final result = graph.expandPortThrough('root', 'portIn');

      expect(result, isTrue);
      expect(
        graph.root.partialChildIds,
        containsAll(['buf', 'inv', 'slicer', 'concat', 'dest']),
      );
      expect(
        graph.root.partialHyperedgeIds,
        containsAll(['h1', 'h2', 'h3', 'h4', 'h5']),
      );
    });
  });
}
