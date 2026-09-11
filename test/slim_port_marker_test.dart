// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// slim_port_marker_test.dart
// Test that port markers (triangles) appear for slim JSON modules
// where cells have no connections but ports carry "connected: true".
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';

import 'test_helpers.dart';

/// Build a graph that simulates a fully-expanded slim module —
/// the module has ONLY primitive children and NO hyperedges.
///
///   root (wrapper)
///   └── top (fully expanded, no edges)
///         ├── portTop_in  (INPUT, WEST)
///         ├── portTop_out (OUTPUT, EAST)
///         │
///         ├── and0  ← primitive (Operator)
///         │     ├── portA_in  (INPUT, WEST)
///         │     └── portA_out (OUTPUT, EAST)
///         │
///         └── buf0  ← primitive (Operator)
///               ├── portB_in  (INPUT, WEST)
///               └── portB_out (OUTPUT, EAST)
///
///   No hyperedges (simulating slim data).
///   top has slimConnectedPortIds on its own ports.
///
SchematicGraph _buildSlimFullyExpandedGraph() {
  // --- Ports ---
  final portTopIn = ElkPort(
    id: 'portTop_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portTopOut = ElkPort(
    id: 'portTop_out',
    hwMeta: const HwMeta(name: 'out'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final portAIn = ElkPort(
    id: 'portA_in',
    hwMeta: const HwMeta(name: 'A'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portAOut = ElkPort(
    id: 'portA_out',
    hwMeta: const HwMeta(name: 'Y'),
    direction: 'OUTPUT',
    side: 'EAST',
  );
  final portBIn = ElkPort(
    id: 'portB_in',
    hwMeta: const HwMeta(name: 'A'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portBOut = ElkPort(
    id: 'portB_out',
    hwMeta: const HwMeta(name: 'Y'),
    direction: 'OUTPUT',
    side: 'EAST',
  );

  // --- Primitive child nodes ---
  final and0 = makeTestNode(
    'and0',
    hwMeta: const HwMeta(name: 'AND', cls: 'Operator'),
    ports: [portAIn, portAOut],
  );
  final buf0 = makeTestNode(
    'buf0',
    hwMeta: const HwMeta(name: 'BUF', cls: 'Operator'),
    ports: [portBIn, portBOut],
  );

  // --- Top module: fully expanded (children visible, no hiddenChildren) ---
  final top = makeTestNode(
    'top',
    hwMeta: const HwMeta(name: 'Top'),
    ports: [portTopIn, portTopOut],
    children: [and0, buf0], // fully expanded
    // No hyperedges — simulates slim data
  )
    // Simulate slimConnectedPortIds (set by adapter for slim modules)
    ..slimConnectedPortIds = {'portTop_in', 'portTop_out'};

  // --- Wrapper root ---
  final root = makeTestNode(
    'r',
    hwMeta: const HwMeta(name: 'root'),
    children: [top],
  );

  return SchematicGraph(
    root: root,
    nodeMap: {'r': root, 'top': top, 'and0': and0, 'buf0': buf0},
  );
}

/// Build a graph that simulates blocks-only slim mode —
/// the module is partially expanded with non-primitive child visible.
///
///   root (wrapper)
///   └── top (partially expanded, no edges)
///         ├── portTop_in  (INPUT, WEST)
///         ├── portTop_out (OUTPUT, EAST)
///         │
///         ├── `visible` submod ← non-primitive (has hiddenChildren)
///         │     ├── portS_in (INPUT, WEST)
///         │     └── portS_out (OUTPUT, EAST)
///         │     └── `hidden` inner (leaf)
///         │
///         └── `hidden` prim ← primitive
///               ├── portP_in (INPUT, WEST)
///               └── portP_out (OUTPUT, EAST)
///
SchematicGraph _buildSlimBlocksOnlyGraph() {
  final portTopIn = ElkPort(
    id: 'portTop_in',
    hwMeta: const HwMeta(name: 'in'),
    direction: 'INPUT',
    side: 'WEST',
  );
  final portTopOut = ElkPort(
    id: 'portTop_out',
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

  final inner = makeTestNode(
    'inner',
    hwMeta: const HwMeta(name: 'Inner', cls: 'Operator'),
  );

  final submod = makeTestNode(
    'submod',
    hwMeta: const HwMeta(name: 'Submod'),
    ports: [portSIn, portSOut],
    hiddenChildren: [inner], // non-primitive
  )..slimConnectedPortIds = {'portS_in', 'portS_out'};

  final prim = makeTestNode(
    'prim',
    hwMeta: const HwMeta(name: 'Prim', cls: 'Operator'),
    ports: [portPIn, portPOut],
  );

  // Top module: partially expanded (blocks-only) with only submod visible.
  final top = makeTestNode(
    'top',
    hwMeta: const HwMeta(name: 'Top'),
    ports: [portTopIn, portTopOut],
    children: [], // will be set up via partial expansion
    hiddenChildren: [submod, prim],
    // No hyperedges — slim data
  )
    ..slimConnectedPortIds = {'portTop_in', 'portTop_out'}
    ..partialChildIds = {'submod'}
    ..partialHyperedgeIds = {};

  final root = makeTestNode(
    'r',
    hwMeta: const HwMeta(name: 'root'),
    children: [top],
  );

  return SchematicGraph(
    root: root,
    nodeMap: {
      'r': root,
      'top': top,
      'submod': submod,
      'prim': prim,
      'inner': inner,
    },
  )..initNodeParents();
}

/// Add dummy layout coordinates so ElkLayoutExtractor can process the tree.
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
  group('Slim port markers', () {
    test(
        'fully expanded module with only primitives and no edges '
        '→ child ports get exterior markers', () {
      final graph = _buildSlimFullyExpandedGraph();
      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      _addDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // Primitive child ports should have exterior markers even though
      // there are no edges (slim data).
      expect(
        result.exteriorHiddenPortIds,
        contains('portA_in'),
        reason: 'AND input should show exterior marker in slim mode',
      );
      expect(
        result.exteriorHiddenPortIds,
        contains('portA_out'),
        reason: 'AND output should show exterior marker in slim mode',
      );
      expect(
        result.exteriorHiddenPortIds,
        contains('portB_in'),
        reason: 'BUF input should show exterior marker in slim mode',
      );
      expect(
        result.exteriorHiddenPortIds,
        contains('portB_out'),
        reason: 'BUF output should show exterior marker in slim mode',
      );

      // Top module's own ports should have interior markers
      // (from _connectedPorts).
      expect(
        result.interiorHiddenPortIds,
        contains('portTop_in'),
        reason: 'top input should show interior marker',
      );
      expect(
        result.interiorHiddenPortIds,
        contains('portTop_out'),
        reason: 'top output should show interior marker',
      );
    });

    test(
        'blocks-only (partially expanded) slim module '
        '→ visible submodule ports get exterior + interior markers', () {
      final graph = _buildSlimBlocksOnlyGraph();
      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      _addDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // Submodule ports should have EXTERIOR markers (parent has no edges
      // but we are in slim mode with visible children).
      expect(
        result.exteriorHiddenPortIds,
        contains('portS_in'),
        reason: 'submod input should show exterior marker',
      );
      expect(
        result.exteriorHiddenPortIds,
        contains('portS_out'),
        reason: 'submod output should show exterior marker',
      );

      // Submodule ports should also have INTERIOR markers because submod
      // has hidden children (it's non-primitive).
      expect(
        result.interiorHiddenPortIds,
        contains('portS_in'),
        reason: 'submod input should show interior marker (has children)',
      );
      expect(
        result.interiorHiddenPortIds,
        contains('portS_out'),
        reason: 'submod output should show interior marker (has children)',
      );

      // Top module's own ports should have interior markers
      // (from _connectedPorts).
      expect(result.interiorHiddenPortIds, contains('portTop_in'));
      expect(result.interiorHiddenPortIds, contains('portTop_out'));
    });

    test('_connectedPorts on collapsed child produces interior markers', () {
      // Even for a collapsed child (not visible in the parent), its own
      // _connectedPorts should add interior markers if the child appears
      // in the ELK tree (e.g., as a _children entry that gets processed).
      // In practice, collapsed children in _children are NOT processed
      // by _extractNode (only visible children are recursed), so the
      // markers come from the parent's slim fallback.

      final graph = _buildSlimBlocksOnlyGraph();
      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      _addDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // The submod (visible child) gets interior markers from its own
      // _connectedPorts and from the parent's slim fallback.
      expect(result.interiorHiddenPortIds, contains('portS_in'));
      expect(result.interiorHiddenPortIds, contains('portS_out'));
    });

    test('full-data module with edges → slim fallback does NOT fire', () {
      // When a module has proper edges, the slim fallback should NOT
      // add false markers.
      final portIn = ElkPort(
        id: 'p_in',
        hwMeta: const HwMeta(name: 'in'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final portOut = ElkPort(
        id: 'p_out',
        hwMeta: const HwMeta(name: 'out'),
        direction: 'OUTPUT',
        side: 'EAST',
      );
      final childPortIn = ElkPort(
        id: 'c_in',
        hwMeta: const HwMeta(name: 'A'),
        direction: 'INPUT',
        side: 'WEST',
      );
      final childPortOut = ElkPort(
        id: 'c_out',
        hwMeta: const HwMeta(name: 'Y'),
        direction: 'OUTPUT',
        side: 'EAST',
      );

      final child = makeTestNode(
        'child',
        hwMeta: const HwMeta(name: 'AND', cls: 'Operator'),
        ports: [childPortIn, childPortOut],
      );

      final h1 = LayoutHyperedge(
        id: 'h1',
        signal: SignalOccurrence(name: 'w1', width: 1),
        sources: [('top', 0)],
        targets: [('child', 0)],
      );

      final top = makeTestNode(
        'top',
        hwMeta: const HwMeta(name: 'Top'),
        ports: [portIn, portOut],
        children: [child],
        hyperedges: [h1],
      );

      final root = makeTestNode(
        'r',
        hwMeta: const HwMeta(name: 'root'),
        children: [top],
      );

      final graph = SchematicGraph(
        root: root,
        nodeMap: {'r': root, 'top': top, 'child': child},
      );

      final json = graph.toJsGraph();
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      _addDummyLayout(parsed);

      final result = ElkLayoutExtractor.extract(parsed);

      // c_in is connected via h1 → visible edge.
      // It should be in exteriorVisible (not exteriorHidden).
      expect(
        result.exteriorHiddenPortIds,
        isNot(contains('c_in')),
        reason: 'connected port with visible edge should NOT be in hidden',
      );

      // c_out has no edge → should NOT have any marker (no slim fallback
      // because edges exist on the module).
      // Actually, it will be in exteriorHidden from the fallback because
      // the module does have edges (from h1), so _isList(edges) is true
      // and the fallback doesn't fire. c_out has no edge → not in any set.
      expect(
        result.exteriorHiddenPortIds,
        isNot(contains('c_out')),
        reason: 'unconnected port should not have marker with full data',
      );

      // c_out should be in unconnectedPortIds (no edge references it).
      expect(
        result.unconnectedPortIds,
        contains('c_out'),
        reason: 'port with no edge should be in unconnected for outline marker',
      );
    });
  });
}
