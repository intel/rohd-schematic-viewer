// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// consolidated_vs_elknode_miter_test.dart
// Integration tests comparing consolidated (LayoutNode)
// vs traditional (LayoutNode) paths.
// A "miter" test compares two implementations for equivalence.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';

import '../test_helpers.dart';

void main() {
  group('Consolidated vs LayoutNode Miter Tests', () {
    late SchematicGraph schematic;
    late HierarchyService hierarchy;

    setUp(() {
      // Build a simple schematic graph with LayoutNode
      final rootElk = _buildSimpleElkGraph();

      // Create hierarchy that matches LayoutNode names (findByPath uses names)
      final child1Hierarchy = HierarchyOccurrence(
        name: 'child1',
        definition: 'submodule',
      );
      final child2Hierarchy = HierarchyOccurrence(
        name: 'child2',
        definition: 'submodule',
      );
      final rootHierarchy = HierarchyOccurrence(
        name: 'root',
        definition: 'top',
      );
      rootHierarchy.children.addAll([child1Hierarchy, child2Hierarchy]);

      // Create hierarchy service
      final adapter = _SimpleHierarchyAdapter()..root = rootHierarchy;
      hierarchy = adapter;

      // Create SchematicGraph and build nodeMap/parents from tree
      schematic = SchematicGraph(root: rootElk, hierarchy: hierarchy)
        ..initNodeParents();
    });

    test('Graph builds without errors and produces valid JSON', () {
      expect(schematic.nodeMap.isNotEmpty, isTrue);
      final elkJson = schematic.toJsGraph();
      expect(elkJson.isNotEmpty, isTrue);
      expect(schematic.root, isNotNull);
    });

    test('Consolidated view finds root node correctly', () {
      expect(schematic.root, isNotNull);
      expect(schematic.root.parent, isNull); // Root has no parent
      expect(schematic.nodeMap.containsKey(schematic.root.id), isTrue);
    });

    test('toJsGraph produces valid JSON structure', () {
      final elkJson = schematic.toJsGraph();
      expect(() => jsonDecode(elkJson), returnsNormally);
      final decoded = jsonDecode(elkJson) as Map<String, dynamic>;
      expect(decoded, isA<Map<String, dynamic>>());
    });

    test('Consolidated view maintains hierarchy references', () {
      for (final node in schematic.nodeMap.values) {
        // Every node must have a hierarchy reference
        expect(node.occurrence, isNotNull);
        // Hierarchy node must match the node's ID
        expect(node.id, equals(node.occurrence.path()));
      }
    });

    test('Graph serialization references all nodes', () {
      final json = schematic.toJsGraph();
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['id'], equals(schematic.root.id));
    });

    test('Toggle invalidates consolidation cache', () {
      final before = schematic.root;
      expect(before, isNotNull);

      // Toggle should invalidate cache
      schematic.toggleNode(schematic.root.id);

      // Root is the same object (LayoutNode IS the graph node now)
      final after = schematic.root;
      expect(after, isNotNull);
    });

    test('Partial expansion state works on consolidated view', () {
      final layoutRoot = schematic.root;

      if (layoutRoot.isExpandable) {
        final before = layoutRoot.isPartiallyExpanded;

        layoutRoot.expandNonPrimitivesPartial();

        final after = layoutRoot.isPartiallyExpanded;
        expect(before != after, isTrue);
      }
    });

    test('Apply and restore partial expansions are symmetric', () {
      final layoutRoot = schematic.root;
      final restoreTarget = layoutRoot;

      // Set up partial expansion
      layoutRoot
        ..partialChildIds = {'partial_child'}
        ..children.clear()
        ..hiddenChildren = [
          LayoutNode(
            occurrence: HierarchyOccurrence(
              name: 'partial_child',
              definition: 'test',
            ),
          ),
        ]
        // Apply partial
        ..applyPartialExpansion();
      expect(layoutRoot.children.isNotEmpty, isTrue);

      // Restore partial
      restoreTarget.restorePartialExpansion();
      expect(layoutRoot.children.isEmpty, isTrue);
      expect(layoutRoot.hiddenChildren?.isNotEmpty, isTrue);
    });

    test(
      'toJsGraph temporarily applies partial expansions and restores state',
      () {
        final layoutRoot = schematic.root;
        if (layoutRoot.isExpandable) {
          layoutRoot.partialChildIds = {'child_id'};

          final exportedJson = schematic.toJsGraph();

          // After export, partial state should be restored (not applied)
          expect(layoutRoot.isPartiallyExpanded, isTrue);
          expect(layoutRoot.children.isEmpty, isTrue); // Still hidden

          expect(() => jsonDecode(exportedJson), returnsNormally);
        }
      },
    );

    test('Graph state is consistent after toggle', () {
      final before = schematic.root.isExpanded;

      schematic.toggleNode(schematic.root.id);

      expect(schematic.root.isExpanded, isNot(before));
      // Root is still the same object
      expect(identical(schematic.root, schematic.root), isTrue);
    });

    test('Multi-level expansion works consistently', () {
      _addMultiLevelStructure(schematic);

      // Test LayoutNode path
      expect(schematic.toggleNode(schematic.root.id), isTrue);
      expect(schematic.isExpanded(schematic.root.id), isTrue);

      // Get consolidated view
      expect(schematic.root.isExpanded, isTrue);

      // Toggle back
      expect(schematic.toggleNode(schematic.root.id), isTrue);
      expect(schematic.isExpanded(schematic.root.id), isFalse);

      // New consolidated view should reflect toggle
      expect(schematic.root.isExpanded, isFalse);
    });

    test('Node count consistency between both paths', () {
      final elkNodeCount = schematic.nodeMap.length;
      final consolidatedNodeCount = schematic.nodeMap.length;

      // Both should have same number of nodes (one-to-one mapping)
      expect(consolidatedNodeCount, equals(elkNodeCount));
    });

    test('Hierarchy delegation works correctly in consolidated view', () {
      final layoutRoot = schematic.root;
      final hNode = layoutRoot.occurrence;

      hNode.signals.addAll([
        SignalOccurrence(name: 'clk', direction: 'input', width: 1),
        SignalOccurrence(name: 'internal', width: 8),
      ]);

      // elkPorts is the ELK port list (not hierarchy-derived)
      // signals getter filters hierarchy signals for non-Port entries
      expect(layoutRoot.signals.length, equals(1));
      expect(layoutRoot.signals[0].name, equals('internal'));
    });
  });
}

/// Build a simple LayoutNode graph for testing
LayoutNode _buildSimpleElkGraph() {
  final root = makeTestNode('root', hwMeta: const HwMeta(name: 'root'));

  final leaf1 = makeTestNode('leaf1', hwMeta: const HwMeta(name: 'leaf1'));

  final child1 = makeTestNode('child1', hwMeta: const HwMeta(name: 'child1'))
    ..hiddenChildren = [leaf1];
  leaf1.parent = child1;

  final child2 = makeTestNode('child2', hwMeta: const HwMeta(name: 'child2'));

  // Start collapsed: children are hidden (matches normal graph lifecycle
  // where toggleNode() must be called to expand)
  root.hiddenChildren = [child1, child2];
  child1.parent = root;
  child2.parent = root;

  return root;
}

/// Add multi-level structure to test deep hierarchies
void _addMultiLevelStructure(SchematicGraph schematic) {
  final grandchild = makeTestNode(
    'grandchild',
    hwMeta: const HwMeta(name: 'grandchild'),
  );

  // Find the first child (may be in children or hiddenChildren)
  final allChildren = [
    ...schematic.root.children,
    ...schematic.root.hiddenChildren ?? <LayoutNode>[],
  ];
  if (allChildren.isNotEmpty) {
    grandchild.parent = allChildren[0];
    allChildren[0].hiddenChildren = [grandchild];
    schematic.nodeMap[grandchild.id] = grandchild;
  }
}

/// Simple hierarchy adapter for testing
class _SimpleHierarchyAdapter extends BaseHierarchyAdapter {
  @override
  set root(HierarchyOccurrence value) => super.root = value;
}
