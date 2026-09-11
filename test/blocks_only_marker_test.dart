// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// blocks_only_marker_test.dart
// Diagnostic test for blocks-only mode exterior
// port markers.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

// Fixture JSON is intentionally decoded dynamically to mirror netlist input.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';

import 'test_helpers.dart';

/// Build a test graph where root has both non-primitive and primitive children.
///
///   root
///   ├── portR_in (INPUT, WEST)
///   ├── portR_out (OUTPUT, EAST)
///   │
///   ├── `hidden` submod  ← non-primitive (has hiddenChildren)
///   │     ├── portS_in (INPUT, WEST)
///   │     └── portS_out (OUTPUT, EAST)
///   │     └── `hidden` subchild (no ports/edges)
///   │
///   └── `hidden` prim   ← primitive (no children)
///         ├── portP_in (INPUT, WEST)
///         └── portP_out (OUTPUT, EAST)
///
///   Hyperedges on root:
///     h1: root:portR_in  →  prim:portP_in
///     h2: prim:portP_out →  submod:portS_in
///     h3: submod:portS_out → root:portR_out
///
SchematicGraph _buildBlocksOnlyGraph() {
  // --- Ports ---
  final portRIn = ElkPort(
    id: 'portR_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portROut = ElkPort(
    id: 'portR_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final portSIn = ElkPort(
    id: 'portS_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portSOut = ElkPort(
    id: 'portS_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final portPIn = ElkPort(
    id: 'portP_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portPOut = ElkPort(
    id: 'portP_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );

  // --- Child nodes ---
  final subchild = makeTestNode(
    'subchild',
    hwMeta: const HwMeta(name: 'SubChild'),
  );
  final submod = makeTestNode(
    'submod',
    hwMeta: const HwMeta(name: 'Submod'),
    ports: [portSIn, portSOut],
    hiddenChildren: [subchild], // ← non-primitive
  );
  final prim = makeTestNode(
    'prim',
    hwMeta: const HwMeta(name: 'Prim', cls: 'Operator'),
    ports: [portPIn, portPOut],
    // no children → primitive
  );

  // --- Hyperedges ---
  final h1 = LayoutHyperedge(
    id: 'h1',
    signal: SignalOccurrence(name: 'sig1', width: 1),
    sources: [('root', 0)],
    targets: [('prim', 0)],
  );
  final h2 = LayoutHyperedge(
    id: 'h2',
    signal: SignalOccurrence(name: 'sig2', width: 1),
    sources: [('prim', 1)],
    targets: [('submod', 0)],
  );
  final h3 = LayoutHyperedge(
    id: 'h3',
    signal: SignalOccurrence(name: 'sig3', width: 1),
    sources: [('submod', 1)],
    targets: [('root', 1)],
  );

  // --- Root node (all children hidden = collapsed) ---
  final root = makeTestNode(
    'root',
    hwMeta: const HwMeta(name: 'Root'),
    ports: [portRIn, portROut],
    children: [],
    hiddenChildren: [submod, prim],
    hyperedges: [h1, h2, h3],
  );

  final nodeMap = <String, LayoutNode>{
    'root': root,
    'submod': submod,
    'prim': prim,
    'subchild': subchild,
  };

  return SchematicGraph(root: root, nodeMap: nodeMap);
}

/// Add dummy layout coordinates to a node tree so the extractor works.
void _addDummyLayout(
  Map<String, dynamic> node, {
  double dx = 0,
  double dy = 0,
}) {
  node['x'] ??= dx;
  node['y'] ??= dy;
  node['width'] ??= 100.0;
  node['height'] ??= 80.0;

  var px = 0.0;
  for (final p in (node['ports'] as List?) ?? []) {
    if (p is Map<String, dynamic>) {
      p['x'] ??= 0.0;
      p['y'] ??= px;
      p['width'] ??= 10.0;
      p['height'] ??= 10.0;
      px += 15;
    }
  }

  var cx = 20.0;
  for (final c in (node['children'] as List?) ?? []) {
    if (c is Map<String, dynamic>) {
      _addDummyLayout(c, dx: cx, dy: 20);
      cx += 120;
    }
  }
}

void main() {
  group('Blocks-only mode port markers', () {
    test('expandNonPrimitives(includeEdges: false) identifies submod', () {
      final graph = _buildBlocksOnlyGraph();
      final result = graph.expandNonPrimitives('root', includeEdges: false);
      expect(result, isTrue, reason: 'submod is non-primitive');

      final root = graph.root;
      expect(root.partialChildIds, contains('submod'));
      expect(root.partialChildIds, isNot(contains('prim')));
      expect(root.partialHyperedgeIds, isEmpty);
    });

    test('toJsGraph produces _edges in blocks-only mode', () {
      final graph = _buildBlocksOnlyGraph();
      final json =
          (graph..expandNonPrimitives('root', includeEdges: false)).toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;

      // Visible children: submod only
      final children = parsed['children'] as List?;
      expect(children, isNotNull);
      expect(children!.length, 1);
      expect(children[0]['id'], 'submod');

      // Hidden children: prim only
      final hiddenChildren = parsed['_children'] as List?;
      expect(hiddenChildren, isNotNull);
      expect(hiddenChildren!.length, 1);
      expect(hiddenChildren[0]['id'], 'prim');

      // No visible edges
      expect(
        parsed['edges'],
        isNull,
        reason: 'blocks-only should have no visible edges',
      );

      // THE KEY CHECK: _edges should have all 3 hidden edges
      final hiddenEdges = parsed['_edges'] as List?;
      expect(
        hiddenEdges,
        isNotNull,
        reason: '_edges must be present for marker detection',
      );
      expect(hiddenEdges!.length, 3);

      // Verify submod's ports are referenced in hidden edges
      final allPorts =
          hiddenEdges.expand((e) => [e['sourcePort'], e['targetPort']]).toSet();
      expect(
        allPorts,
        contains('portS_in'),
        reason: 'hidden edge should reference submod input',
      );
      expect(
        allPorts,
        contains('portS_out'),
        reason: 'hidden edge should reference submod output',
      );
    });

    test('extractor produces correct exteriorHiddenPortIds', () {
      final graph = _buildBlocksOnlyGraph();
      final json =
          (graph..expandNonPrimitives('root', includeEdges: false)).toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;

      // Add dummy layout coordinates (simulate ELK output)
      _addDummyLayout(parsed);

      // Run extractor
      final result = ElkLayoutExtractor.extract(parsed);

      // Submod ports should be in exteriorHiddenPortIds
      expect(
        result.exteriorHiddenPortIds,
        contains('portS_in'),
        reason: 'submod input port should show exterior marker (hidden wire)',
      );
      expect(
        result.exteriorHiddenPortIds,
        contains('portS_out'),
        reason: 'submod output port should show exterior marker (hidden wire)',
      );

      // Root's own ports should be in interiorHiddenPortIds
      expect(
        result.interiorHiddenPortIds,
        contains('portR_in'),
        reason: 'root input should show interior marker',
      );
      expect(
        result.interiorHiddenPortIds,
        contains('portR_out'),
        reason: 'root output should show interior marker',
      );

      // Primitive ports should also be in exteriorHidden (but won't render
      // since prim isn't visible)
      expect(result.exteriorHiddenPortIds, contains('portP_in'));
      expect(result.exteriorHiddenPortIds, contains('portP_out'));
    });

    test('after port expansion, primitive other ports in exteriorHidden', () {
      final graph = _buildBlocksOnlyGraph();

      // Start with blocks-only
      final expanded = (graph..expandNonPrimitives('root', includeEdges: false))
          .expandPort('root', 'portS_in');

      // Expand port: click on submod's portS_in (exterior marker)
      // This should reveal h2 (prim→submod) and prim as connected child
      expect(expanded, isTrue);

      // Now prim should be in partialChildIds (connected via h2)
      expect(graph.root.partialChildIds, contains('prim'));

      // h2 should be in partialHyperedgeIds
      expect(graph.root.partialHyperedgeIds, contains('h2'));

      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      _addDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // prim is now visible. Its other port (portP_in) connects via h1
      // which is NOT in partialHyperedgeIds. So h1 should be in _edges.
      // portP_in should be in exteriorHiddenPortIds.
      expect(
        result.exteriorHiddenPortIds,
        contains('portP_in'),
        reason: 'primitive input port should show exterior marker '
            '(connected to hidden wire h1)',
      );
    });

    test('convertToBlocksOnly from fully expanded', () {
      final graph = _buildBlocksOnlyGraph();

      // Fully expand root.
      final result = (graph..toggleNode('root')).convertToBlocksOnly('root');

      // Convert to blocks-only.
      expect(
        result,
        isTrue,
        reason: 'submod is non-primitive → conversion should succeed',
      );

      // Should now be partially expanded with only submod visible.
      expect(graph.root.isPartiallyExpanded, isTrue);
      expect(graph.root.isExpanded, isFalse);
      expect(graph.root.children.length, 0);
      expect(graph.root.partialChildIds, contains('submod'));
      expect(graph.root.partialChildIds, isNot(contains('prim')));

      // Edges should be empty (blocks-only = no edges).
      expect(graph.root.partialHyperedgeIds, isEmpty);

      // Verify toJsGraph output.
      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;

      final children = parsed['children'] as List?;
      expect(children, isNotNull);
      expect(children!.length, 1);
      expect(children[0]['id'], 'submod');

      // No visible edges.
      expect(parsed['edges'], isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // Real schematic: unconnected port detection
  // ─────────────────────────────────────────────────────────────────
  group('Unconnected ports on real FilterBank', () {
    late NetlistSchematicAdapter adapter;

    setUp(() {
      final raw = File('assets/rohd_schematic.json').readAsStringSync();
      final fullJson = jsonDecode(raw) as Map<String, dynamic>;
      adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
    });

    test('ch1/validOut is in unconnectedPortIds (blocks-only)', () {
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;
      expect(top.hwMeta.name, 'FilterBank');
      expect(top.isPartiallyExpanded, isTrue);

      // Find ch1/validOut port ID.
      String? validOutPortId;
      for (final hc in top.hiddenChildren ?? <LayoutNode>[]) {
        if (hc.hwMeta.name.split(' (').first == 'ch1') {
          for (final p in hc.elkPorts) {
            if (p.hwMeta.name == 'validOut') {
              validOutPortId = p.id;
            }
          }
        }
      }
      expect(validOutPortId, isNotNull, reason: 'ch1/validOut should exist');

      // Serialize and add dummy layout for extraction.
      final jsGraph = schematic.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;
      _addRealDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // ch1/validOut has no hyperedge at FilterBank level.
      // It should NOT be in exteriorHidden (no edge references it).
      expect(
        result.exteriorHiddenPortIds,
        isNot(contains(validOutPortId)),
        reason: 'validOut has no edge → not in exteriorHidden',
      );

      // It SHOULD be in unconnectedPortIds.
      expect(
        result.unconnectedPortIds,
        contains(validOutPortId),
        reason:
            'validOut has no edge at FilterBank level → should be unconnected',
      );
    });

    test('controller/loadingPhase is in unconnectedPortIds', () {
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      // Find controller/loadingPhase port ID.
      String? loadingPhaseId;
      for (final hc in top.hiddenChildren ?? <LayoutNode>[]) {
        if (hc.hwMeta.name.split(' (').first == 'controller') {
          for (final p in hc.elkPorts) {
            if (p.hwMeta.name == 'loadingPhase') {
              loadingPhaseId = p.id;
            }
          }
        }
      }
      expect(
        loadingPhaseId,
        isNotNull,
        reason: 'controller/loadingPhase should exist',
      );

      final jsGraph = schematic.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;
      _addRealDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);
      expect(
        result.unconnectedPortIds,
        contains(loadingPhaseId),
        reason: 'loadingPhase has no edge at FilterBank level',
      );
    });

    test('slim mode: all ports are in exteriorHidden, none unconnected', () {
      // In slim mode (no edges), all ports should show filled markers
      // (optimistic assumption), not outline markers.
      final raw = File('assets/rohd_schematic.json').readAsStringSync();
      final fullJson = jsonDecode(raw) as Map<String, dynamic>;
      final fullModules = fullJson['modules'] as Map<String, dynamic>;

      // Build slim modules (strip connections).
      final slimModules = <String, dynamic>{};
      for (final entry in fullModules.entries) {
        final mod = Map<String, dynamic>.from(entry.value as Map);
        final cells = mod['cells'] as Map<String, dynamic>?;
        if (cells != null) {
          final slimCells = <String, dynamic>{};
          for (final cellEntry in cells.entries) {
            final cell = Map<String, dynamic>.from(cellEntry.value as Map)
              ..remove('connections');
            slimCells[cellEntry.key] = cell;
          }
          mod['cells'] = slimCells;
        }
        slimModules[entry.key] = mod;
      }
      final slimJsonString = jsonEncode({
        'creator': fullJson['creator'],
        'modules': slimModules,
      });

      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      final schematic = slimAdapter.schematic;
      final top = schematic.root.children.first;
      expect(top.hwMeta.name, 'FilterBank');

      final jsGraph = schematic.toJsGraph();
      final parsed = jsonDecode(jsGraph) as Map<String, dynamic>;
      _addRealDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // Slim mode: no edge data → slim fallback fires.
      // All child ports should be in exteriorHidden (filled markers).
      // unconnectedPortIds should be empty (no outline markers).
      expect(
        result.unconnectedPortIds,
        isEmpty,
        reason: 'Slim mode should have no unconnected ports '
            '(all ports presumed connected)',
      );
      expect(
        result.exteriorHiddenPortIds,
        isNotEmpty,
        reason: 'Slim mode should mark all ports as exterior hidden',
      );
    });
  });
}

/// Add dummy layout coordinates recursively (for real schematics).
void _addRealDummyLayout(Map<String, dynamic> node) {
  node['x'] ??= 0.0;
  node['y'] ??= 0.0;
  node['width'] ??= 100.0;
  node['height'] ??= 100.0;

  final ports = node['ports'];
  if (ports is List) {
    var py = 10.0;
    for (final p in ports) {
      if (p is Map<String, dynamic>) {
        p['x'] ??= 0.0;
        p['y'] ??= py;
        p['width'] ??= 10.0;
        p['height'] ??= 10.0;
        py += 15;
      }
    }
  }

  for (final key in ['children', '_children']) {
    final children = node[key];
    if (children is List) {
      var cx = 20.0;
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          child['x'] ??= cx;
          child['y'] ??= 20.0;
          _addRealDummyLayout(child);
          cx += 120;
        }
      }
    }
  }
}
