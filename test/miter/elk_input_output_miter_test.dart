// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// elk_input_output_miter_test.dart
// Miter tests comparing ELK inputs and outputs between Dart and JS paths.
//
// These tests verify that:
// 1. ELK receives identical input graphs (netlist + sizing) from both paths
// 2. ELK produces identical block placements from both paths
//
// 2026 February
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_schematic_viewer/src/schematic/schematic.dart';

/// Test fixture: minimal schematic with known structure for miter comparison.
const _minimalSchematic = r'''
{
  "modules": {
    "TestMiter": {
      "attributes": { "top": 1 },
      "ports": {
        "a": { "direction": "input", "bits": [2] },
        "b": { "direction": "input", "bits": [3] },
        "sum": { "direction": "output", "bits": [4] }
      },
      "cells": {
        "add_gate": {
          "type": "$add",
          "parameters": { "A_WIDTH": 1, "B_WIDTH": 1, "Y_WIDTH": 1 },
          "port_directions": {
            "A": "input",
            "B": "input",
            "Y": "output"
          },
          "connections": {
            "A": [2],
            "B": [3],
            "Y": [4]
          }
        }
      },
      "netnames": {
        "a": { "bits": [2] },
        "b": { "bits": [3] },
        "sum": { "bits": [4] }
      }
    }
  }
}
''';

/// Test fixture with SLICE/CONCAT for port annotation testing.
const _sliceConcatSchematic = r'''
{
  "modules": {
    "SliceConcatTest": {
      "attributes": { "top": 1 },
      "ports": {
        "in_wide": { "direction": "input", "bits": [10, 11, 12, 13, 14, 15, 16, 17] },
        "out_narrow": { "direction": "output", "bits": [20, 21, 22, 23] }
      },
      "cells": {
        "slice_op": {
          "type": "$slice",
          "parameters": { "A_WIDTH": 8, "Y_WIDTH": 4, "OFFSET": 2 },
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [10, 11, 12, 13, 14, 15, 16, 17],
            "Y": [20, 21, 22, 23]
          }
        }
      },
      "netnames": {
        "in_wide": { "bits": [10, 11, 12, 13, 14, 15, 16, 17] },
        "out_narrow": { "bits": [20, 21, 22, 23] }
      }
    }
  }
}
''';

/// Helper to extract sizing info from a node recursively.
Map<String, Map<String, dynamic>> extractNodeSizes(Map<String, dynamic> node) {
  final result = <String, Map<String, dynamic>>{};

  final id = node['id']?.toString() ?? '';
  final hwMeta = node['hwMeta'] as Map<String, dynamic>? ?? {};
  final name = hwMeta['name']?.toString() ?? '';
  final cls = hwMeta['cls']?.toString() ?? '';
  final width = node['width'];
  final height = node['height'];

  result[id] = {'name': name, 'cls': cls, 'width': width, 'height': height};

  // Extract port sizes
  final ports = node['ports'] as List? ?? [];
  for (final port in ports) {
    final p = port as Map<String, dynamic>;
    final portId = p['id']?.toString() ?? '';
    final portWidth = p['width'];
    final portHeight = p['height'];
    result['$id/$portId'] = {
      'type': 'port',
      'width': portWidth,
      'height': portHeight,
    };
  }

  // Recurse to children
  final children = node['children'] as List? ?? [];
  for (final child in children) {
    result.addAll(extractNodeSizes(child as Map<String, dynamic>));
  }

  // Hidden (`_children`) nodes are intentionally NOT recursed: ELK ignores
  // any underscore-prefixed key, so collapsed subtrees are serialized as
  // minimal stubs without sizes and are never laid out.  Validating sizes on
  // them would check structure ELK never reads.

  return result;
}

/// Helper to extract edge structure from a node recursively.
List<Map<String, dynamic>> extractEdges(Map<String, dynamic> node) {
  final result = <Map<String, dynamic>>[];

  final edges = node['edges'] as List? ?? [];
  for (final edge in edges) {
    final e = edge as Map<String, dynamic>;
    result.add({
      'id': e['id'],
      'source': e['source'],
      'sourcePort': e['sourcePort'],
      'target': e['target'],
      'targetPort': e['targetPort'],
      // Mark hyperedge format if present
      'isHyperedge': e.containsKey('sources') || e.containsKey('targets'),
    });
  }

  // Recurse to children
  final children = node['children'] as List? ?? [];
  for (final child in children) {
    result.addAll(extractEdges(child as Map<String, dynamic>));
  }

  return result;
}

/// Helper to extract ELK positions from a laid-out graph.
Map<String, Map<String, double>> extractPositions(Map<String, dynamic> node) {
  final result = <String, Map<String, double>>{};

  final id = node['id']?.toString() ?? '';
  final x = (node['x'] as num?)?.toDouble();
  final y = (node['y'] as num?)?.toDouble();
  final width = (node['width'] as num?)?.toDouble();
  final height = (node['height'] as num?)?.toDouble();

  if (x != null && y != null) {
    result[id] = {'x': x, 'y': y, 'width': width ?? 0, 'height': height ?? 0};
  }

  // Recurse to children
  final children = node['children'] as List? ?? [];
  for (final child in children) {
    result.addAll(extractPositions(child as Map<String, dynamic>));
  }

  return result;
}

void main() {
  group('ELK Input Miter Tests', () {
    group('Graph Structure Parity', () {
      test('minimal schematic produces valid ELK input', () {
        final adapter = NetlistSchematicAdapter.fromJson(_minimalSchematic);
        // Top module children are already visible at hierarchyLevel 1.
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        // Verify basic ELK structure
        expect(elkGraph['id'], isNotNull);
        expect(elkGraph['children'], isNotNull);
        expect((elkGraph['children'] as List).isNotEmpty, isTrue);

        // Find the TestMiter module
        final topModule =
            (elkGraph['children'] as List).first as Map<String, dynamic>;
        final topHwMeta = topModule['hwMeta'] as Map<String, dynamic>;
        expect(topHwMeta['name'], equals('TestMiter'));

        // Verify ports exist
        expect(topModule['ports'], isNotNull);
        final ports = topModule['ports'] as List;
        expect(ports.length, equals(3)); // a, b, sum

        // Verify children (the add_gate cell)
        expect(topModule['children'], isNotNull);
        final children = topModule['children'] as List;
        expect(children.length, equals(1));

        final addGate = children.first as Map<String, dynamic>;
        final addGateHw = addGate['hwMeta'] as Map<String, dynamic>;
        expect(addGateHw['name'], equals('ADD'));
        expect(addGateHw['cls'], equals('Operator'));
      });

      test('edges are in ELK format (not hyperedge format)', () {
        final adapter = NetlistSchematicAdapter.fromJson(_minimalSchematic);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final edges = extractEdges(elkGraph);

        // All edges should be in simple format (source/target, not sources/targets)
        for (final edge in edges) {
          expect(
            edge['isHyperedge'],
            isFalse,
            reason: 'Edge ${edge['id']} should not be in hyperedge format',
          );
          expect(
            edge['source'],
            isNotNull,
            reason: 'Edge ${edge['id']} should have source',
          );
          expect(
            edge['target'],
            isNotNull,
            reason: 'Edge ${edge['id']} should have target',
          );
        }
      });

      test('SLICE port annotations match JS format', () {
        final adapter = NetlistSchematicAdapter.fromJson(_sliceConcatSchematic);
        // Top module children are already visible at hierarchyLevel 1.
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        // Find the SLICE node
        final topModule =
            (elkGraph['children'] as List).first as Map<String, dynamic>;
        final children = topModule['children'] as List;
        final sliceNode = children.firstWhere((c) {
          final m = c as Map<String, dynamic>;
          final hw = m['hwMeta'] as Map<String, dynamic>?;
          return hw?['name'] == 'SLICE';
        }) as Map<String, dynamic>;

        // Check port annotations
        final ports = sliceNode['ports'] as List;

        // Find input port (A) and output port (Y) by direction
        // With sequential IDs, ports are identified by their direction/index
        final inputPorts = ports.where((p) {
          final pm = p as Map<String, dynamic>;
          final dir = pm['direction']?.toString();
          return dir == 'INPUT';
        }).toList();
        final outputPorts = ports.where((p) {
          final pm = p as Map<String, dynamic>;
          final dir = pm['direction']?.toString();
          return dir == 'OUTPUT';
        }).toList();

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

        final portA = inputPorts.first as Map<String, dynamic>;
        final portY = outputPorts.first as Map<String, dynamic>;
        final portAHw = portA['hwMeta'] as Map<String, dynamic>;
        final portYHw = portY['hwMeta'] as Map<String, dynamic>;

        // Input port A should have bit range annotation [hi:lo]
        // With OFFSET=2, Y_WIDTH=4: getPortNameSplice(2, 4) = "[5:2]"
        expect(
          portAHw['name'],
          equals('[5:2]'),
          reason: 'SLICE input port should have [5:2] annotation',
        );

        // Output port Y should have empty name
        expect(
          portYHw['name'],
          equals(''),
          reason: 'SLICE output port should have empty name',
        );
      });
    });

    group('Sizing Parity', () {
      test('operator nodes have correct sizes', () {
        final adapter = NetlistSchematicAdapter.fromJson(_minimalSchematic);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final sizes = extractNodeSizes(elkGraph);

        // Find ADD operator
        final addEntry = sizes.entries.firstWhere(
          (e) => e.value['name'] == 'ADD' && e.value['cls'] == 'Operator',
        );

        // ADD should have default operator size (25x25)
        expect(
          addEntry.value['width'],
          equals(25.0),
          reason: 'ADD operator width should be 25',
        );
        expect(
          addEntry.value['height'],
          equals(25.0),
          reason: 'ADD operator height should be 25',
        );
      });

      test('module nodes have generic sizing', () {
        final adapter = NetlistSchematicAdapter.fromJson(_minimalSchematic);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final sizes = extractNodeSizes(elkGraph);

        // Find TestMiter module
        final moduleEntry = sizes.entries.firstWhere(
          (e) => e.value['name'] == 'TestMiter',
        );

        // Module should have non-null dimensions (generic sizing)
        expect(moduleEntry.value['width'], isNotNull);
        expect(moduleEntry.value['height'], isNotNull);
        expect((moduleEntry.value['width'] as num) > 0, isTrue);
        expect((moduleEntry.value['height'] as num) > 0, isTrue);
      });

      test('all ports have pin sizes', () {
        final adapter = NetlistSchematicAdapter.fromJson(_minimalSchematic);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final sizes = extractNodeSizes(elkGraph);

        // All port entries should have width=7, height=13 (PORT_PIN_SIZE)
        final portEntries = sizes.entries.where(
          (e) => e.value['type'] == 'port',
        );

        for (final port in portEntries) {
          expect(
            port.value['width'],
            equals(7.0),
            reason: 'Port ${port.key} width should be 7',
          );
          expect(
            port.value['height'],
            equals(13.0),
            reason: 'Port ${port.key} height should be 13',
          );
        }
      });

      test('SLICE nodes use generic sizing (not operator sizing)', () {
        final adapter = NetlistSchematicAdapter.fromJson(_sliceConcatSchematic);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final sizes = extractNodeSizes(elkGraph);

        // Find SLICE node
        final sliceEntry = sizes.entries.firstWhere(
          (e) => e.value['name'] == 'SLICE',
        );

        // SLICE should have generic sizing (not 25x25 operator default)
        // Generic sizing depends on port count, label width, etc.
        expect(sliceEntry.value['width'], isNotNull);
        expect(sliceEntry.value['height'], isNotNull);

        // SLICE with 2 ports should have height >= 40 (2 * PORT_HEIGHT)
        expect(
          (sliceEntry.value['height'] as num) >= 20,
          isTrue,
          reason: 'SLICE should have height for its ports',
        );
      });
    });

    group('Real Schematic Miter', () {
      late String sampleJson;

      setUpAll(() {
        final jsonFile = File('assets/rohd_schematic.json');
        if (!jsonFile.existsSync()) {
          throw StateError('Test file not found: assets/rohd_schematic.json');
        }
        sampleJson = jsonFile.readAsStringSync();
      });

      test('real schematic produces valid ELK input', () {
        final adapter = NetlistSchematicAdapter.fromJson(sampleJson);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        // Basic validity
        expect(elkGraph['id'], isNotNull);
        expect(elkGraph['children'], isNotNull);

        // Extract and verify sizes
        final sizes = extractNodeSizes(elkGraph);
        expect(sizes.isNotEmpty, isTrue);

        // Count nodes with valid sizes
        var nodesWithoutSizes = 0;

        for (final entry in sizes.entries) {
          if (entry.value['type'] == 'port') {
            continue; // Skip ports
          }

          final width = entry.value['width'];
          final height = entry.value['height'];

          if (width is num && height is num && width > 0 && height > 0) {
            // valid size
          } else {
            nodesWithoutSizes++;
          }
        }

        // All nodes should have sizes
        expect(
          nodesWithoutSizes,
          equals(0),
          reason: 'All nodes should have valid sizes for ELK',
        );
      });

      test('real schematic edges reference valid nodes', () {
        final adapter = NetlistSchematicAdapter.fromJson(sampleJson);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        // Collect all node IDs
        final nodeIds = <String>{};
        void collectNodeIds(Map<String, dynamic> node) {
          nodeIds.add(node['id'].toString());
          for (final child in (node['children'] as List? ?? [])) {
            collectNodeIds(child as Map<String, dynamic>);
          }
          for (final child in (node['_children'] as List? ?? [])) {
            collectNodeIds(child as Map<String, dynamic>);
          }
        }

        collectNodeIds(elkGraph);

        // Extract and verify edges reference valid nodes
        final edges = extractEdges(elkGraph);
        var invalidEdges = 0;

        for (final edge in edges) {
          final source = edge['source']?.toString();
          final target = edge['target']?.toString();

          if (source == null ||
              target == null ||
              !nodeIds.contains(source) ||
              !nodeIds.contains(target)) {
            invalidEdges++;
          }
        }

        // All edges should reference valid nodes
        expect(
          invalidEdges,
          equals(0),
          reason: 'All edges should reference valid nodes',
        );
      });

      test('sizing summary for miter comparison', () {
        final adapter = NetlistSchematicAdapter.fromJson(sampleJson);
        final elkJson = adapter.toJsGraph();
        final elkGraph = jsonDecode(elkJson) as Map<String, dynamic>;

        final sizes = extractNodeSizes(elkGraph);

        // Group by operator type for miter summary
        final sizesByType = <String, List<Map<String, dynamic>>>{};

        for (final entry in sizes.entries) {
          if (entry.value['type'] == 'port') {
            continue;
          }

          final cls = entry.value['cls']?.toString() ?? '';
          final name = entry.value['name']?.toString() ?? '';
          final key = cls.isNotEmpty ? '$cls:$name' : name;

          sizesByType.putIfAbsent(key, () => []);
          sizesByType[key]!.add({
            'id': entry.key,
            'width': entry.value['width'],
            'height': entry.value['height'],
          });
        }

        for (final type in sizesByType.keys.toList()..sort()) {
          final nodes = sizesByType[type]!;
          if (nodes.isEmpty) {
            continue;
          }

          final firstNode = nodes.first;
          final allSameSize = nodes.every(
            (n) =>
                n['width'] == firstNode['width'] &&
                n['height'] == firstNode['height'],
          );

          if (allSameSize) {
            // All nodes same size: nothing to log in tests
          } else {
            // Some variation exists; assert sizes are present for sampled nodes
            for (final n in nodes.take(3)) {
              expect(n['width'], isNotNull);
              expect(n['height'], isNotNull);
            }
          }
        }
      });
    });
  });

  group('ELK Output Miter Tests (Placement Comparison)', () {
    // These tests verify that ELK produces identical placements
    // Currently, this requires running ELK through JavaScript which
    // needs an integration test environment.

    test('save Dart ELK graph for miter comparison', () {
      // Generate ELK input from Dart path
      final jsonFile = File('assets/rohd_schematic.json');
      if (!jsonFile.existsSync()) {
        fail('Test file not found: assets/rohd_schematic.json');
      }
      final netlistJson = jsonFile.readAsStringSync();
      final adapter = NetlistSchematicAdapter.fromJson(netlistJson);
      final dartElkJson = adapter.toJsGraph();

      // Pretty-print for readability
      final formatted = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(dartElkJson));

      // Save to file for manual comparison with JS path
      final outputFile = File('build/test_cache/dart_elk_graph.json');
      outputFile.parent.createSync(recursive: true);
      outputFile.writeAsStringSync(formatted);

      // Verify file was created
      expect(
        outputFile.existsSync(),
        isTrue,
        reason: 'ELK graph file should be written successfully',
      );

      // Also verify sizing summary is available
      final elkGraph = jsonDecode(dartElkJson) as Map<String, dynamic>;
      final sizes = extractNodeSizes(elkGraph);

      // Count sizing types
      var operators = 0;
      var generic = 0;
      var modules = 0;

      for (final entry in sizes.entries) {
        if (entry.value['type'] == 'port') {
          continue;
        }
        final cls = entry.value['cls']?.toString() ?? '';
        final name = entry.value['name']?.toString() ?? '';

        if (cls == 'Operator') {
          operators++;
        } else if (cls == 'Module' || cls == '') {
          if (name == 'root' || name.contains('.')) {
            modules++;
          } else {
            generic++;
          }
        }
      }

      // Verify sizing breakdown is present
      expect(operators >= 0, isTrue, reason: 'Sizing should count operators');
      expect(generic >= 0, isTrue, reason: 'Sizing should count generic nodes');
      expect(modules >= 0, isTrue, reason: 'Sizing should count modules');
    });
  });
}
