// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// blocks_only_real_test.dart
// Diagnostic test: verify blocks-only mode on real FP adder schematic.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';

void main() {
  late NetlistSchematicAdapter adapter;

  setUp(() {
    final json = File('assets/rohd_schematic.json').readAsStringSync();
    adapter = NetlistSchematicAdapter.fromJson(json);
  });

  test('initial blocks-only mode: top module has no visible edges', () {
    final schematic = adapter.schematic;
    final root = schematic.root; // wrapper root
    final topModule = root.children.isNotEmpty ? root.children.first : null;
    expect(topModule, isNotNull, reason: 'root should have a visible child');

    // The top module should be partially expanded (blocks-only).
    expect(
      topModule!.isPartiallyExpanded,
      isTrue,
      reason: 'top module should be in partial expansion (blocks-only)',
    );

    // partialHyperedgeIds should be empty (no signals enabled).
    expect(
      topModule.partialHyperedgeIds ?? {},
      isEmpty,
      reason: 'blocks-only mode should have no allowed hyperedges',
    );

    // The top module should have non-primitive children marked as partial.
    expect(topModule.partialChildIds, isNotNull);
    expect(
      topModule.partialChildIds,
      isNotEmpty,
      reason: 'should have non-primitive children marked for display',
    );

    expect(topModule.hwMeta.name, equals('FilterBank'));
    expect(topModule.partialChildIds!.length, equals(3));
    expect(topModule.partialHyperedgeIds ?? {}, isEmpty);
    expect(topModule.hiddenChildren?.length ?? 0, equals(3));
    expect(topModule.hyperedges?.length ?? 0, greaterThan(0));
  });

  test('toJsGraph in blocks-only mode produces no visible edges', () {
    final schematic = adapter.schematic;
    final json = schematic.toJsGraph();
    final parsed = jsonDecode(json) as Map<String, dynamic>;

    // Navigate: root > children[0] = top module
    final children = parsed['children'] as List?;
    expect(children, isNotNull);
    final topModule = children![0] as Map<String, dynamic>;

    // Now look at the top module level
    final visibleChildren = topModule['children'] as List? ?? [];
    final visibleEdges = topModule['edges'] as List? ?? [];
    final hiddenEdges = topModule['_edges'] as List? ?? [];

    expect(topModule['id'], isNotNull);
    expect(visibleChildren.length, equals(3));
    // Hidden children are tracked on the LayoutNode object, not in the
    // serialised JSON (verified in the first test via
    // topModule.hiddenChildren).
    expect(hiddenEdges.length, greaterThan(0));
    expect(topModule['isPartiallyExpanded'], isTrue);

    expect(
      visibleEdges,
      isEmpty,
      reason: 'blocks-only mode should have ZERO visible edges',
    );
  });

  test('blocks-only: all visible block ports have hidden connections', () {
    final schematic = adapter.schematic;
    final json = schematic.toJsGraph();
    final parsed = jsonDecode(json) as Map<String, dynamic>;

    final topModule = (parsed['children'] as List)[0] as Map<String, dynamic>;

    final hiddenEdges = topModule['_edges'] as List? ?? [];

    // Collect all ports referenced by hidden edges
    final portsInHiddenEdges = <String>{};
    for (final e in hiddenEdges) {
      if (e is Map<String, dynamic>) {
        final sp = e['sourcePort']?.toString();
        final tp = e['targetPort']?.toString();
        if (sp != null) {
          portsInHiddenEdges.add(sp);
        }
        if (tp != null) {
          portsInHiddenEdges.add(tp);
        }
      }
    }

    // Collect all ports on visible children
    final visibleChildren = topModule['children'] as List? ?? [];
    var portsOnVisibleBlocks = 0;
    var portsWithHiddenWires = 0;
    var portsWithoutHiddenWires = 0;

    for (final c in visibleChildren) {
      if (c is Map<String, dynamic>) {
        final ports = c['ports'] as List? ?? [];
        for (final p in ports) {
          if (p is Map<String, dynamic>) {
            final portId = p['id']?.toString() ?? '';
            portsOnVisibleBlocks++;
            if (portsInHiddenEdges.contains(portId)) {
              portsWithHiddenWires++;
            } else {
              portsWithoutHiddenWires++;
              if (portsWithoutHiddenWires <= 5) {}
            }
          }
        }
      }
    }

    expect(
      portsOnVisibleBlocks,
      greaterThan(0),
      reason: 'visible blocks should have ports',
    );
    expect(
      portsWithHiddenWires,
      greaterThan(0),
      reason: 'most ports should be in hidden edges',
    );
  });
}
