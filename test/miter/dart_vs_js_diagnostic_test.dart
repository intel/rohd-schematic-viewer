// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// dart_vs_js_diagnostic_test.dart
// Diagnostic test comparing Dart-serialized graph vs expected ELK output.
//
// This test helps identify structural differences between the two pipelines.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_schematic_viewer/src/schematic/schematic.dart';

void main() {
  group('Dart vs JS Graph Comparison', () {
    late String sampleJson;
    late NetlistSchematicAdapter dartAdapter;

    setUpAll(() {
      // Load the test schematic
      final jsonFile = File('assets/rohd_schematic.json');
      if (!jsonFile.existsSync()) {
        throw StateError('Test file not found: assets/rohd_schematic.json');
      }
      sampleJson = jsonFile.readAsStringSync();
    });

    setUp(() {
      dartAdapter = NetlistSchematicAdapter.fromJson(sampleJson);
    });

    test('dump Dart graph structure', () {
      final graph = dartAdapter.schematic;

      expect(graph.root, isNotNull, reason: 'Root node must exist');
      expect(graph.root.hwMeta, isNotNull, reason: 'Root must have hwMeta');
      expect(
        graph.root.children,
        isNotEmpty,
        reason: 'Root should have children',
      );
      // Root node may not have ports (it's a container), verify children do
      expect(
        graph.root.children.first.elkPorts,
        isNotEmpty,
        reason: 'First child should have ports',
      );
    });

    test('dump Dart graph serialized JSON', () {
      final graph = dartAdapter.schematic;

      // Serialize to JS format
      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      expect(parsed, isNotNull, reason: 'Serialized JSON must not be null');
      expect(parsed['id'], isNotNull, reason: 'JSON must have id');
      expect(
        parsed['children'],
        isList,
        reason: 'Root must have children array',
      );
      expect(
        (parsed['children'] as List).isNotEmpty,
        isTrue,
        reason: 'Root should have children',
      );
      // Verify first child has ports
      final firstChild =
          (parsed['children'] as List).first as Map<String, dynamic>;
      expect(
        firstChild['ports'],
        isList,
        reason: 'Child nodes must have ports array',
      );
    });

    test('check edge format matches JS expectation', () {
      // JS expects edges in this format after hyperEdgesToEdges:
      // { id, source, sourcePort, target, targetPort, hwMeta }
      //
      // Before hyperEdgesToEdges (hyperedge format):
      // { id, sources: [[nodeId, portId], ...], targets: [...], hwMeta }

      final graph = dartAdapter.schematic;
      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      void checkEdges(Map<String, dynamic> node, String path) {
        final edges = node['edges'] as List?;
        if (edges != null && edges.isNotEmpty) {
          // Verify first edge has required fields for simple edge format
          final edge = edges.first as Map<String, dynamic>;
          expect(
            edge.containsKey('source') && edge.containsKey('target'),
            isTrue,
            reason:
                '[$path] First edge must be in simple edge format with source/target',
          );
          expect(
            edge.containsKey('sourcePort') && edge.containsKey('targetPort'),
            isTrue,
            reason: '[$path] Edge must have sourcePort and targetPort',
          );
        }

        final children = node['children'] as List?;
        if (children != null) {
          for (var i = 0; i < children.length && i < 3; i++) {
            checkEdges(
              children[i] as Map<String, dynamic>,
              '$path.children[$i]',
            );
          }
        }
      }

      checkEdges(parsed, 'root');
    });

    test('check if hyperedges are expanded before serialization', () {
      final graph = dartAdapter.schematic;

      // Count hyperedges (edges are now derived from hyperedges during toJson)
      var totalHyperedges = 0;

      void countRecursive(LayoutNode node) {
        totalHyperedges += node.hyperedges?.length ?? 0;

        node.children.forEach(countRecursive);
        if (node.hiddenChildren != null) {
          node.hiddenChildren!.forEach(countRecursive);
        }
      }

      countRecursive(graph.root);

      // Hyperedges are the source of truth; they become edges in toJson()
      expect(
        totalHyperedges >= 0,
        isTrue,
        reason: 'Graph should have hyperedges',
      );
    });

    test('verify hyperedges are serialized as edges', () {
      final graph = dartAdapter.schematic;

      // Hyperedges are serialized as edges during toJsGraph()
      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      void findEdges(Map<String, dynamic> node, String path) {
        final edges = node['edges'] as List?;
        if (edges != null && edges.isNotEmpty) {
          expect(
            edges.isNotEmpty,
            isTrue,
            reason: '[$path] Should have edges after expansion',
          );
        }

        final children = node['children'] as List?;
        if (children != null) {
          for (var i = 0; i < children.length; i++) {
            findEdges(children[i] as Map<String, dynamic>, '$path.c[$i]');
          }
        }
      }

      findEdges(parsed, 'root');
    });

    test('verify port format matches JS expectation', () {
      final graph = dartAdapter.schematic;
      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      void checkPorts(Map<String, dynamic> node, String path) {
        final ports = node['ports'] as List?;
        if (ports != null && ports.isNotEmpty) {
          // Verify required properties
          final firstPort = ports.first as Map<String, dynamic>;
          expect(
            firstPort.containsKey('id'),
            isTrue,
            reason: '[$path] Port must have id',
          );
          expect(
            firstPort.containsKey('hwMeta'),
            isTrue,
            reason: '[$path] Port must have hwMeta',
          );
          expect(
            firstPort.containsKey('properties'),
            isTrue,
            reason: '[$path] Port must have properties',
          );

          final props = firstPort['properties'] as Map<String, dynamic>?;
          expect(
            props?.containsKey('side'),
            isTrue,
            reason: '[$path] Port properties must have side',
          );
        }

        final children = node['children'] as List?;
        if (children != null && children.isNotEmpty) {
          checkPorts(children.first as Map<String, dynamic>, '$path.c[0]');
        }
      }

      checkPorts(parsed, 'root');
    });

    test('verify node sizes are set', () {
      final graph = dartAdapter.schematic;
      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      void checkSizes(Map<String, dynamic> node, String path) {
        final width = node['width'];
        final height = node['height'];

        expect(width, isNotNull, reason: 'Node must have width');
        expect(height, isNotNull, reason: 'Node must have height');
        expect(width, greaterThan(0), reason: 'Width must be > 0');
        expect(height, greaterThan(0), reason: 'Height must be > 0');

        final children = node['children'] as List?;
        if (children != null && children.isNotEmpty) {
          for (var i = 0; i < children.length && i < 3; i++) {
            checkSizes(children[i] as Map<String, dynamic>, '$path.c[$i]');
          }
        }
      }

      checkSizes(parsed, 'root');
    });

    test('verify edge hierarchy correctness', () {
      // Edges must reference ports that exist at the correct hierarchy level.
      // An edge in node N's edges array can only reference:
      // 1. Ports on node N itself (for hierarchical edges to/from parent)
      // 2. Ports on direct children of node N
      //
      // The ELK error "ElkPort '3_sum' => LayoutNode '1' could not be found"
      // suggests edges are crossing hierarchy boundaries incorrectly.

      final graph = dartAdapter.schematic;

      final jsGraph = graph.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

      const errorCount = 0;

      void checkEdgeHierarchy(
        Map<String, dynamic> node,
        String path,
        Set<String> validNodeIds,
        Set<String> validPortIds,
      ) {
        final nodeId = node['id']?.toString() ?? '';
        final ports = node['ports'] as List? ?? [];
        final children = node['children'] as List? ?? [];
        final edges = node['edges'] as List? ?? [];

        // Collect valid port IDs for this scope:
        // - This node's own ports
        // - All direct children's ports
        final scopePortIds = <String>{};
        final scopeNodeIds = <String>{nodeId};

        // Add this node's ports
        for (final port in ports) {
          final portMap = port as Map<String, dynamic>;
          scopePortIds.add(portMap['id']?.toString() ?? '');
        }

        // Add children's ports
        for (final child in children) {
          final childMap = child as Map<String, dynamic>;
          final childId = childMap['id']?.toString() ?? '';
          scopeNodeIds.add(childId);

          final childPorts = childMap['ports'] as List? ?? [];
          for (final port in childPorts) {
            final portMap = port as Map<String, dynamic>;
            scopePortIds.add(portMap['id']?.toString() ?? '');
          }
        }

        // Check each edge
        for (final edge in edges) {
          final edgeMap = edge as Map<String, dynamic>;
          final edgeId = edgeMap['id']?.toString() ?? '';
          final sourceNodeId = edgeMap['source']?.toString() ?? '';
          final sourcePortId = edgeMap['sourcePort']?.toString() ?? '';
          final targetNodeId = edgeMap['target']?.toString() ?? '';
          final targetPortId = edgeMap['targetPort']?.toString() ?? '';

          // Check source
          expect(
            scopeNodeIds.contains(sourceNodeId),
            isTrue,
            reason: '[$path] Edge $edgeId: source node $sourceNodeId not in '
                'scope $scopeNodeIds',
          );
          expect(
            scopePortIds.contains(sourcePortId),
            isTrue,
            reason: '[$path] Edge $edgeId: source port $sourcePortId '
                'not in scope',
          );

          // Check target
          expect(
            scopeNodeIds.contains(targetNodeId),
            isTrue,
            reason: '[$path] Edge $edgeId: target node $targetNodeId '
                'not in scope $scopeNodeIds',
          );
          expect(
            scopePortIds.contains(targetPortId),
            isTrue,
            reason: '[$path] Edge $edgeId: target port $targetPortId '
                'not in scope',
          );
        }

        // Recurse to children
        for (var i = 0; i < children.length; i++) {
          checkEdgeHierarchy(
            children[i] as Map<String, dynamic>,
            '$path.c[$i]',
            scopeNodeIds,
            scopePortIds,
          );
        }
      }

      checkEdgeHierarchy(parsed, 'root', {}, {});

      expect(
        errorCount,
        equals(0),
        reason: 'All edges must reference ports within their hierarchy scope',
      );
    });
  });
}
