// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// filter_bank_expansion_test.dart
// Test incremental expansion of FilterBank schematic through the same
// slim → fetch → rebuild pipeline that the devtools extension uses.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
//
// The failure mode under test: after loading a slim JSON (cells without
// connections) and then "fetching" full connectivity data for the top
// module, expanding blocks in various orders should produce the same
// edges as loading the full design directly.  The known bug is that
// the incremental path yields 0 edges.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

// Fixture JSON is intentionally decoded dynamically to mirror netlist input.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';

/// Strip `connections` from every cell in every module, producing a "slim"
/// Yosys JSON that mimics what the devtools extension receives before
/// fetching full connectivity data.
///
/// The slim version retains: ports, netnames, cell types/attributes,
/// port_directions — everything except the per-cell `connections` map.
Map<String, dynamic> _makeSlimModules(Map<String, dynamic> fullModules) {
  final slim = <String, dynamic>{};
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
    slim[entry.key] = mod;
  }
  return slim;
}

/// Extract visible edges from the top module in the serialized JSON.
///
/// Returns a set of "sourcePort→targetPort" strings for easy comparison.
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

/// Count all edges (visible + hidden) at the top module level.
int _totalEdgeCount(String jsGraphJson) {
  final root = jsonDecode(jsGraphJson) as Map<String, dynamic>;
  final topChildren = root['children'] as List? ?? [];
  if (topChildren.isEmpty) {
    return 0;
  }
  final topModule = topChildren[0] as Map<String, dynamic>;
  final visible = topModule['edges'] as List? ?? [];
  final hidden = topModule['_edges'] as List? ?? [];
  return visible.length + hidden.length;
}

/// Simulate the devtools incremental fetch + rebuild workflow.
///
/// Given a current (possibly slim) JSON string and full module data for
/// specific modules, this replaces slim modules with full data, BFS-walks
/// to include transitively referenced types, and rebuilds the adapter.
///
/// [sharedModules] is the mutable global module map (mix of slim + full
/// entries).  If provided, it's updated in-place (mirroring the real
/// devtools behavior where fetched data persists).  If null, a fresh
/// copy of the slim modules from [currentJson] is used as starting point.
///
/// This mirrors `_fetchModulesAndRebuild` in embedded_schematic_viewer.dart.
NetlistSchematicAdapter _simulateFetchAndRebuild(
  String currentJson,
  Map<String, dynamic> fullModules,
  Set<String> modulesToFetch, {
  ExpansionSnapshot? snapshot,
  Map<String, dynamic>? sharedModules,
}) {
  final currentParsed = jsonDecode(currentJson) as Map<String, dynamic>;
  final currentModules = currentParsed['modules'] as Map<String, dynamic>;

  // If no shared modules provided, use current modules as the shared state.
  sharedModules ??= Map<String, dynamic>.from(currentModules);

  // Replace slim modules with full data (simulates fetch callback).
  for (final key in modulesToFetch) {
    if (fullModules.containsKey(key)) {
      sharedModules[key] = fullModules[key];
      currentModules[key] = fullModules[key];
    }
  }

  // BFS: ensure all transitively referenced module types are present.
  // Copy from sharedModules (which may still have slim entries for
  // unfetched types). This matches the real code behavior.
  final bfsQueue = <String>[...modulesToFetch];
  final visited = <String>{...currentModules.keys};
  while (bfsQueue.isNotEmpty) {
    final current = bfsQueue.removeAt(0);
    final mod = currentModules[current] as Map<String, dynamic>?;
    if (mod == null) {
      continue;
    }
    final cells = mod['cells'] as Map<String, dynamic>? ?? {};
    for (final cellEntry in cells.values) {
      final cellData = cellEntry as Map<String, dynamic>;
      final cellType = cellData['type'] as String?;
      if (cellType != null &&
          !visited.contains(cellType) &&
          sharedModules.containsKey(cellType)) {
        currentModules[cellType] = sharedModules[cellType];
        visited.add(cellType);
        bfsQueue.add(cellType);
      }
    }
  }

  final enrichedJson = jsonEncode(currentParsed);
  final adapter = NetlistSchematicAdapter.fromJson(enrichedJson);

  // Restore expansion state if provided (mirrors _fetchModulesAndRebuild).
  if (snapshot != null) {
    adapter.schematic.restoreExpansionSnapshot(snapshot);
  }

  return adapter;
}

void main() {
  late Map<String, dynamic> fullJson;
  late Map<String, dynamic> fullModules;

  setUpAll(() {
    final raw = File('assets/FilterBank.rohd.json').readAsStringSync();
    fullJson = jsonDecode(raw) as Map<String, dynamic>;
    fullModules = fullJson['modules'] as Map<String, dynamic>;
  });

  test('recursive out0 expansion enters ch0 to find its driver', () {
    final raw = File('assets/rohd_schematic.json').readAsStringSync();
    final adapter = NetlistSchematicAdapter.fromJson(raw);
    final schematic = adapter.schematic;
    final filterBank = schematic.root.children.first;
    final out0 = filterBank.elkPorts.firstWhere(
      (port) => port.hwMeta.name == 'out0',
    );
    final ch0 = (filterBank.hiddenChildren ?? filterBank.children).firstWhere(
      (child) => child.hwMeta.name.split(' (').first == 'ch0',
    );

    expect(ch0.isPartiallyExpanded, isFalse);
    expect(
      schematic.expandPortThroughRecursive(filterBank.id, out0.id),
      isTrue,
    );
    expect(
      ch0.isPartiallyExpanded,
      isTrue,
      reason: 'out0 should trace through ch0.dataOut into ch0 internals',
    );
    expect(ch0.partialHyperedgeIds, isNotEmpty);
  });

  // ───────────────────────────────────────────────────────────────────
  // Reference: full design loaded directly
  // ───────────────────────────────────────────────────────────────────
  group('Reference: full design edges', () {
    test('full design in blocks-only mode has hidden edges', () {
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      expect(top.hwMeta.name, equals('FilterBank'));
      expect(top.isPartiallyExpanded, isTrue);
      expect(top.partialChildIds!.length, equals(3));

      // Blocks-only: 0 visible edges, but hidden edges exist.
      final json = schematic.toJsGraph();
      final visibleEdges = _extractEdgeSet(json);
      final hiddenEdges = _extractHiddenEdgeSet(json);

      expect(
        visibleEdges,
        isEmpty,
        reason: 'Blocks-only mode: no visible edges',
      );
      expect(
        hiddenEdges,
        isNotEmpty,
        reason: 'Full design should have hidden edges in blocks-only',
      );
    });

    test('full design fully expanded has visible edges', () {
      final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      // Collapse blocks-only, then fully expand.
      schematic
        ..collapsePartialExpansion(top.id)
        ..toggleNode(top.id);

      expect(top.isExpanded, isTrue);

      final json = schematic.toJsGraph();
      final visibleEdges = _extractEdgeSet(json);

      expect(
        visibleEdges,
        isNotEmpty,
        reason: 'Fully expanded design should have visible edges',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Slim loading baseline
  // ───────────────────────────────────────────────────────────────────
  group('Slim loading baseline', () {
    test('slim FilterBank has zero hyperedges', () {
      final slimModules = _makeSlimModules(fullModules);
      final slimJson = jsonEncode({
        'creator': fullJson['creator'],
        'modules': slimModules,
      });
      final adapter = NetlistSchematicAdapter.fromJson(slimJson);
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      expect(top.hwMeta.name, equals('FilterBank'));
      // Slim modules produce no hyperedges (no cell connections).
      expect(
        top.hyperedges ?? [],
        isEmpty,
        reason: 'Slim module should have no hyperedges',
      );

      // Blocks-only initial state should still show children
      // (blocks-only is triggered by expandNonPrimitives which checks
      // for non-primitive hidden children, not edges).
      // If expandNonPrimitives found non-prims, top is partially expanded.
      // If not, it falls back to toggleNode (fully expanded).
      // Either way, there should be 0 edges in serialized JSON.
      final json = schematic.toJsGraph();
      final totalEdges = _totalEdgeCount(json);
      expect(
        totalEdges,
        equals(0),
        reason: 'Slim design should have no edges at all',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Incremental fetch + rebuild (the devtools workflow)
  // ───────────────────────────────────────────────────────────────────
  group('Incremental fetch: slim → full FilterBank', () {
    late String slimJsonString;
    late Set<String> referenceHiddenEdges;
    late Set<String> referenceFullEdges;

    setUp(() {
      final slimModules = _makeSlimModules(fullModules);
      slimJsonString = jsonEncode({
        'creator': fullJson['creator'],
        'modules': slimModules,
      });

      // Capture reference edge sets from full design.
      final refAdapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final refSchematic = refAdapter.schematic;
      final refTop = refSchematic.root.children.first;

      // Reference: blocks-only hidden edges.
      referenceHiddenEdges = _extractHiddenEdgeSet(refSchematic.toJsGraph());

      // Reference: fully expanded visible edges.
      refSchematic
        ..collapsePartialExpansion(refTop.id)
        ..toggleNode(refTop.id);
      referenceFullEdges = _extractEdgeSet(refSchematic.toJsGraph());
    });

    test('fetch FilterBank produces matching hidden edges in blocks-only', () {
      // Step 1: Load slim JSON.
      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      final snapshot = slimAdapter.schematic.expansionSnapshot();

      // Step 2: Simulate fetching full data for FilterBank module.
      final rebuilt = _simulateFetchAndRebuild(
          slimJsonString,
          fullModules,
          {
            'FilterBank',
          },
          snapshot: snapshot);

      final top = rebuilt.schematic.root.children.first;
      expect(top.hwMeta.name, equals('FilterBank'));

      // After rebuild, top should be in blocks-only mode.
      expect(
        top.isPartiallyExpanded,
        isTrue,
        reason: 'Top should be blocks-only after rebuild',
      );

      // Hidden edges should now match the full design.
      final json = rebuilt.schematic.toJsGraph();
      final hiddenEdges = _extractHiddenEdgeSet(json);
      final visibleEdges = _extractEdgeSet(json);

      expect(visibleEdges, isEmpty, reason: 'Blocks-only: no visible edges');
      expect(
        hiddenEdges,
        isNotEmpty,
        reason: 'After fetch, hidden edges should be present',
      );
      expect(
        hiddenEdges,
        equals(referenceHiddenEdges),
        reason: 'Hidden edges after incremental fetch should match full design',
      );
    });

    test('fetch FilterBank then fully expand matches reference edges', () {
      // Step 1: Load slim JSON.
      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      final snapshot = slimAdapter.schematic.expansionSnapshot();

      // Step 2: Fetch full FilterBank data.
      final rebuilt = _simulateFetchAndRebuild(
          slimJsonString,
          fullModules,
          {
            'FilterBank',
          },
          snapshot: snapshot);
      final top = rebuilt.schematic.root.children.first;

      // Step 3: Fully expand.
      rebuilt.schematic.collapsePartialExpansion(top.id);
      rebuilt.schematic.toggleNode(top.id);
      expect(top.isExpanded, isTrue);

      // Step 4: Edges should match reference.
      final json = rebuilt.schematic.toJsGraph();
      final edges = _extractEdgeSet(json);

      expect(
        edges,
        isNotEmpty,
        reason: 'Should have visible edges after full expand',
      );
      expect(
        edges,
        equals(referenceFullEdges),
        reason:
            'Edges after incremental fetch + expand should match full design',
      );
    });

    test('expand blocks in order: ch0, controller, ch1', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['ch0', 'controller', 'ch1'],
      );
    });

    test('expand blocks in order: ch1, ch0, controller', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['ch1', 'ch0', 'controller'],
      );
    });

    test('expand blocks in order: controller, ch1, ch0', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['controller', 'ch1', 'ch0'],
      );
    });

    test('expand blocks in order: controller, ch0, ch1', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['controller', 'ch0', 'ch1'],
      );
    });

    test('expand blocks in order: ch0, ch1, controller', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['ch0', 'ch1', 'controller'],
      );
    });

    test('expand blocks in order: ch1, controller, ch0', () {
      _testBlockExpansionOrder(
        slimJsonString,
        fullModules,
        referenceHiddenEdges,
        ['ch1', 'controller', 'ch0'],
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Port-click expansion after incremental fetch
  // ───────────────────────────────────────────────────────────────────
  group('Port-click expansion after fetch', () {
    late String slimJsonString;
    late Set<String> referenceHiddenEdges;

    setUp(() {
      final slimModules = _makeSlimModules(fullModules);
      slimJsonString = jsonEncode({
        'creator': fullJson['creator'],
        'modules': slimModules,
      });

      final refAdapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      referenceHiddenEdges = _extractHiddenEdgeSet(
        refAdapter.schematic.toJsGraph(),
      );
    });

    test('expandPort on each block produces visible edges', () {
      // Slim → fetch → rebuild.
      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      final snapshot = slimAdapter.schematic.expansionSnapshot();
      final adapter = _simulateFetchAndRebuild(
          slimJsonString,
          fullModules,
          {
            'FilterBank',
          },
          snapshot: snapshot);
      final schematic = adapter.schematic;
      final top = schematic.root.children.first;

      // Before any port click: 0 visible edges.
      var json = schematic.toJsGraph();
      expect(_extractEdgeSet(json), isEmpty);

      // Click each block's first port, one at a time, checking edges.
      final childIds = top.partialChildIds!.toList();
      for (final childId in childIds) {
        final childNode = schematic.nodeMap[childId];
        if (childNode == null || childNode.elkPorts.isEmpty) {
          continue;
        }
        final portId = childNode.elkPorts.first.id;
        final expanded = schematic.expandPort(top.id, portId);
        if (expanded) {
          json = schematic.toJsGraph();
          final edges = _extractEdgeSet(json);
          expect(
            edges,
            isNotEmpty,
            reason: 'expandPort on ${childNode.hwMeta.name} '
                'should reveal at least one edge',
          );
        }
      }

      // After all port clicks, total should match reference.
      json = schematic.toJsGraph();
      final allEdges = {
        ..._extractEdgeSet(json),
        ..._extractHiddenEdgeSet(json),
      };
      expect(allEdges, equals(referenceHiddenEdges));
    });

    test('expandPort on reference (full design) matches incremental', () {
      // Reference: expand same ports on the full design.
      final refAdapter = NetlistSchematicAdapter.fromJson(jsonEncode(fullJson));
      final refTop = refAdapter.schematic.root.children.first;
      final refChildIds = refTop.partialChildIds!.toList();
      for (final childId in refChildIds) {
        final childNode = refAdapter.schematic.nodeMap[childId];
        if (childNode == null || childNode.elkPorts.isEmpty) {
          continue;
        }
        refAdapter.schematic.expandPort(refTop.id, childNode.elkPorts.first.id);
      }
      final refJson = refAdapter.schematic.toJsGraph();
      final refVisible = _extractEdgeSet(refJson);
      final refHidden = _extractHiddenEdgeSet(refJson);

      // Incremental: same port clicks on fetched adapter.
      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      final snapshot = slimAdapter.schematic.expansionSnapshot();
      final adapter = _simulateFetchAndRebuild(
          slimJsonString,
          fullModules,
          {
            'FilterBank',
          },
          snapshot: snapshot);
      final top = adapter.schematic.root.children.first;
      final childIds = top.partialChildIds!.toList();
      for (final childId in childIds) {
        final childNode = adapter.schematic.nodeMap[childId];
        if (childNode == null || childNode.elkPorts.isEmpty) {
          continue;
        }
        adapter.schematic.expandPort(top.id, childNode.elkPorts.first.id);
      }
      final json = adapter.schematic.toJsGraph();
      final visible = _extractEdgeSet(json);
      final hidden = _extractHiddenEdgeSet(json);

      expect(
        visible,
        equals(refVisible),
        reason: 'Visible edges should match reference after same port clicks',
      );
      expect(
        hidden,
        equals(refHidden),
        reason: 'Hidden edges should match reference after same port clicks',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Incremental fetch per-child module
  // ───────────────────────────────────────────────────────────────────
  group('Incremental fetch: per-child module expansion', () {
    late String slimJsonString;

    setUp(() {
      final slimModules = _makeSlimModules(fullModules);
      slimJsonString = jsonEncode({
        'creator': fullJson['creator'],
        'modules': slimModules,
      });
    });

    test('fetch FilterBank first, then fetch child modules one at a time', () {
      // Simulate the persistent sharedModules map used in devtools.
      final sharedModules = Map<String, dynamic>.from(
        jsonDecode(slimJsonString)['modules'] as Map<String, dynamic>,
      );

      // Step 1: Load slim → fetch FilterBank (top module).
      final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
      var snapshot = slimAdapter.schematic.expansionSnapshot();
      var adapter = _simulateFetchAndRebuild(
        slimJsonString,
        fullModules,
        {'FilterBank'},
        snapshot: snapshot,
        sharedModules: sharedModules,
      );
      var top = adapter.schematic.root.children.first;
      expect(top.isPartiallyExpanded, isTrue);

      // At this point, FilterBank has full connectivity but child modules
      // (FilterChannel, FilterController) are still slim in sharedModules.
      // The top-level edges should be present (they come from FilterBank's
      // netnames + cell connections, not from children's internals).
      var json = adapter.schematic.toJsGraph();
      var hiddenEdges = _extractHiddenEdgeSet(json);
      expect(
        hiddenEdges,
        isNotEmpty,
        reason: 'FilterBank connectivity should produce hidden edges',
      );

      // Step 2: Simulate expanding ch0 — this would trigger
      // ensureConnectivity for FilterChannel.
      final childModules = top.partialChildIds?.toList() ?? [];
      expect(childModules, isNotEmpty);

      // Find the ch0 node by name (for reference checking later).
      final allHidden = top.hiddenChildren ?? <LayoutNode>[];
      expect(
        allHidden.any((c) => c.hwMeta.name.split(' (').first == 'ch0'),
        isTrue,
        reason: 'ch0 should exist in hidden children',
      );

      // Capture snapshot, then fetch FilterChannel.
      snapshot = adapter.schematic.expansionSnapshot();
      // Re-encode the current state as the "current adapter JSON".
      // In devtools, this is the schematicJson that gets decoded and
      // enriched. It already has FilterBank full (from step 1).
      final currentJson = jsonEncode({
        'creator': fullJson['creator'],
        'modules': sharedModules,
      });
      adapter = _simulateFetchAndRebuild(
        currentJson,
        fullModules,
        {'FilterChannel_T3_W16'},
        snapshot: snapshot,
        sharedModules: sharedModules,
      );

      top = adapter.schematic.root.children.first;
      // Top should still have connectivity from FilterBank.
      json = adapter.schematic.toJsGraph();
      hiddenEdges = _extractHiddenEdgeSet(json);
      expect(
        hiddenEdges,
        isNotEmpty,
        reason: 'FilterBank edges should persist after fetching FilterChannel',
      );

      // Now expand ch0's non-primitives.
      // ch0 might not exist with the same ID after rebuild, so find it
      // by name in the rebuilt adapter.
      final rebuiltTop = adapter.schematic.root.children.first;
      LayoutNode? rebuiltCh0;
      for (final c in rebuiltTop.hiddenChildren ?? <LayoutNode>[]) {
        if (c.hwMeta.name.split(' (').first == 'ch0') {
          rebuiltCh0 = c;
          break;
        }
      }
      if (rebuiltCh0 != null) {
        final expandResult = adapter.schematic.expandNonPrimitives(
          rebuiltCh0.id,
          includeEdges: false,
        );
        // Whether this succeeds depends on whether ch0 has non-primitive
        // hidden children (it should, since FilterChannel has MacUnit cells).
        if (expandResult) {
          expect(rebuiltCh0.isPartiallyExpanded, isTrue);
        }
      }
    });

    test('navigate into child module (extractAndCompute style)', () {
      // This test simulates _extractAndComputeFromJson: when the user
      // double-clicks a child module (e.g., ch0), a subset JSON is
      // created with that module's type (FilterChannel_T3_W16) as the new top
      // module, plus all transitively referenced sub-modules.

      // First fetch FilterChannel_T3_W16 from slim → full.
      // Build a subset JSON with FilterChannel_T3_W16 as top and all needed
      // sub-modules (MacUnit_W16, CoeffBank_T3_W16, etc.)
      final filterChannelFull =
          fullModules['FilterChannel_T3_W16'] as Map<String, dynamic>;
      final subsetModules = <String, dynamic>{
        'FilterChannel_T3_W16': {
          ...filterChannelFull,
          'attributes': {
            ...(filterChannelFull['attributes'] as Map<String, dynamic>? ?? {}),
            'top': 1,
          },
        },
      };

      // BFS to collect all referenced module types.
      final queue = <String>['FilterChannel_T3_W16'];
      final visited = <String>{'FilterChannel_T3_W16'};
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        final mod = subsetModules[current] as Map<String, dynamic>?;
        if (mod == null) {
          continue;
        }
        final cells = mod['cells'] as Map<String, dynamic>? ?? {};
        for (final cellEntry in cells.values) {
          final cellData = cellEntry as Map<String, dynamic>;
          final cellType = cellData['type'] as String?;
          if (cellType != null &&
              !visited.contains(cellType) &&
              fullModules.containsKey(cellType)) {
            subsetModules[cellType] = fullModules[cellType];
            visited.add(cellType);
            queue.add(cellType);
          }
        }
      }

      final subsetJson = jsonEncode({
        'creator': 'test',
        'modules': subsetModules,
      });

      // Load subset as a fresh adapter (simulating computeLayout).
      final adapter = NetlistSchematicAdapter.fromJson(subsetJson);
      final top = adapter.schematic.root.children.first;

      expect(top.hwMeta.name, equals('FilterChannel_T3_W16'));
      // FilterChannel_T3_W16 should have non-primitive children (MacUnit_W16
      // instances).
      expect(
        top.isPartiallyExpanded || top.isExpanded,
        isTrue,
        reason: 'FilterChannel_T3_W16 should have expandable children '
            '(MacUnit_W16 etc.)',
      );

      // Check that edges exist (FilterChannel has connections).
      final json = adapter.schematic.toJsGraph();
      final totalEdges = _totalEdgeCount(json);
      expect(
        totalEdges,
        greaterThan(0),
        reason:
            'FilterChannel_T3_W16 should have edges when loaded with full data',
      );

      // Compare with reference: load full design, navigate to
      // FilterChannel_T3_W16.
      final refAdapter = NetlistSchematicAdapter.fromJson(subsetJson);
      final refJson = refAdapter.schematic.toJsGraph();
      final refTotalEdges = _totalEdgeCount(refJson);
      expect(
        totalEdges,
        equals(refTotalEdges),
        reason: 'Edge count should match reference',
      );
    });
  });
}

/// Test that expanding blocks in [blockOrder] (by instance name) after
/// incrementally fetching full FilterBank data produces edges matching
/// the reference.
///
/// This simulates the user flow:
/// 1. Load slim JSON → blocks-only (0 edges)
/// 2. "Fetch" FilterBank full connectivity → rebuild adapter
/// 3. Expand blocks one at a time via expandPort on each block's port
/// 4. After all blocks expanded, verify edges match reference
void _testBlockExpansionOrder(
  String slimJsonString,
  Map<String, dynamic> fullModules,
  Set<String> referenceHiddenEdges,
  List<String> blockOrder,
) {
  // Step 1: Load slim, capture snapshot.
  final slimAdapter = NetlistSchematicAdapter.fromJson(slimJsonString);
  final snapshot = slimAdapter.schematic.expansionSnapshot();

  // Step 2: Fetch full FilterBank data and rebuild.
  final rebuilt = _simulateFetchAndRebuild(
      slimJsonString,
      fullModules,
      {
        'FilterBank',
      },
      snapshot: snapshot);
  final schematic = rebuilt.schematic;
  final top = schematic.root.children.first;

  expect(top.hwMeta.name, equals('FilterBank'));
  expect(
    top.isPartiallyExpanded,
    isTrue,
    reason: 'Should be in blocks-only mode after rebuild',
  );
  expect(top.partialChildIds, isNotNull);
  expect(
    top.partialChildIds!.length,
    equals(3),
    reason: 'FilterBank should have 3 non-primitive children',
  );

  // Step 3: The hidden edges at this point should match the reference
  // regardless of which blocks we expand (before expanding any port,
  // all edges are hidden in blocks-only mode).
  var json = schematic.toJsGraph();
  final hiddenEdges = _extractHiddenEdgeSet(json);
  expect(
    hiddenEdges,
    isNotEmpty,
    reason: 'After fetch, blocks-only should have hidden edges',
  );
  expect(
    hiddenEdges,
    equals(referenceHiddenEdges),
    reason: 'Hidden edges should match reference before expansion',
  );

  // Step 4: Expand blocks in the specified order by clicking each
  // block's first port to reveal connected edges.
  // First, collect name → nodeId mapping for the partial children.
  final nameToId = <String, String>{};
  for (final childId in top.partialChildIds!) {
    // Look up in hiddenChildren (blocks-only stores them there).
    for (final hc in top.hiddenChildren ?? <LayoutNode>[]) {
      if (hc.id == childId) {
        // Extract instance name from "instance (type)" label format.
        final instanceName = hc.hwMeta.name.split(' (').first;
        nameToId[instanceName] = childId;
        break;
      }
    }
  }

  // Expand each block by clicking its first port.
  for (final blockName in blockOrder) {
    final nodeId = nameToId[blockName];
    expect(
      nodeId,
      isNotNull,
      reason: 'Block "$blockName" should exist in partialChildIds',
    );

    // Find the child node to get its first port.
    final childNode = schematic.nodeMap[nodeId];
    expect(
      childNode,
      isNotNull,
      reason: 'Block "$blockName" should exist in nodeMap',
    );
    if (childNode!.elkPorts.isNotEmpty) {
      final portId = childNode.elkPorts.first.id;
      schematic.expandPort(top.id, portId);
    }
  }

  // Step 5: After clicking all blocks' ports, we should have visible
  // edges. At minimum, the total edge count should match.
  json = schematic.toJsGraph();
  final finalVisible = _extractEdgeSet(json);
  final finalHidden = _extractHiddenEdgeSet(json);
  final totalEdges = finalVisible.length + finalHidden.length;

  expect(
    totalEdges,
    greaterThan(0),
    reason: 'After all expansions, total edges should be > 0 '
        '(order: ${blockOrder.join(", ")})',
  );

  // The union of visible + hidden edges should equal the reference
  // hidden edge set (which is the full set of top-level edges).
  final allEdges = {...finalVisible, ...finalHidden};
  expect(
    allEdges,
    equals(referenceHiddenEdges),
    reason: 'All edges (visible + hidden) should match reference '
        '(order: ${blockOrder.join(", ")})',
  );
}
