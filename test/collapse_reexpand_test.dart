// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// collapse_reexpand_test.dart
// Regression test: fully expand a block, collapse a child port's edges,
// then re-expand that same port.  The bug is that after converting from
// fully-expanded to partially-expanded (during the collapse), the
// subsequent expandPort or expandPortThrough refuses to work.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';

/// Extract visible edges from the top module in the serialized JSON.
Set<String> _extractEdgeSet(String jsGraphJson) {
  final root = jsonDecode(jsGraphJson) as Map<String, dynamic>;
  final topChildren = root['children'] as List? ?? [];
  if (topChildren.isEmpty) {
    return {};
  }
  final topModule = topChildren[0] as Map<String, dynamic>;
  final edges = topModule['edges'] as List? ?? [];
  return edges.map((e) {
    final m = e as Map<String, dynamic>;
    return '${m['sourcePort']}→${m['targetPort']}';
  }).toSet();
}

/// Extract hidden edges from the top module in the serialized JSON.
Set<String> _extractHiddenEdgeSet(String jsGraphJson) {
  final root = jsonDecode(jsGraphJson) as Map<String, dynamic>;
  final topChildren = root['children'] as List? ?? [];
  if (topChildren.isEmpty) {
    return {};
  }
  final topModule = topChildren[0] as Map<String, dynamic>;
  final edges = topModule['_edges'] as List? ?? [];
  return edges.map((e) {
    final m = e as Map<String, dynamic>;
    return '${m['sourcePort']}→${m['targetPort']}';
  }).toSet();
}

void main() {
  late Map<String, dynamic> fullJson;

  setUpAll(() {
    final raw = File('assets/rohd_schematic.json').readAsStringSync();
    fullJson = jsonDecode(raw) as Map<String, dynamic>;
  });

  group('Fully-expanded collapse then re-expand', () {
    test('collapse then expandPortThrough on same port succeeds', () {
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      expect(top.hwMeta.name, equals('FilterBank'));

      // Collapse blocks-only, then fully expand.
      schematic
        ..collapsePartialExpansion(top.id)
        ..toggleNode(top.id);
      expect(top.isExpanded, isTrue);
      expect(top.isPartiallyExpanded, isFalse);

      // Capture reference edges.
      final refJson = schematic.toJsGraph();
      final refVisibleEdges = _extractEdgeSet(refJson);
      final refHiddenEdges = _extractHiddenEdgeSet(refJson);
      expect(
        refVisibleEdges,
        isNotEmpty,
        reason: 'Fully expanded should have visible edges',
      );

      // Pick a child instance port that participates in a visible edge.
      String? targetPortId;
      for (final child in top.children) {
        if (child.elkPorts.isEmpty) {
          continue;
        }
        for (final port in child.elkPorts) {
          if (refVisibleEdges.any((e) => e.contains(port.id))) {
            targetPortId = port.id;
            break;
          }
        }
        if (targetPortId != null) {
          break;
        }
      }
      expect(
        targetPortId,
        isNotNull,
        reason: 'Should find a child port in edges',
      );

      // Collapse the port.
      final collapsed = schematic.collapsePortThrough(top.id, targetPortId!);
      expect(collapsed, isTrue, reason: 'collapsePortThrough should succeed');

      // Serialize (simulates layout cycle in the UI).
      final afterCollapseJson = schematic.toJsGraph();
      final afterVisible = _extractEdgeSet(afterCollapseJson);
      final afterHidden = _extractHiddenEdgeSet(afterCollapseJson);

      // Total edges preserved.
      expect(
        afterVisible.length + afterHidden.length,
        equals(refVisibleEdges.length + refHiddenEdges.length),
        reason: 'Total edges should be preserved',
      );

      // Re-expand the same port.
      final expanded = schematic.expandPortThrough(top.id, targetPortId);
      expect(
        expanded,
        isTrue,
        reason: 'expandPortThrough should succeed after collapse',
      );
    });

    test('collapse then expandPort on same port succeeds', () {
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      schematic
        ..collapsePartialExpansion(top.id)
        ..toggleNode(top.id);
      expect(top.isExpanded, isTrue);

      final refJson = schematic.toJsGraph();
      final refVisible = _extractEdgeSet(refJson);

      String? targetPortId;
      for (final child in top.children) {
        for (final port in child.elkPorts) {
          if (refVisible.any((e) => e.contains(port.id))) {
            targetPortId = port.id;
            break;
          }
        }
        if (targetPortId != null) {
          break;
        }
      }
      expect(targetPortId, isNotNull);

      final collapsed = schematic.collapsePortThrough(top.id, targetPortId!);
      expect(collapsed, isTrue);

      // Serialize to simulate layout cycle.
      schematic.toJsGraph();

      final expanded = schematic.expandPort(top.id, targetPortId);
      expect(
        expanded,
        isTrue,
        reason: 'expandPort should succeed after collapse',
      );
    });

    test('multiple collapse-expand cycles on same port', () {
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      schematic
        ..collapsePartialExpansion(top.id)
        ..toggleNode(top.id);

      final refJson = schematic.toJsGraph();
      final refVisible = _extractEdgeSet(refJson);

      String? targetPortId;
      for (final child in top.children) {
        for (final port in child.elkPorts) {
          if (refVisible.any((e) => e.contains(port.id))) {
            targetPortId = port.id;
            break;
          }
        }
        if (targetPortId != null) {
          break;
        }
      }
      expect(targetPortId, isNotNull);

      for (var i = 0; i < 3; i++) {
        final collapsed = schematic.collapsePortThrough(top.id, targetPortId!);
        expect(collapsed, isTrue, reason: 'Collapse cycle $i should succeed');

        schematic.toJsGraph();

        final expanded = schematic.expandPortThrough(top.id, targetPortId);
        expect(expanded, isTrue, reason: 'Expand cycle $i should succeed');

        schematic.toJsGraph();
      }
    });

    test('collapsed port has bowtie marker (exteriorHiddenPortIds)', () {
      // This test verifies the UI-level marker state: after collapsing
      // a port from a fully-expanded block, the port must appear in
      // exteriorHiddenPortIds so the bowtie marker is drawn and the
      // user can click to re-expand.
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      schematic
        ..collapsePartialExpansion(top.id)
        ..toggleNode(top.id);
      expect(top.isExpanded, isTrue);

      // Pick a child port with visible edges.
      final refJson = schematic.toJsGraph();
      final refVisible = _extractEdgeSet(refJson);

      String? targetPortId;
      for (final child in top.children) {
        for (final port in child.elkPorts) {
          if (refVisible.any((e) => e.contains(port.id))) {
            targetPortId = port.id;
            break;
          }
        }
        if (targetPortId != null) {
          break;
        }
      }
      expect(targetPortId, isNotNull);

      // Before collapse: no hidden port markers needed (all visible).
      // Collapse the port.
      final collapsed = schematic.collapsePortThrough(top.id, targetPortId!);
      expect(collapsed, isTrue);

      // Get the post-collapse layout data.
      final afterJson = schematic.toJsGraph();
      final afterParsed = jsonDecode(afterJson) as Map<String, dynamic>;
      final afterLayout = ElkLayoutExtractor.extract(afterParsed);

      // Check: the port should have a bowtie marker.
      final hasMarker =
          afterLayout.exteriorHiddenPortIds.contains(targetPortId) ||
              afterLayout.interiorHiddenPortIds.contains(targetPortId);
      expect(
        hasMarker,
        isTrue,
        reason: 'Port "$targetPortId" should have a bowtie marker '
            'after collapse, so the user can click to re-expand. '
            'exteriorHidden: ${afterLayout.exteriorHiddenPortIds}, '
            'interiorHidden: ${afterLayout.interiorHiddenPortIds}',
      );
    });
  });
}
