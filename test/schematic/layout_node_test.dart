// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// layout_node_test.dart
// Unit tests for LayoutNode expansion and state management.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

void main() {
  group('LayoutNode', () {
    late HierarchyOccurrence rootHierarchy;
    late HierarchyOccurrence childHierarchy;
    late HierarchyOccurrence grandchildHierarchy;
    late LayoutNode rootNode;
    late LayoutNode childNode;
    late LayoutNode grandchildNode;

    setUp(() {
      // Create hierarchy nodes
      grandchildHierarchy = HierarchyOccurrence(
        name: 'grandchild1',
        definition: 'primitive_gate',
        isPrimitive: true,
      );

      childHierarchy = HierarchyOccurrence(
        name: 'child1',
        definition: 'submodule',
      );
      childHierarchy.children.add(grandchildHierarchy);

      rootHierarchy = HierarchyOccurrence(
        name: 'top',
        definition: 'top_module',
      );
      rootHierarchy.children.add(childHierarchy);
      rootHierarchy.buildAddresses();

      // Create layout nodes wrapping hierarchy nodes
      grandchildNode = LayoutNode(occurrence: grandchildHierarchy);

      childNode = LayoutNode(
        occurrence: childHierarchy,
        children: [],
        hiddenChildren: [grandchildNode],
      );
      grandchildNode.parent = childNode;

      rootNode = LayoutNode(
        occurrence: rootHierarchy,
        children: [],
        hiddenChildren: [childNode],
      );
      childNode.parent = rootNode;
    });

    test('LayoutNode has correct delegation properties', () {
      expect(rootNode.name, equals('top'));
      expect(rootNode.name, equals('top'));
      expect(rootNode.occurrence.isPrimitive, isFalse);
      expect(rootNode.definition, equals('top_module'));
    });

    test('LayoutNode.isExpandable returns true when hiddenChildren exist', () {
      expect(rootNode.isExpandable, isTrue);
      expect(childNode.isExpandable, isTrue);
      expect(grandchildNode.isExpandable, isFalse);
    });

    test('LayoutNode.isExpanded returns true when children exist', () {
      expect(rootNode.isExpanded, isFalse);
      expect(childNode.isExpanded, isFalse);

      // Expand root
      rootNode.children.addAll(rootNode.hiddenChildren ?? []);
      rootNode.hiddenChildren = null;
      expect(rootNode.isExpanded, isTrue);
    });

    test('LayoutNode.toggle() expands collapsed node', () {
      expect(rootNode.isExpandable, isTrue);
      expect(rootNode.isExpanded, isFalse);

      rootNode.toggle();

      expect(rootNode.isExpandable, isFalse);
      expect(rootNode.isExpanded, isTrue);
      expect(rootNode.children.length, equals(1));
      expect(rootNode.children[0], equals(childNode));
      expect(rootNode.hiddenChildren, isNull);
    });

    test('LayoutNode.toggle() collapses expanded node', () {
      // First expand
      rootNode.toggle();
      expect(rootNode.isExpanded, isTrue);

      // Then collapse
      rootNode.toggle();

      expect(rootNode.isExpanded, isFalse);
      expect(rootNode.hiddenChildren, isNotNull);
      expect(rootNode.hiddenChildren!.length, equals(1));
      expect(rootNode.children.length, equals(0));
    });

    test(
      'LayoutNode.expandNonPrimitivesPartial() reveals only non-primitives',
      () {
        expect(childNode.isPartiallyExpanded, isFalse);

        final revealed = childNode.expandNonPrimitivesPartial();

        expect(
          revealed,
          isFalse,
        ); // No non-primitives (grandchild is primitive)
      },
    );

    test(
        'LayoutNode.expandNonPrimitivesPartial() '
        'reveals non-primitive children only', () {
      // Add a non-primitive grandchild
      final nonPrimitiveGrandchild = HierarchyOccurrence(
        name: 'submodule1',
        definition: 'submodule',
      );
      // Add to hierarchy tree and rebuild addresses so path() works
      childHierarchy.children.add(nonPrimitiveGrandchild);
      rootHierarchy.buildAddresses();

      // Give it a dummy hidden child so isExpandable returns true
      final dummyLeaf = LayoutNode(
        occurrence: HierarchyOccurrence(name: 'leaf', definition: 'gate'),
      );
      final nonPrimitiveNode = LayoutNode(
        occurrence: nonPrimitiveGrandchild,
        children: [],
        hiddenChildren: [dummyLeaf],
      )..parent = childNode;

      childNode.hiddenChildren!.add(nonPrimitiveNode);

      final revealed = childNode.expandNonPrimitivesPartial();

      expect(revealed, isTrue);
      expect(childNode.isPartiallyExpanded, isTrue);
      expect(childNode.partialChildIds, contains('top/child1/submodule1'));
    });

    test('LayoutNode.collapsePartialExpansion() clears partial state', () {
      // Set partial state
      childNode
        ..partialChildIds = {'some_id'}
        ..partialHyperedgeIds = {'edge_id'};

      final wasPartial = childNode.collapsePartialExpansion();

      expect(wasPartial, isTrue);
      expect(childNode.partialChildIds, isNull);
      expect(childNode.partialHyperedgeIds, isNull);
    });

    test(
      'LayoutNode.collapsePartialExpansion() returns false if not partial',
      () {
        expect(childNode.isPartiallyExpanded, isFalse);
        final wasPartial = childNode.collapsePartialExpansion();
        expect(wasPartial, isFalse);
      },
    );

    test(
      'LayoutNode.applyPartialExpansion() moves partial children visible',
      () {
        // grandchildNode is already in childNode.hiddenChildren from setUp
        childNode.partialChildIds = {'top/child1/grandchild1'};

        expect(childNode.children.length, equals(0));
        expect(childNode.hiddenChildren!.length, equals(1));

        childNode.applyPartialExpansion();

        expect(childNode.children.length, equals(1));
        expect(childNode.hiddenChildren!.length, equals(0));
        expect(childNode.children[0], equals(grandchildNode));
      },
    );

    test('LayoutNode.restorePartialExpansion() moves children back hidden', () {
      // grandchildNode is already in childNode.hiddenChildren from setUp
      childNode
        ..partialChildIds = {'top/child1/grandchild1'}
        ..applyPartialExpansion();
      expect(childNode.children.length, equals(1));

      childNode.restorePartialExpansion();

      expect(childNode.children.length, equals(0));
      expect(childNode.hiddenChildren!.length, equals(1));
      expect(childNode.hiddenChildren![0], equals(grandchildNode));
    });

    test(
      'LayoutNode.applyPartialExpansion() with hyperedges preserves edge ids',
      () {
        final testHyperedge = LayoutHyperedge(
          id: 'edge1',
          signal: SignalOccurrence(name: 'test_signal', width: 1),
          sources: [('top/child1', 0)],
          targets: [('top/child1/grandchild1', 0)],
        );

        // grandchildNode is already in childNode.hiddenChildren from setUp
        childNode
          ..hyperedges = [testHyperedge]
          ..partialChildIds = {'top/child1/grandchild1'}
          ..partialHyperedgeIds = {'edge1'}
          ..applyPartialExpansion();

        // Children moved as expected
        expect(childNode.children.length, equals(1));
        // partialHyperedgeIds preserved so toJson() can filter edges correctly
        expect(childNode.partialHyperedgeIds, contains('edge1'));
      },
    );

    test(
      'LayoutNode.clearDescendantMarks() clears all descendant partial state',
      () {
        // Set up multi-level partial state
        rootNode
          ..partialChildIds = {'id1'}
          ..partialHyperedgeIds = {'edge1'};
        childNode
          ..partialChildIds = {'id2'}
          ..partialHyperedgeIds = {'edge2'};
        grandchildNode.partialChildIds = {'id3'};

        LayoutNode.clearDescendantMarks([rootNode]);

        expect(rootNode.partialChildIds, isNull);
        expect(rootNode.partialHyperedgeIds, isNull);
        expect(childNode.partialChildIds, isNull);
        expect(childNode.partialHyperedgeIds, isNull);
        expect(grandchildNode.partialChildIds, isNull);
      },
    );

    test('LayoutNode.toString() produces readable representation', () {
      final str = rootNode.toString();
      expect(str, contains('LayoutNode'));
      expect(str, contains('top'));
      expect(str, contains('children'));
    });

    test('LayoutNode delegation: ports delegates to hierarchy', () {
      final port = SignalOccurrence(
        name: 'portA',
        direction: 'input',
        width: 1,
      );
      childHierarchy.signals.add(port);

      final ports = childNode.ports;
      expect(ports.length, equals(1));
      expect(ports[0].name, equals('portA'));
    });

    test('LayoutNode delegation: signals delegates to hierarchy', () {
      final sig = SignalOccurrence(name: 'internal_signal', width: 8);
      childHierarchy.signals.add(sig);

      final signals = childNode.signals;
      expect(signals.length, equals(1));
      expect(signals[0].name, equals('internal_signal'));
    });
  });
}
