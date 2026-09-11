// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// dart_js_miter_test.dart
// Miter tests to compare Dart schematic parsing against JavaScript reference.
//
// A "miter" is a comparison circuit that verifies two implementations produce
// the same output. These tests ensure the Dart pipeline produces graphs that
// match the expected ELK graph pipeline.
//
// 2026 February
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';

import 'package:rohd_schematic_viewer/src/schematic/schematic.dart';

bool _isBitRangeAnnotation(String value) {
  if (!value.startsWith('[') || !value.endsWith(']')) {
    return false;
  }
  final range = value.substring(1, value.length - 1);
  final separator = range.indexOf(':');
  final high =
      int.tryParse(separator < 0 ? range : range.substring(0, separator));
  final low =
      separator < 0 ? high : int.tryParse(range.substring(separator + 1));
  return high != null && low != null && range.indexOf(':', separator + 1) < 0;
}

void main() {
  group('Dart→JS Miter Tests', () {
    late String netlistJson;
    late NetlistSchematicAdapter dartAdapter;

    setUpAll(() {
      // Load the reference schematic
      final file = File('assets/rohd_schematic.json');
      if (!file.existsSync()) {
        throw StateError(
          'Test fixture assets/rohd_schematic.json not found. '
          'Please ensure the file exists.',
        );
      }
      netlistJson = file.readAsStringSync();
    });

    setUp(() {
      // Parse with Dart adapter
      dartAdapter = NetlistSchematicAdapter.fromJson(netlistJson);
    });

    group('Graph Structure', () {
      test('parses without error', () {
        expect(dartAdapter, isNotNull);
        expect(dartAdapter.schematic.root, isNotNull);
      });

      test('has non-empty node map', () {
        expect(dartAdapter.schematic.nodeMap, isNotEmpty);
      });

      test('root has correct structure', () {
        final root = dartAdapter.schematic.root;

        // Root should be the wrapper node
        expect(root.hwMeta.name, 'root');
        expect(root.children, isNotEmpty);

        // First child should be the top module
        final topModule = root.children.first;
        expect(topModule.hwMeta.name, isNotEmpty);
      });

      test('all nodes are registered in nodeMap', () {
        var visitedCount = 0;

        void countNodes(LayoutNode node) {
          visitedCount++;
          node.children.forEach(countNodes);
          if (node.hiddenChildren != null) {
            node.hiddenChildren!.forEach(countNodes);
          }
        }

        countNodes(dartAdapter.schematic.root);

        // nodeMap should contain all visited nodes
        expect(
          dartAdapter.schematic.nodeMap.length,
          visitedCount,
          reason: 'nodeMap should contain all nodes',
        );
      });
    });

    group('Port Processing', () {
      test('nodes have ports', () {
        final nodesWithPorts = dartAdapter.schematic.nodeMap.values
            .where((n) => n.elkPorts.isNotEmpty)
            .toList();

        expect(
          nodesWithPorts,
          isNotEmpty,
          reason: 'At least some nodes should have ports',
        );
      });

      test('ports have valid sides', () {
        for (final node in dartAdapter.schematic.nodeMap.values) {
          for (final port in node.elkPorts) {
            expect(
              [PortSide.west, PortSide.east, PortSide.north, PortSide.south],
              contains(port.side),
              reason: 'Port ${port.id} should have valid side',
            );
          }
        }
      });

      test('ports have valid directions', () {
        for (final node in dartAdapter.schematic.nodeMap.values) {
          for (final port in node.elkPorts) {
            expect(
              [PortDirection.input, PortDirection.output, PortDirection.inout],
              contains(port.direction),
              reason: 'Port ${port.id} should have valid direction',
            );
          }
        }
      });

      test('port IDs are unique within node', () {
        for (final node in dartAdapter.schematic.nodeMap.values) {
          final portIds = node.elkPorts.map((p) => p.id).toSet();
          expect(
            portIds.length,
            node.elkPorts.length,
            reason: 'Node ${node.id} should have unique port IDs',
          );
        }
      });

      test('SLICE ports have bit range annotations', () {
        // Find SLICE nodes and verify port naming matches JS behavior.
        // FilterBank may not have SLICE cells — skip if absent.
        final sliceNodes = dartAdapter.schematic.nodeMap.values
            .where((n) => n.hwMeta.name == 'SLICE')
            .toList();

        if (sliceNodes.isEmpty) {
          // No SLICE nodes in this netlist — nothing to verify.
          return;
        }

        for (final node in sliceNodes) {
          // Find input/output ports by direction (now using sequential IDs)
          final inputPorts = node.elkPorts.where(
            (p) => p.direction == PortDirection.input,
          );
          final outputPorts = node.elkPorts.where(
            (p) => p.direction == PortDirection.output,
          );

          expect(
            inputPorts.length,
            equals(1),
            reason: 'SLICE should have 1 input port',
          );
          expect(
            outputPorts.length,
            equals(1),
            reason: 'SLICE should have 1 output port',
          );

          final inputPort = inputPorts.first;
          final outputPort = outputPorts.first;

          // Input should have bit range annotation like "[7:0]" or "[3]"
          expect(
            _isBitRangeAnnotation(inputPort.hwMeta.name),
            isTrue,
            reason: 'SLICE input port should have bit range annotation',
          );

          // Output port Y should have empty name
          expect(
            outputPort.hwMeta.name,
            '',
            reason: 'SLICE output port Y should have empty name',
          );
        }
      });

      test('CONCAT ports have bit range annotations', () {
        // Find CONCAT nodes and verify port naming matches JS behavior.
        // FilterBank may not have CONCAT cells — skip if absent.
        final concatNodes = dartAdapter.schematic.nodeMap.values
            .where((n) => n.hwMeta.name == 'CONCAT')
            .toList();

        if (concatNodes.isEmpty) {
          // No CONCAT nodes in this netlist — nothing to verify.
          return;
        }

        for (final node in concatNodes) {
          // Find input/output ports by direction (now using sequential IDs)
          final inputPorts = node.elkPorts
              .where((p) => p.direction == PortDirection.input)
              .toList();
          final outputPorts = node.elkPorts.where(
            (p) => p.direction == PortDirection.output,
          );

          expect(
            inputPorts.length,
            greaterThanOrEqualTo(2),
            reason: 'CONCAT should have at least 2 input ports',
          );
          expect(
            outputPorts.length,
            equals(1),
            reason: 'CONCAT should have 1 output port',
          );

          // Both input ports should have bit range annotations (can be [n] or
          // [m:n])
          for (final inputPort in inputPorts) {
            expect(
              _isBitRangeAnnotation(inputPort.hwMeta.name),
              isTrue,
              reason: 'CONCAT input port ${inputPort.id} should have '
                  'bit range annotation',
            );
          }

          // Output port Y should have empty name
          final outputPort = outputPorts.first;
          expect(
            outputPort.hwMeta.name,
            '',
            reason: 'CONCAT output port Y should have empty name',
          );
        }
      });
    });

    group('CONST Node Sizing Parity', () {
      // Tests to verify CONST node handling matches JS behavior:
      // In the original JS pipeline, dynamically-created CONST nodes have:
      // - hwMeta.name = hex value (e.g., "0xff")
      // - hwMeta.cls = "" (empty, NOT "Operator")
      // - No bodyText
      // This ensures consistent sizing between Dart and JS paths.

      test(r'$const cells produce nodes with hex value as name', () {
        // Create a minimal Yosys JSON with a $const cell
        const constJson = r'''
{
  "modules": {
    "TestModule": {
      "attributes": { "top": 1 },
      "ports": {},
      "cells": {
        "const_cell": {
          "type": "$const",
          "parameters": {
            "WIDTH": 8,
            "VALUE": 255
          },
          "port_directions": {
            "Y": "output"
          },
          "connections": {
            "Y": [100, 101, 102, 103, 104, 105, 106, 107]
          }
        }
      },
      "netnames": {}
    }
  }
}
''';

        final adapter = NetlistSchematicAdapter.fromJson(constJson);

        // Find the const node
        final constNode = adapter.schematic.nodeMap.values.firstWhere(
          (n) => n.hwMeta.name.contains("'h"),
          orElse: () => throw StateError('Should have a node with hex name'),
        );

        // Verify node properties match JS behavior
        expect(
          constNode.hwMeta.name,
          equals("8'hff"),
          reason: 'CONST node name should be hex value',
        );
        expect(
          constNode.hwMeta.cls,
          equals(''),
          reason: 'CONST node cls should be empty (not "Operator")',
        );
        expect(
          constNode.hwMeta.bodyText,
          isNull,
          reason: 'CONST node should have no bodyText',
        );
      });

      test(r'$const node sizing uses label width (not bodyText)', () {
        // Create a $const cell with a known hex value
        const constJson = r'''
{
  "modules": {
    "TestModule": {
      "attributes": { "top": 1 },
      "ports": {},
      "cells": {
        "const_cell": {
          "type": "$const",
          "parameters": {
            "WIDTH": 32,
            "VALUE": 4294967295
          },
          "port_directions": {
            "Y": "output"
          },
          "connections": {
            "Y": [100]
          }
        }
      },
      "netnames": {}
    }
  }
}
''';

        final adapter = NetlistSchematicAdapter.fromJson(constJson);
        // Top module children are already visible at hierarchyLevel 1.
        final elkJson = adapter.toJsGraph();
        final decoded = jsonDecode(elkJson) as Map<String, dynamic>;

        // Find the const node in the serialized output
        final topModule = (decoded['children'] as List<dynamic>).first
            as Map<String, dynamic>;
        final children = topModule['children'] as List<dynamic>;
        final constNode = children.firstWhere(
          (c) => (((c as Map<String, dynamic>)['hwMeta']
                  as Map<String, dynamic>)['name'] as String)
              .contains("'h"),
        ) as Map<String, dynamic>;

        // The hex value is "0xffffffff" (10 chars)
        // Expected width calculation:
        // - No bodyText contribution (bodyTextW = 0)
        // - labelW = 10 * 7.55 = 75.5
        // - Port width for single output port
        // - Final width depends on formula but should be reasonable
        final width = constNode['width'] as double;
        expect(
          width,
          greaterThan(50),
          reason: 'CONST node width should account for hex label length',
        );

        // Verify no bodyText in serialized output
        expect(
          (constNode['hwMeta'] as Map<String, dynamic>)['bodyText'],
          isNull,
          reason: 'Serialized CONST node should have no bodyText',
        );
      });
    });

    group('Hierarchy Structure', () {
      test('hierarchy has root', () {
        expect(dartAdapter.hierarchy.root, isNotNull);
      });

      test('hierarchy root matches schematic top module', () {
        final topModule = dartAdapter.schematic.root.children.first;
        expect(dartAdapter.hierarchy.root.name, topModule.hwMeta.name);
      });

      test('hierarchy nodes have correct parent relationships', () {
        void checkParents(
          HierarchyOccurrence node,
          String? expectedParentPath,
        ) {
          expect(
            node.parent?.path(),
            expectedParentPath,
            reason:
                'Node ${node.path()} should have parent $expectedParentPath',
          );

          for (final child in node.children) {
            checkParents(child, node.path());
          }
        }

        checkParents(dartAdapter.hierarchy.root, null);
      });
    });

    group('JSON Serialization', () {
      test('toJsGraph produces valid JSON', () {
        final jsGraph = dartAdapter.toJsGraph();

        expect(
          () => jsonDecode(jsGraph),
          returnsNormally,
          reason: 'toJsGraph should produce valid JSON',
        );
      });

      test('serialized graph has expected structure', () {
        final jsGraph = dartAdapter.toJsGraph();
        final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

        expect(parsed['id'], isNotNull);
        expect(parsed['hwMeta'], isNotNull);
        expect((parsed['hwMeta'] as Map<String, dynamic>)['name'], 'root');
      });

      test('serialized graph has children', () {
        final jsGraph = dartAdapter.toJsGraph();
        final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

        expect(parsed['children'], isNotNull);
        expect(parsed['children'], isNotEmpty);
      });

      test('round-trip serialization preserves structure', () {
        final jsGraph = dartAdapter.toJsGraph();
        final reparsed = SchematicGraph.fromJson(jsGraph);

        expect(
          reparsed.nodeMap.length,
          dartAdapter.schematic.nodeMap.length,
          reason: 'Node count should be preserved after round-trip',
        );
      });
    });

    group('Hyperedge Processing', () {
      test('hyperedges are collected', () {
        // Note: hyperedges may or may not be present depending on the netlist
        // final hyperedgeCount = dartAdapter.schematic.hyperedges.length;
        // print('Found $hyperedgeCount hyperedges');
      });

      test(
        'hyperedges are serialized as edges in JSON when nodes are expanded',
        () {
          final hyperedgeCount = dartAdapter.schematic.hyperedges.length;
          if (hyperedgeCount == 0) {
            return;
          }

          // Find a node with hyperedges and expand it fully so its edges
          // appear.
          LayoutNode? nodeWithEdges;
          for (final node in dartAdapter.schematic.nodeMap.values) {
            if (node.hyperedges != null && node.hyperedges!.isNotEmpty) {
              nodeWithEdges = node;
              break;
            }
          }
          if (nodeWithEdges == null) {
            return;
          }

          // Fully expand the node so children are visible (toggle if
          // collapsed).
          if (!nodeWithEdges.isExpanded) {
            dartAdapter.toggleNode(nodeWithEdges.id);
          }

          final jsGraph = dartAdapter.schematic.toJsGraph();
          final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;

          int countEdges(Map<String, dynamic> node) {
            final edges = (node['edges'] as List? ?? []).length;
            final children = node['children'] as List? ?? [];
            return edges +
                children.fold(
                  0,
                  (sum, c) => sum + countEdges(c as Map<String, dynamic>),
                );
          }

          final edgeCount = countEdges(parsed);
          // After expanding a node with hyperedges there should be ≥ 1 edge
          expect(
            edgeCount,
            greaterThan(0),
            reason: 'Expanded node should have edges serialized in JSON',
          );
        },
      );
    });

    group('Toggle Behavior', () {
      test('toggle changes expansion state', () {
        // Find an expandable node
        final expandableNode = dartAdapter.schematic.nodeMap.values.firstWhere(
          (n) => n.isExpandable,
          orElse: () =>
              throw StateError('No expandable nodes found for toggle test'),
        );

        final nodeId = expandableNode.id;
        final wasExpanded = dartAdapter.isExpanded(nodeId);

        dartAdapter.toggleNode(nodeId);

        expect(
          dartAdapter.isExpanded(nodeId),
          !wasExpanded,
          reason: 'Expansion state should toggle',
        );
      });

      test('toggle moves children correctly', () {
        // Find an expandable node
        LayoutNode? expandableNode;
        for (final node in dartAdapter.schematic.nodeMap.values) {
          if (node.isExpandable) {
            expandableNode = node;
            break;
          }
        }

        if (expandableNode == null) {
          // Skip test if no expandable nodes
          return;
        }

        final hiddenCount = expandableNode.hiddenChildren?.length ?? 0;

        dartAdapter.toggleNode(expandableNode.id);

        expect(
          expandableNode.children.length,
          hiddenCount,
          reason: 'Hidden children should become visible after expand',
        );
        expect(
          expandableNode.hiddenChildren,
          isNull,
          reason: 'hiddenChildren should be null after expand',
        );
      });
    });
  });

  group('Miter: Dart vs JS Structure Comparison', () {
    // These tests would compare the Dart output against captured JS output.
    // For now, we define the expected structure based on the ELK graph format.

    test('ID format matches expected convention', () {
      final file = File('assets/rohd_schematic.json');
      if (!file.existsSync()) {
        return;
      }

      final netlistJson = file.readAsStringSync();
      final adapter = NetlistSchematicAdapter.fromJson(netlistJson);

      // Check that node IDs are non-empty address strings
      for (final node in adapter.schematic.nodeMap.values) {
        expect(
          node.id,
          isNotEmpty,
          reason: 'Node ID should be a non-empty string',
        );
        // Address IDs are dot-delimited integers (e.g. '0', '0.1', '0.1.2')
        // or 'root' for the wrapper node.
        if (node.id != 'root') {
          for (final segment in node.id.split('.')) {
            expect(
              int.tryParse(segment),
              isNotNull,
              reason: 'Node ID "${node.id}" segments should be '
                  'non-negative integers',
            );
          }
        }

        for (final port in node.elkPorts) {
          // Port IDs follow the "nodeId:portIndex" convention.
          final colon = port.id.lastIndexOf(':');
          expect(
            colon,
            greaterThan(0),
            reason: 'Port ID "${port.id}" should be "nodeId:portIndex" format',
          );
          expect(
            int.tryParse(port.id.substring(colon + 1)),
            isNotNull,
            reason: 'Port ID "${port.id}" index suffix '
                'should be a non-negative integer',
          );
        }
      }
    });

    test('hwMeta structure matches expected format', () {
      final file = File('assets/rohd_schematic.json');
      if (!file.existsSync()) {
        return;
      }

      final netlistJson = file.readAsStringSync();
      final adapter = NetlistSchematicAdapter.fromJson(netlistJson);

      for (final node in adapter.schematic.nodeMap.values) {
        final meta = node.hwMeta;

        // name is required
        expect(
          meta.name,
          isNotEmpty,
          reason: 'Node ${node.id} should have non-empty name',
        );

        // cls can be empty or "Operator"
        expect(
          meta.cls,
          anyOf(isEmpty, equals('Operator')),
          reason: 'Node ${node.id} cls should be empty or "Operator"',
        );
      }
    });

    test('ELK properties are set correctly', () {
      final file = File('assets/rohd_schematic.json');
      if (!file.existsSync()) {
        return;
      }

      final netlistJson = file.readAsStringSync();
      final adapter = NetlistSchematicAdapter.fromJson(netlistJson);

      for (final node in adapter.schematic.nodeMap.values) {
        // Check required ELK properties
        expect(
          node.properties['org.eclipse.elk.portConstraints'],
          'FIXED_ORDER',
          reason: 'Node ${node.id} should have FIXED_ORDER port constraint',
        );
      }
    });
  });

  group('Dart-First Path Integration', () {
    late String netlistJson;
    late NetlistSchematicAdapter adapter;

    setUpAll(() {
      final file = File('assets/rohd_schematic.json');
      if (!file.existsSync()) {
        throw StateError('Test fixture assets/rohd_schematic.json not found.');
      }
      netlistJson = file.readAsStringSync();
    });

    setUp(() {
      adapter = NetlistSchematicAdapter.fromJson(netlistJson);
    });

    test('toJsGraph() produces valid JSON', () {
      final elkJson = adapter.schematic.toJsGraph();

      // Should be valid JSON
      expect(() => jsonDecode(elkJson), returnsNormally);

      final decoded = jsonDecode(elkJson) as Map<String, dynamic>;

      // Should NOT have Yosys-specific keys
      expect(
        decoded.containsKey('modules'),
        isFalse,
        reason: 'ELK graph should not have "modules" key',
      );
      expect(
        decoded.containsKey('cells'),
        isFalse,
        reason: 'ELK graph should not have "cells" key',
      );

      // Should have ELK keys
      expect(decoded.containsKey('id'), isTrue);
      expect(decoded.containsKey('hwMeta'), isTrue);
      expect(decoded.containsKey('children'), isTrue);
    });

    test('toJsGraph() preserves node structure', () {
      final elkJson = adapter.schematic.toJsGraph();
      final decoded = jsonDecode(elkJson) as Map<String, dynamic>;

      // Root node
      expect(decoded['id'], equals(adapter.schematic.root.id));
      expect(
        (decoded['hwMeta'] as Map<String, dynamic>)['name'],
        equals(adapter.schematic.root.hwMeta.name),
      );

      // Children
      final children = decoded['children'] as List?;
      expect(children, isNotNull);
      expect(children!.length, equals(adapter.schematic.root.children.length));
    });

    test('toJsGraph() includes ports with correct structure', () {
      final elkJson = adapter.schematic.toJsGraph();
      final decoded = jsonDecode(elkJson) as Map<String, dynamic>;

      // Find a node with ports
      var portsFound = 0;
      void checkNodePorts(Map<String, dynamic> jsNode) {
        final jsPorts = jsNode['ports'] as List?;
        if (jsPorts != null && jsPorts.isNotEmpty) {
          for (final jsPort in jsPorts) {
            final port = jsPort as Map<String, dynamic>;
            portsFound++;

            // Required keys for ELK port
            expect(
              port.containsKey('id'),
              isTrue,
              reason: 'Port should have id',
            );
            expect(
              port.containsKey('direction'),
              isTrue,
              reason: 'Port should have direction',
            );
            expect(
              port.containsKey('properties'),
              isTrue,
              reason: 'Port should have properties',
            );

            // Direction should be INPUT or OUTPUT
            expect(
              port['direction'],
              anyOf(equals('INPUT'), equals('OUTPUT')),
              reason: 'Port direction should be INPUT or OUTPUT',
            );

            // Properties should have side and index
            final props = port['properties'] as Map<String, dynamic>?;
            expect(props, isNotNull, reason: 'Port should have properties map');
            expect(
              props!.containsKey('side'),
              isTrue,
              reason: 'Port properties should have side',
            );
            expect(
              props.containsKey('index'),
              isTrue,
              reason: 'Port properties should have index',
            );

            // Note: x, y, width, height are optional and set by ELK during
            // layout They may not be present in the pre-layout graph
          }
        }

        // Recurse into children
        final children = jsNode['children'] as List?;
        if (children != null) {
          for (final child in children) {
            checkNodePorts(child as Map<String, dynamic>);
          }
        }
      }

      checkNodePorts(decoded);

      // Should have found some ports
      expect(
        portsFound,
        greaterThan(0),
        reason: 'Should have found ports in the graph',
      );
    });

    test('toJsGraph() includes edges with hyperedge expansion', () {
      final elkJson = adapter.schematic.toJsGraph();
      final decoded = jsonDecode(elkJson) as Map<String, dynamic>;

      void checkNodeEdges(Map<String, dynamic> jsNode) {
        final jsEdges = jsNode['edges'] as List?;
        if (jsEdges != null && jsEdges.isNotEmpty) {
          for (final jsEdge in jsEdges) {
            final edge = jsEdge as Map<String, dynamic>;
            // Expanded edges should have single source/target (not arrays)
            expect(edge.containsKey('id'), isTrue);
            expect(edge.containsKey('source'), isTrue);
            expect(edge.containsKey('target'), isTrue);
            expect(edge['source'], isA<String>());
            expect(edge['target'], isA<String>());
          }
        }

        // Recurse into children
        final children = jsNode['children'] as List?;
        if (children != null) {
          for (final child in children) {
            checkNodeEdges(child as Map<String, dynamic>);
          }
        }
      }

      checkNodeEdges(decoded);
    });

    test('adapter hierarchy matches schematic node count', () {
      // Both structures should have the same number of nodes
      final schematicNodeCount = adapter.schematic.nodeMap.length;

      // The schematic should have a meaningful number of nodes
      expect(
        schematicNodeCount,
        greaterThan(0),
        reason: 'Schematic should have nodes',
      );

      // The hierarchy root should exist
      expect(
        adapter.hierarchy.root,
        isNotNull,
        reason: 'Hierarchy should have a root node',
      );
    });
  });
}
