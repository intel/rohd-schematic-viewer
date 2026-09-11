// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_graph.dart
// SchematicGraph class that holds the complete ELK graph in Dart.
// This is the master data structure for schematic layout computation.
//
// 2026 February
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

import 'package:rohd_schematic_viewer/src/schematic/operator_shapes.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

/// Snapshot of the full expansion state of a schematic graph.
///
/// Captures both fully-expanded node IDs and partially-expanded nodes
/// (blocks mode) with their visible child/edge sets, enabling exact
/// state restoration across adapter rebuilds.
class ExpansionSnapshot {
  /// IDs of nodes that are fully expanded (all children visible).
  final Set<String> fullyExpanded;

  /// Per-node partial expansion state: node ID → visible child/edge IDs.
  final Map<String, ({Set<String> childIds, Set<String> edgeIds})> partials;

  /// Creates an expansion snapshot.
  const ExpansionSnapshot({
    required this.fullyExpanded,
    required this.partials,
  });

  @override
  String toString() => 'ExpansionSnapshot('
      'fullyExpanded=$fullyExpanded, '
      'partials=${partials.keys})';
}

/// Schematic-specific graph that parallels the hierarchy API.
///
/// This holds ELK-ready data structures that can be:
/// 1. Serialized to JSON for ELK layout
/// 2. Passed directly to Dart ELK layout engine
///
/// The graph maintains both visible and hidden (collapsed) nodes/edges,
/// supporting toggle/expand operations without re-parsing.
class SchematicGraph {
  /// Root node of the schematic graph.
  final LayoutNode root;

  /// Map for fast lookup: node ID → LayoutNode.
  ///
  /// Keys are address-based strings (e.g. "0.1.2") derived from the node's
  /// position in the build-time tree.  The root wrapper uses the key "r".
  final Map<String, LayoutNode> nodeMap;

  /// Reference to the parallel hierarchy service (optional).
  final HierarchyService? hierarchy;

  /// Constructor for `SchematicGraph`.
  SchematicGraph({
    required this.root,
    Map<String, LayoutNode>? nodeMap,
    this.hierarchy,
  }) : nodeMap = nodeMap ?? {};

  /// Get a node by ID (O(1) hash lookup).
  LayoutNode? getNode(String id) => nodeMap[id];

  /// Look up a node by its `OccurrenceAddress`.
  ///
  /// Address `[]` maps to the root wrapper ("r").
  /// Address ``0`` maps to the top module ("0").
  /// Address ``0, 1, 2`` maps to node "0.1.2".
  LayoutNode? occurrenceByAddress(OccurrenceAddress addr) =>
      nodeMap[addr.path.isEmpty ? 'r' : addr.path.join('.')];

  /// Get all currently expanded node IDs (derived from tree state).
  Set<String> get expandedNodeIds {
    final ids = <String>{};
    void collect(LayoutNode n) {
      if (n.isExpanded) {
        ids.add(n.id);
      }
      n.children.forEach(collect);
      if (n.hiddenChildren != null) {
        n.hiddenChildren!.forEach(collect);
      }
    }

    collect(root);
    return ids;
  }

  /// Capture a complete expansion snapshot including both fully-expanded
  /// nodes and partially-expanded (blocks-mode) nodes with their visible
  /// child/edge sets.
  ///
  /// Use `restoreExpansionSnapshot` on a fresh graph to replay this state.
  ExpansionSnapshot expansionSnapshot() {
    final fullyExpanded = <String>{};
    final partials = <String, ({Set<String> childIds, Set<String> edgeIds})>{};

    void collect(LayoutNode n) {
      if (n.isExpanded) {
        fullyExpanded.add(n.id);
      } else if (n.isPartiallyExpanded) {
        partials[n.id] = (
          childIds: Set<String>.from(n.partialChildIds!),
          edgeIds: Set<String>.from(n.partialHyperedgeIds ?? {}),
        );
      }
      n.children.forEach(collect);
      if (n.hiddenChildren != null) {
        n.hiddenChildren!.forEach(collect);
      }
    }

    collect(root);
    return ExpansionSnapshot(fullyExpanded: fullyExpanded, partials: partials);
  }

  /// Restore a previously captured `ExpansionSnapshot` on this graph.
  ///
  /// Reconciles the current state (which may already have the top module
  /// partially expanded from the adapter builder) to match the snapshot.
  void restoreExpansionSnapshot(ExpansionSnapshot snapshot) {
    // First, capture what the fresh adapter already has.
    final freshExpanded = expandedNodeIds;
    final freshPartials = <String, Set<String>>{};
    void collectFreshPartials(LayoutNode n) {
      if (n.isPartiallyExpanded) {
        freshPartials[n.id] = Set<String>.from(n.partialChildIds!);
      }
      n.children.forEach(collectFreshPartials);
      if (n.hiddenChildren != null) {
        n.hiddenChildren!.forEach(collectFreshPartials);
      }
    }

    collectFreshPartials(root);

    // Collapse fully-expanded nodes that shouldn't be.
    for (final id in freshExpanded) {
      if (!snapshot.fullyExpanded.contains(id) &&
          !snapshot.partials.containsKey(id)) {
        toggleNode(id);
      }
    }

    // Expand nodes that should be fully expanded but aren't.
    for (final id in snapshot.fullyExpanded) {
      if (!freshExpanded.contains(id)) {
        toggleNode(id);
      }
    }

    // Restore partial expansions.
    for (final entry in snapshot.partials.entries) {
      final node = nodeMap[entry.key];
      if (node == null) {
        continue;
      }
      // If the node is already partially expanded from the fresh adapter,
      // clear it and reapply the snapshot's partial set.
      node
        ..partialChildIds = entry.value.childIds
        ..partialHyperedgeIds = entry.value.edgeIds;
    }

    // Clear any fresh partial expansions not in the snapshot.
    for (final id in freshPartials.keys) {
      if (!snapshot.partials.containsKey(id) &&
          !snapshot.fullyExpanded.contains(id)) {
        nodeMap[id]?.partialChildIds = null;
        nodeMap[id]?.partialHyperedgeIds = null;
      }
    }
  }

  /// Check if a node is currently expanded.
  bool isExpanded(String nodeId) => nodeMap[nodeId]?.isExpanded ?? false;

  /// Collect all hyperedges from the entire node tree.
  List<LayoutHyperedge> get hyperedges {
    final all = <LayoutHyperedge>[];
    void collect(LayoutNode node) {
      if (node.hyperedges != null) {
        all.addAll(node.hyperedges!);
      }
      node.children.forEach(collect);
      if (node.hiddenChildren != null) {
        node.hiddenChildren!.forEach(collect);
      }
    }

    collect(root);
    return all;
  }

  /// Toggle a node's expansion state.
  ///
  /// Returns true if the toggle was successful.
  bool toggleNode(String nodeId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    if (node.isExpanded) {
      // Collapse
      node.toggle();
    } else if (node.isExpandable) {
      // Expand
      node.toggle();
    } else {
      return false; // No children to toggle
    }

    return true;
  }

  /// Recursively toggle a node and all its descendant submodules.
  ///
  /// When expanding: toggles the node open, then recursively expands
  /// every expandable child all the way down the hierarchy.
  /// When collapsing: recursively collapses all expanded descendants
  /// first, then collapses this node so re-expanding starts fresh.
  ///
  /// When the node is partially expanded (blocks-only mode), promotes
  /// it to fully expanded and recursively expands all descendants —
  /// the user intent of SHIFT+click is "open everything".
  ///
  /// Returns `true` if the initial toggle was successful.
  bool toggleNodeRecursive(String nodeId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    final wasPartiallyExpanded = node.isPartiallyExpanded;

    if (wasPartiallyExpanded) {
      // Partially expanded (blocks-only) — promote to full expansion.
      // Clear partial state, then toggle open and expand descendants.
      node
        ..partialChildIds = null
        ..partialHyperedgeIds = null;
      if (!toggleNode(nodeId)) {
        return false;
      }
      _expandDescendants(node);
    } else if (node.isExpandable) {
      // Expanding: toggle open, then expand all descendants.
      if (!toggleNode(nodeId)) {
        return false;
      }
      _expandDescendants(node);
    } else if (node.isExpanded) {
      // Collapsing: first collapse all expanded descendants, then this.
      _collapseDescendants(node);
      toggleNode(nodeId);
    } else {
      return false;
    }
    return true;
  }

  /// Recursively expand non-primitive children of a node and their
  /// descendants in blocks-only mode (no edges).
  ///
  /// First performs `expandNonPrimitives` on `nodeId`, then for each
  /// revealed non-primitive child, recursively does the same.
  ///
  /// Before operating on each child, any prior expansion state (full
  /// expand or partial/port expand) is collapsed so that blocks-only
  /// mode starts from a clean slate.
  ///
  /// Returns `true` if any new children were revealed.
  bool expandNonPrimitivesRecursive(String nodeId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    // If the node is currently expanded or partially expanded, collapse
    // it first so expandNonPrimitives can work on its hiddenChildren.
    _ensureCollapsed(node);

    if (!expandNonPrimitives(nodeId, includeEdges: false)) {
      return false;
    }

    // The partial children are the non-primitive children just revealed.
    final revealedIds = node.partialChildIds;
    if (revealedIds == null) {
      return true;
    }

    revealedIds.toList().forEach(expandNonPrimitivesRecursive);
    return true;
  }

  /// Recursively convert a fully expanded node to blocks-only mode,
  /// then do the same for every revealed non-primitive descendant.
  ///
  /// Returns `true` if the initial conversion happened.
  bool convertToBlocksOnlyRecursive(String nodeId) {
    if (!convertToBlocksOnly(nodeId)) {
      return false;
    }

    final node = nodeMap[nodeId];
    if (node == null) {
      return true;
    }

    final revealedIds = node.partialChildIds;
    if (revealedIds == null) {
      return true;
    }

    revealedIds.toList().forEach(expandNonPrimitivesRecursive);
    return true;
  }

  /// Helper: ensure `node` is in collapsed state (has hiddenChildren,
  /// not children).  If expanded or partially expanded, collapse first.
  void _ensureCollapsed(LayoutNode node) {
    if (node.isExpanded) {
      _collapseDescendants(node);
      node.toggle();
    } else if (node.isPartiallyExpanded) {
      if (node.hiddenChildren != null) {
        LayoutNode.clearDescendantMarks(node.hiddenChildren!);
      }
      LayoutNode.clearDescendantMarks(node.children);
      node
        ..partialChildIds = null
        ..partialHyperedgeIds = null;
    }
  }

  /// Helper: recursively expand all expandable descendants of `node`.
  void _expandDescendants(LayoutNode node) {
    for (final child in node.children) {
      if (child.isExpandable) {
        child.toggle();
        _expandDescendants(child);
      } else if (child.isExpanded) {
        _expandDescendants(child);
      }
    }
  }

  /// Helper: recursively collapse all expanded/partial descendants so
  /// a subsequent re-expand starts with every child in its collapsed
  /// state.
  void _collapseDescendants(LayoutNode node) {
    for (final child in node.children) {
      if (child.isExpanded) {
        _collapseDescendants(child);
        child.toggle();
      } else if (child.isPartiallyExpanded) {
        if (child.hiddenChildren != null) {
          LayoutNode.clearDescendantMarks(child.hiddenChildren!);
        }
        LayoutNode.clearDescendantMarks(child.children);
        child
          ..partialChildIds = null
          ..partialHyperedgeIds = null;
      }
    }
  }

  /// Incrementally expand a single port of a collapsed child module.
  ///
  /// Reveals only the internal edges connected to `portId` and the
  /// submodules at the other end of those edges. This is a partial
  /// expansion — the node is not fully toggled, just the
  /// port's immediate fan-in/fan-out becomes visible.
  ///
  /// Returns `true` if new children/edges were revealed.
  bool expandPort(String nodeId, String portId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    // Node must have hidden children for partial expansion to make sense.
    if (node.hiddenChildren == null || node.hiddenChildren!.isEmpty) {
      return false;
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      return false;
    }

    // Use the port→hyperedge index for O(1) lookup.
    // Convert string portId to local port index.
    // The port might belong to this node or one of its children.
    final resolved = node.resolvePortId(portId);
    if (resolved == null) {
      return false;
    }
    final resolvedNodeId = resolved.$1;
    final portIdx = resolved.$2;
    final idx = node.portHyperedgeIndex;
    List<LayoutHyperedge>? matching;
    if (resolvedNodeId == node.id) {
      matching = idx[portIdx];
    } else {
      matching = _findHyperedgesForPort(node, resolvedNodeId, portIdx);
    }
    if (matching == null || matching.isEmpty) {
      return false;
    }

    final matchingHyperedgeIds = <String>{};
    final connectedChildIds = <String>{};

    // When the clicked port belongs to a specific child instance, only
    // reveal that child plus children on the OTHER side of the hyperedge.
    // Without this, clicking one TagManager's "count" port would reveal
    // ALL sibling TagManager instances connected to the same bus.
    final clickedIsChild = resolvedNodeId != node.id;

    for (final h in matching) {
      matchingHyperedgeIds.add(h.id);
      if (clickedIsChild) {
        // Determine which side the clicked child is on.
        final clickedInSources = h.sources.any((s) => s.$1 == resolvedNodeId);
        final clickedInTargets = h.targets.any((t) => t.$1 == resolvedNodeId);
        // Always include the clicked child itself.
        connectedChildIds.add(resolvedNodeId);
        // Include children on the opposite side (and the parent port side).
        if (clickedInSources) {
          for (final (nId, _) in h.targets) {
            if (nId != node.id) {
              connectedChildIds.add(nId);
            }
          }
        }
        if (clickedInTargets) {
          for (final (nId, _) in h.sources) {
            if (nId != node.id) {
              connectedChildIds.add(nId);
            }
          }
        }
      } else {
        // Clicked port is on the parent node itself — reveal all children.
        for (final (nId, _) in h.sources) {
          if (nId != node.id) {
            connectedChildIds.add(nId);
          }
        }
        for (final (nId, _) in h.targets) {
          if (nId != node.id) {
            connectedChildIds.add(nId);
          }
        }
      }
    }

    if (connectedChildIds.isEmpty && matchingHyperedgeIds.isEmpty) {
      return false;
    }

    // Check if everything is already visible (idempotent click)
    final existingChildren = node.partialChildIds ?? {};
    final existingEdges = node.partialHyperedgeIds ?? {};
    if (existingChildren.containsAll(connectedChildIds) &&
        existingEdges.containsAll(matchingHyperedgeIds)) {
      return false; // Already visible — no change
    }

    // Additive: merge into existing partial sets.
    final mergedChildren = {...existingChildren, ...connectedChildIds};
    final mergedEdges = {...existingEdges, ...matchingHyperedgeIds};

    // Also include any inter-child hyperedge that shares at least one
    // exact (nodeId, portIndex) endpoint with the directly matched
    // hyperedges from *this* click.  This ensures we only pull in edges
    // on the same signal network — not unrelated internal signals whose
    // children happen to all be visible (e.g. in blocks-only mode).
    //
    // Collect the child-side endpoints of the currently matched edges.
    final matchedEndpoints = <(String, int)>{};
    for (final h in matching) {
      for (final s in h.sources) {
        if (s.$1 != node.id) {
          matchedEndpoints.add(s);
        }
      }
      for (final t in h.targets) {
        if (t.$1 != node.id) {
          matchedEndpoints.add(t);
        }
      }
    }

    for (final h in hyperedges) {
      if (mergedEdges.contains(h.id)) {
        continue;
      }
      final allChildEndpoints =
          h.sources.every((s) => mergedChildren.contains(s.$1)) &&
              h.targets.every((t) => mergedChildren.contains(t.$1));
      if (!allChildEndpoints) {
        continue;
      }
      // Only add if this edge shares at least one (nodeId, portIndex)
      // with the directly matched hyperedges from this click.
      final sharesEndpoint = h.sources.any(matchedEndpoints.contains) ||
          h.targets.any(matchedEndpoints.contains);
      if (!sharesEndpoint) {
        continue;
      }
      mergedEdges.add(h.id);
    }

    node
      ..partialChildIds = mergedChildren
      ..partialHyperedgeIds = mergedEdges;

    return true;
  }

  /// Operator names considered "trivial" for pass-through traversal.
  ///
  /// These gates simply relay, invert, or reshape a signal and carry
  /// little standalone semantic meaning.  When the user asks for
  /// pass-through expansion the traversal continues *through* any
  /// hidden child whose `hwMeta.name` is in this set and whose
  /// `hwMeta.cls == 'Operator'`.
  static const _trivialOperators = <String>{
    'BUF',
    'NOT',
    'SLICE',
    'CONCAT',
    'STRUCT_PACK',
    'STRUCT_UNPACK',
  };

  /// Find hyperedges in `parentNode` that reference (childNodeId, portIndex).
  ///
  /// Used when the BFS queue contains a child port that isn't in the parent
  /// node's `portHyperedgeIndex` (which is keyed by ports on the parent
  /// itself).  Falls back to a linear scan of the parent's hyperedges.
  static List<LayoutHyperedge> _findHyperedgesForPort(
    LayoutNode parentNode,
    String childNodeId,
    int portIndex,
  ) {
    final result = <LayoutHyperedge>[];
    final hes = parentNode.hyperedges;
    if (hes == null) {
      return result;
    }
    for (final h in hes) {
      var found = false;
      for (final (nId, pIdx) in h.sources) {
        if (nId == childNodeId && pIdx == portIndex) {
          found = true;
          break;
        }
      }
      if (!found) {
        for (final (nId, pIdx) in h.targets) {
          if (nId == childNodeId && pIdx == portIndex) {
            found = true;
            break;
          }
        }
      }
      if (found) {
        result.add(h);
      }
    }
    return result;
  }

  /// Whether `child` is a trivial pass-through gate.
  ///
  /// A trivial gate is a leaf-level operator (no sub-children) whose
  /// operator name is in `_trivialOperators`.
  static bool _isTrivialGate(LayoutNode child) =>
      child.hwMeta.cls == 'Operator' &&
      _trivialOperators.contains(child.hwMeta.name) &&
      child.children.isEmpty &&
      (child.hiddenChildren == null || child.hiddenChildren!.isEmpty);

  /// Collect the child IDs and hyperedge IDs that would be revealed/removed
  /// by a pass-through expansion/collapse on `portId` in `node`.
  ///
  /// Performs a BFS traversal through trivial gates, identical logic used by
  /// both `expandPortThrough` and `collapsePortThrough`. This ensures both
  /// operations traverse the exact same path and affect the same gates/edges.
  ///
  /// Returns a tuple of (childIds, hyperedgeIds) discovered on this port path.
  static (Set<String>, Set<String>) _collectPortThroughGatesAndEdges(
    LayoutNode node,
    String portId,
  ) {
    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      return (<String>{}, <String>{});
    }

    // Convert string portId to local port index.
    // The port might belong to this node or one of its children.
    final resolved = node.resolvePortId(portId);
    if (resolved == null) {
      return (<String>{}, <String>{});
    }
    final startNodeId = resolved.$1;
    final startPortIdx = resolved.$2;

    // Build a quick lookup: childId → LayoutNode (both hidden and visible).
    final allChildMap = <String, LayoutNode>{};
    for (final child in node.children) {
      allChildMap[child.id] = child;
    }
    if (node.hiddenChildren != null) {
      for (final child in node.hiddenChildren!) {
        allChildMap[child.id] = child;
      }
    }

    // BFS to collect gates and edges on this port path.
    // Queue contains (nodeId, portIndex) pairs — the nodeId is needed
    // because the portIndex is local to each child node.
    final portQueue = Queue<(String, int)>()..add((startNodeId, startPortIdx));
    final visitedPorts = <(String, int)>{};
    final collectedChildIds = <String>{};
    final collectedHyperedgeIds = <String>{};

    final idx = node.portHyperedgeIndex;

    while (portQueue.isNotEmpty) {
      final current = portQueue.removeFirst();
      if (!visitedPorts.add(current)) {
        continue;
      }

      // Only look up in the parent node's index when the port belongs
      // to the parent node itself.
      final currentNodeId = current.$1;
      final currentPortIdx = current.$2;

      // For ports on the parent node, look up in parent's index.
      // For ports on child nodes, we need to find hyperedges that
      // reference that child's port.
      List<LayoutHyperedge>? matching;
      if (currentNodeId == node.id) {
        matching = idx[currentPortIdx];
      } else {
        // For child ports, scan the parent's hyperedges for references
        // to (childId, portIndex).
        matching = <LayoutHyperedge>[];
        final hes = node.hyperedges;
        if (hes != null) {
          for (final h in hes) {
            for (final (nId, pIdx) in h.sources) {
              if (nId == currentNodeId && pIdx == currentPortIdx) {
                matching.add(h);
                break;
              }
            }
            for (final (nId, pIdx) in h.targets) {
              if (nId == currentNodeId && pIdx == currentPortIdx) {
                if (!matching.contains(h)) {
                  matching.add(h);
                }
                break;
              }
            }
          }
        }
      }

      if (matching == null || matching.isEmpty) {
        continue;
      }

      for (final h in matching) {
        collectedHyperedgeIds.add(h.id);

        // Collect child endpoints (skip the parent node itself).
        for (final (nId, pIdx) in h.sources) {
          if (nId == node.id) {
            continue;
          }
          collectedChildIds.add(nId);
          final child = allChildMap[nId];
          if (child != null && _isTrivialGate(child)) {
            // Guard: if this gate appears as a SOURCE at exactly the port
            // we're currently processing, we arrived FROM this hyperedge
            // via this gate's output.  Following its exit ports would go
            // backward (e.g. starting at BUF output → traversing to BUF
            // input).  Skip the enqueue in this case only.
            if (nId == currentNodeId && pIdx == currentPortIdx) {
              continue;
            }
            portQueue.addAll(
              _exitPortIndices(child, pIdx).map((i) => (nId, i)),
            );
          }
        }
        for (final (nId, pIdx) in h.targets) {
          if (nId == node.id) {
            continue;
          }
          collectedChildIds.add(nId);
          final child = allChildMap[nId];
          if (child != null && _isTrivialGate(child)) {
            // No guard here: appearing as a TARGET means this is the gate's
            // entry side (e.g. CONCAT input or BUF input driven by a wire).
            // Following its exit ports is the correct forward direction.
            portQueue.addAll(
              _exitPortIndices(child, pIdx).map((i) => (nId, i)),
            );
          }
        }
      }
    }

    return (collectedChildIds, collectedHyperedgeIds);
  }

  /// Return the port indices on the *opposite* side of a child node from
  /// `entryPortIndex`.
  ///
  /// If `entryPortIndex` is an INPUT port, returns all OUTPUT port indices,
  /// and vice-versa.  For INOUT ports, returns all other port indices.
  /// This is used by `expandPortThrough` to continue traversal through
  /// trivial gates.
  static List<int> _exitPortIndices(LayoutNode child, int entryPortIndex) {
    if (entryPortIndex < 0 || entryPortIndex >= child.elkPorts.length) {
      return const [];
    }
    final entryDirection = child.elkPorts[entryPortIndex].direction;

    // For inout ports, return all *other* port indices (both input and
    // output).  For input/output, return the opposite direction plus any
    // inout ports.
    if (entryDirection == PortDirection.inout) {
      return [
        for (var i = 0; i < child.elkPorts.length; i++)
          if (i != entryPortIndex) i,
      ];
    }

    final oppositeDirection = entryDirection == PortDirection.input
        ? PortDirection.output
        : PortDirection.input;

    return [
      for (var i = 0; i < child.elkPorts.length; i++)
        if (child.elkPorts[i].direction == oppositeDirection ||
            child.elkPorts[i].direction == PortDirection.inout)
          i,
    ];
  }

  /// Incrementally expand a port with pass-through traversal.
  ///
  /// Like `expandPort`, but continues through trivial gates (buffers,
  /// inverters, slicers, concatenators) until non-trivial children or
  /// external ports of `nodeId` are reached.
  ///
  /// **Direction semantics:**
  /// * WEST ports (inputs) — the signal flows inward; traversal follows
  ///   hyperedge targets from the parent port to child INPUT ports, then
  ///   exits through child OUTPUT ports.  CONCAT children may fanout
  ///   (one output → many sources in the next hyperedge).
  /// * EAST ports (outputs) — the signal flows outward; traversal follows
  ///   hyperedge sources from the parent port to child OUTPUT ports, then
  ///   exits through child INPUT ports.  SLICE children may fanout
  ///   (one input → many targets in the next hyperedge).
  ///
  /// The traversal uses a BFS queue of port IDs (child-side) that still
  /// need to be matched against hyperedges.  Each newly discovered
  /// trivial child enqueues its "exit" ports for further exploration.
  ///
  /// Returns `true` if new children/edges were revealed.
  bool expandPortThrough(String nodeId, String portId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    if (node.hiddenChildren == null || node.hiddenChildren!.isEmpty) {
      return false;
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      return false;
    }

    // Use shared collection logic to find gates and edges on this port path.
    final (collectedChildIds, collectedHyperedgeIds) =
        _collectPortThroughGatesAndEdges(node, portId);

    if (collectedChildIds.isEmpty && collectedHyperedgeIds.isEmpty) {
      return false;
    }

    // Check idempotency.
    final existingChildren = node.partialChildIds ?? {};
    final existingEdges = node.partialHyperedgeIds ?? {};
    if (existingChildren.containsAll(collectedChildIds) &&
        existingEdges.containsAll(collectedHyperedgeIds)) {
      return false;
    }

    // Additive: merge into existing partial sets.
    final mergedChildren = {...existingChildren, ...collectedChildIds};
    final mergedEdges = {...existingEdges, ...collectedHyperedgeIds};

    node
      ..partialChildIds = mergedChildren
      ..partialHyperedgeIds = mergedEdges;

    return true;
  }

  /// Collapse the children and edges that `expandPortThrough` would reveal.
  ///
  /// Runs the same BFS from `portId` through hyperedges and trivial gates, but
  /// **removes** the discovered children and edges from the partial expansion
  /// sets instead of adding them.  A child is only removed when no remaining
  /// visible hyperedge still references it.
  ///
  /// Non-trivial child modules are always kept in `partialChildIds` even when
  /// no remaining edge references them — only trivial pass-through gates are
  /// removed.  This ensures that block-mode children survive port collapse: if
  /// a module was visible before the port was expanded, collapsing the port
  /// must not hide it.
  ///
  /// If the node is fully expanded, initializes it to a partially-expanded
  /// state containing all visible children and edges before removing the ones
  /// associated with `portId`.
  ///
  /// Returns a tuple of (changed, removedChildIds) where:
  /// - changed: true if any children/edges were removed
  /// - removedChildIds: set of child node IDs that were removed (for focus
  ///   recovery)
  (bool, Set<String>) collapsePortThroughWithRemoved(
    String nodeId,
    String portId,
  ) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return (false, <String>{});
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      return (false, <String>{});
    }

    // If the node is fully expanded, physically move all children to
    // hiddenChildren so that _applyPartialExpansions can selectively
    // restore only the ones we keep.  Just setting partialChildIds without
    // moving children would leave them all visible because
    // _applyPartialExpansions only acts when hiddenChildren is non-empty.
    // We deliberately do NOT call node.toggle() here because toggle()
    // calls clearDescendantMarks which would discard any partial/blocks-only
    // expansion state on sub-children.
    if (node.isExpanded && !node.isPartiallyExpanded) {
      final allChildIds = node.children.map((c) => c.id).toSet();
      final allEdgeIds = hyperedges.map((h) => h.id).toSet();
      node
        ..hiddenChildren = List.of(node.children)
        ..children = []
        ..partialChildIds = allChildIds
        ..partialHyperedgeIds = allEdgeIds;
    }

    // Must be partially expanded for collapse to make sense.
    if (!node.isPartiallyExpanded) {
      return (false, <String>{});
    }

    // Use shared collection logic: same BFS traversal as expand.
    // This ensures we remove exactly what expand added.
    final (collectedChildIds, collectedHyperedgeIds) =
        _collectPortThroughGatesAndEdges(node, portId);

    if (collectedChildIds.isEmpty && collectedHyperedgeIds.isEmpty) {
      return (false, <String>{});
    }

    final existingChildren = node.partialChildIds;
    final existingEdges = node.partialHyperedgeIds;
    if (existingChildren == null || existingEdges == null) {
      return (false, <String>{});
    }

    // Remove ONLY the gates and edges discovered on THIS BFS path.
    // This ensures perfect symmetry with expand.
    var remainingChildren = existingChildren.difference(collectedChildIds);
    final remainingEdges = existingEdges.difference(collectedHyperedgeIds);

    // A collected child must only be hidden when ALL of the following hold:
    //   1. No remaining visible edge still references it (e.g. a BUF whose
    //      input wire is still shown must stay visible), AND
    //   2. It is a primitive leaf node (operator/gate with no sub-children).
    //      Non-primitive submodules are kept visible even after their last
    //      wire is collapsed — the user must explicitly toggle them closed.
    final allChildMap = <String, LayoutNode>{};
    for (final c in node.children) {
      allChildMap[c.id] = c;
    }
    if (node.hiddenChildren != null) {
      for (final c in node.hiddenChildren!) {
        allChildMap[c.id] = c;
      }
    }

    for (final childId in collectedChildIds) {
      // Keep if a remaining edge still references this child.
      var keep = false;
      for (final h in hyperedges) {
        if (!remainingEdges.contains(h.id)) {
          continue;
        }
        if (h.sources.any((s) => s.$1 == childId) ||
            h.targets.any((t) => t.$1 == childId)) {
          keep = true;
          break;
        }
      }
      // Also keep if this is a non-primitive submodule (has sub-children).
      if (!keep) {
        final child = allChildMap[childId];
        if (child != null &&
            (child.children.isNotEmpty ||
                (child.hiddenChildren != null &&
                    child.hiddenChildren!.isNotEmpty))) {
          keep = true;
        }
      }
      if (keep) {
        remainingChildren = {...remainingChildren, childId};
      }
    }

    // Check if anything actually changed.
    if (remainingChildren.length == existingChildren.length &&
        remainingEdges.length == existingEdges.length) {
      return (false, <String>{});
    }

    if (remainingChildren.isEmpty && remainingEdges.isEmpty) {
      // Fully collapsed — clear partial state.
      node
        ..partialChildIds = null
        ..partialHyperedgeIds = null;
    } else {
      node
        ..partialChildIds = remainingChildren
        ..partialHyperedgeIds = remainingEdges;
    }

    return (true, collectedChildIds);
  }

  /// Collapse the children and edges that `expandPortThrough` would reveal.
  ///
  /// Returns `true` if any children/edges were removed.
  /// For detailed removal info (to recover focus),
  /// use `collapsePortThroughWithRemoved`.
  bool collapsePortThrough(String nodeId, String portId) {
    final (changed, _) = collapsePortThroughWithRemoved(nodeId, portId);
    return changed;
  }

  /// Recursively collapse a port through trivial gates and across
  /// already-opened module boundaries.
  ///
  /// Uses the same directional discovery as `expandPortThroughRecursive`, but
  /// only descends into children that remain expanded or partially expanded.
  ///
  /// Returns `true` if any children/edges were removed at any level.
  bool collapsePortThroughRecursive(
    String nodeId,
    String portId, {
    Set<(String, String)>? visited,
  }) {
    visited ??= {};
    final key = (nodeId, portId);
    if (visited.contains(key)) {
      return false;
    }
    visited.add(key);

    // Collapse at this level.
    final changed = collapsePortThrough(nodeId, portId);

    final node = nodeMap[nodeId];
    if (node == null) {
      return changed;
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      final parent = node.parent;
      if (parent == null ||
          (!parent.isExpanded && !parent.isPartiallyExpanded)) {
        return changed;
      }
      final parentChanged = collapsePortThroughRecursive(
        parent.id,
        portId,
        visited: visited,
      );
      return changed || parentChanged;
    }

    // Convert string portId to (ownerNodeId, portIndex).
    // The port might belong to this node or one of its children.
    final resolved = node.resolvePortId(portId);
    if (resolved == null) {
      return changed;
    }
    final startNodeId = resolved.$1;
    final startPortIdx = resolved.$2;

    // BFS from `portId` — identical to expandPortThroughRecursive.
    final allChildren = <String, LayoutNode>{};
    for (final child in node.children) {
      allChildren[child.id] = child;
    }
    if (node.hiddenChildren != null) {
      for (final child in node.hiddenChildren!) {
        allChildren[child.id] = child;
      }
    }
    final startOwner = startNodeId == node.id ? node : allChildren[startNodeId];
    if (startOwner == null ||
        startPortIdx < 0 ||
        startPortIdx >= startOwner.elkPorts.length) {
      return changed;
    }
    final traceUpstream =
        startOwner.elkPorts[startPortIdx].direction == PortDirection.output;

    // BFS queue: (nodeId, portIndex) tuples.
    final portQueue = Queue<(String, int)>()..add((startNodeId, startPortIdx));
    final visitedPorts = <(String, int)>{};
    // childPorts: childNodeId → set of port IDs (strings for recursive calls)
    final childPorts = <String, Set<String>>{};
    final parentPorts = <String>{};

    final idx = node.portHyperedgeIndex;

    while (portQueue.isNotEmpty) {
      final current = portQueue.removeFirst();
      if (!visitedPorts.add(current)) {
        continue;
      }

      final currentNodeId = current.$1;
      final currentPortIdx = current.$2;

      List<LayoutHyperedge>? matching;
      if (currentNodeId == node.id) {
        matching = idx[currentPortIdx];
      } else {
        matching = _findHyperedgesForPort(node, currentNodeId, currentPortIdx);
      }

      if (matching == null || matching.isEmpty) {
        continue;
      }

      for (final h in matching) {
        for (final (nId, pIdx) in h.sources) {
          if (nId == node.id) {
            parentPorts.add(node.portIdAt(pIdx));
          }
        }
        for (final (nId, pIdx) in h.targets) {
          if (nId == node.id) {
            parentPorts.add(node.portIdAt(pIdx));
          }
        }

        final directionalEndpoints = traceUpstream ? h.sources : h.targets;
        final childEndpoints = directionalEndpoints
            .where((endpoint) => endpoint.$1 != node.id)
            .toList();
        if (childEndpoints.length != 1) {
          continue;
        }
        final (nId, pIdx) = childEndpoints.single;
        final child = allChildren[nId];
        final portIdStr = child?.portIdAt(pIdx) ?? pIdx.toString();
        childPorts.putIfAbsent(nId, () => <String>{}).add(portIdStr);
        if (child != null && _isTrivialGate(child)) {
          final exits = _exitPortIndices(child, pIdx);
          if (exits.length == 1) {
            portQueue.add((nId, exits.single));
          }
        }
      }
    }

    var anyRecursive = false;

    // --- Downward recursion into expanded/partial children ---
    for (final entry in childPorts.entries) {
      final childId = entry.key;
      final child = allChildren[childId];
      if (child == null) {
        continue;
      }
      if (_isTrivialGate(child)) {
        continue;
      }
      if (!child.isExpanded && !child.isPartiallyExpanded) {
        continue;
      }

      for (final childPortId in entry.value) {
        if (collapsePortThroughRecursive(
          childId,
          childPortId,
          visited: visited,
        )) {
          anyRecursive = true;
        }
      }
    }

    // --- Upward recursion through the parent boundary ---
    if (parentPorts.isNotEmpty && node.parent != null) {
      var currentNode = node;
      var currentParent = node.parent!;
      var portsToPropagate = parentPorts;

      while (portsToPropagate.isNotEmpty) {
        if (!currentParent.isExpanded && !currentParent.isPartiallyExpanded) {
          break;
        }

        final nextPorts = <String>{};

        for (final pIdStr in portsToPropagate) {
          final propKey = (currentParent.id, pIdStr);
          if (visited.contains(propKey)) {
            continue;
          }
          visited.add(propKey);

          if (collapsePortThrough(currentParent.id, pIdStr)) {
            anyRecursive = true;
          }

          // Convert string portId to index for parent's lookup.
          final pIdxVal = currentParent.portIndexById(pIdStr);
          if (pIdxVal < 0) {
            continue;
          }
          final pIdx = currentParent.portHyperedgeIndex;
          final pMatching = pIdx[pIdxVal];
          if (pMatching == null) {
            continue;
          }

          // Also need current node's port index for the involves check.
          final currentNodePortIdx = currentNode.portIndexById(pIdStr);

          for (final h in pMatching) {
            // Check if this hyperedge involves (currentNode.id, portIdx).
            var involves = false;
            for (final (nId, hpIdx) in h.sources) {
              if (nId == currentNode.id && hpIdx == currentNodePortIdx) {
                involves = true;
                break;
              }
            }
            if (!involves) {
              for (final (nId, hpIdx) in h.targets) {
                if (nId == currentNode.id && hpIdx == currentNodePortIdx) {
                  involves = true;
                  break;
                }
              }
            }
            if (!involves) {
              continue;
            }

            for (final (nId, hpIdx) in h.sources) {
              if (nId == currentNode.id) {
                continue;
              }
              if (nId == currentParent.id) {
                nextPorts.add(currentParent.portIdAt(hpIdx));
              } else {
                final sibling = nodeMap[nId];
                if (sibling != null &&
                    (sibling.isExpanded || sibling.isPartiallyExpanded)) {
                  final sibPortStr = sibling.portIdAt(hpIdx);
                  if (collapsePortThroughRecursive(
                    nId,
                    sibPortStr,
                    visited: visited,
                  )) {
                    anyRecursive = true;
                  }
                }
              }
            }
            for (final (nId, hpIdx) in h.targets) {
              if (nId == currentNode.id) {
                continue;
              }
              if (nId == currentParent.id) {
                nextPorts.add(currentParent.portIdAt(hpIdx));
              } else {
                final sibling = nodeMap[nId];
                if (sibling != null &&
                    (sibling.isExpanded || sibling.isPartiallyExpanded)) {
                  final sibPortStr = sibling.portIdAt(hpIdx);
                  if (collapsePortThroughRecursive(
                    nId,
                    sibPortStr,
                    visited: visited,
                  )) {
                    anyRecursive = true;
                  }
                }
              }
            }
          }
        }

        if (nextPorts.isEmpty || currentParent.parent == null) {
          break;
        }
        currentNode = currentParent;
        currentParent = currentParent.parent!;
        portsToPropagate = nextPorts;
      }
    }

    return changed || anyRecursive;
  }

  /// Recursively expand a port through trivial gates and across
  /// already-opened module boundaries.
  ///
  /// First runs `expandPortThrough` on `nodeId`/`portId`, then:
  ///
  /// * **Downward**: for each revealed non-trivial child, finds the boundary
  ///   port(s) and recurses into that child, partially expanding the connected
  ///   path even when the child was previously collapsed.
  /// * **Upward**: if the traversal reached a port on `nodeId` itself
  ///   (i.e. the signal exits through the module boundary) and the
  ///   parent node is visible, reveals connected siblings at the parent
  ///   level and recurses into siblings that are already open.  If the
  ///   signal reaches the parent's own boundary, climbs further up
  ///   using an iterative loop — never re-entering an intermediate
  ///   module, which would redundantly expand unrelated internal wires.
  ///
  /// Traversal continues only while each step has a unique exit. It stops at
  /// fan-out rather than expanding multiple downstream branches.
  ///
  /// A visited set of `(nodeId, portId)` pairs prevents infinite loops
  /// when signals form combinational cycles or the same boundary port
  /// is reachable from multiple directions.
  ///
  /// Returns `true` if any new children/edges were revealed at any
  /// level of the hierarchy.
  bool expandPortThroughRecursive(
    String nodeId,
    String portId, {
    Set<(String, String)>? visited,
  }) {
    visited ??= {};
    final key = (nodeId, portId);
    if (visited.contains(key)) {
      return false;
    }
    visited.add(key);

    // Expand at this level (may be a no-op for fully expanded nodes).
    final changed = expandPortThrough(nodeId, portId);

    final node = nodeMap[nodeId];
    if (node == null) {
      return changed;
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      final parent = node.parent;
      if (parent == null ||
          (!parent.isExpanded && !parent.isPartiallyExpanded)) {
        return changed;
      }
      final parentChanged = expandPortThroughRecursive(
        parent.id,
        portId,
        visited: visited,
      );
      return changed || parentChanged;
    }

    // Convert string portId to (ownerNodeId, portIndex).
    // The port might belong to this node or one of its children.
    final resolved = node.resolvePortId(portId);
    if (resolved == null) {
      return changed;
    }
    final startNodeId = resolved.$1;
    final startPortIdx = resolved.$2;

    // BFS from `portId` through this node's hyperedges (mirrors the
    // traversal in expandPortThrough) to discover:
    //   childPorts: childId → {portId strings on that child}
    //   parentPorts: portId strings on `node` itself (boundary exits)
    // This works for partially expanded AND fully expanded nodes.
    final allChildren = <String, LayoutNode>{};
    for (final child in node.children) {
      allChildren[child.id] = child;
    }
    if (node.hiddenChildren != null) {
      for (final child in node.hiddenChildren!) {
        allChildren[child.id] = child;
      }
    }
    final startOwner = startNodeId == node.id ? node : allChildren[startNodeId];
    if (startOwner == null ||
        startPortIdx < 0 ||
        startPortIdx >= startOwner.elkPorts.length) {
      return changed;
    }
    final traceUpstream =
        startOwner.elkPorts[startPortIdx].direction == PortDirection.output;

    // BFS queue: (nodeId, portIndex) tuples.
    final portQueue = Queue<(String, int)>()..add((startNodeId, startPortIdx));
    final visitedPorts = <(String, int)>{};
    final childPorts = <String, Set<String>>{};
    final parentPorts = <String>{};

    final idx = node.portHyperedgeIndex;

    while (portQueue.isNotEmpty) {
      final current = portQueue.removeFirst();
      if (!visitedPorts.add(current)) {
        continue;
      }

      final currentNodeId = current.$1;
      final currentPortIdx = current.$2;

      List<LayoutHyperedge>? matching;
      if (currentNodeId == node.id) {
        matching = idx[currentPortIdx];
      } else {
        matching = _findHyperedgesForPort(node, currentNodeId, currentPortIdx);
      }

      if (matching == null || matching.isEmpty) {
        continue;
      }

      for (final h in matching) {
        for (final (nId, pIdx) in h.sources) {
          if (nId == node.id) {
            parentPorts.add(node.portIdAt(pIdx));
          }
        }
        for (final (nId, pIdx) in h.targets) {
          if (nId == node.id) {
            parentPorts.add(node.portIdAt(pIdx));
          }
        }

        final directionalEndpoints = traceUpstream ? h.sources : h.targets;
        final childEndpoints = directionalEndpoints
            .where((endpoint) => endpoint.$1 != node.id)
            .toList();
        if (childEndpoints.length != 1) {
          continue;
        }
        final (nId, pIdx) = childEndpoints.single;
        final child = allChildren[nId];
        final portIdStr = child?.portIdAt(pIdx) ?? pIdx.toString();
        childPorts.putIfAbsent(nId, () => <String>{}).add(portIdStr);
        if (child != null && _isTrivialGate(child)) {
          final exits = _exitPortIndices(child, pIdx);
          if (exits.length == 1) {
            portQueue.add((nId, exits.single));
          }
        }
      }
    }

    var anyRecursive = false;

    // --- Downward recursion into expanded/partial children ---
    for (final entry in childPorts.entries) {
      final childId = entry.key;
      final child = allChildren[childId];
      if (child == null) {
        continue;
      }
      if (_isTrivialGate(child)) {
        continue; // already traversed through
      }

      for (final childPortId in entry.value) {
        if (expandPortThroughRecursive(
          childId,
          childPortId,
          visited: visited,
        )) {
          anyRecursive = true;
        }
      }
    }

    // --- Upward recursion through the parent boundary ---
    // For each boundary port, climb up through ancestor modules:
    //   1. At the parent level, call expandPortThrough to reveal the
    //      connected siblings/edges.
    //   2. Walk the parent's hyperedges to find siblings and further
    //      boundary exits.
    //   3. Recurse into siblings that are already open.
    //   4. If the signal exits through the parent's own boundary,
    //      continue climbing (repeat at grandparent level) WITHOUT
    //      re-entering the parent — that would redundantly expand
    //      unrelated internal wires.
    if (parentPorts.isNotEmpty && node.parent != null) {
      // Seed: current node's boundary ports at the first parent level.
      var currentNode = node;
      var currentParent = node.parent!;
      var portsToPropagate = parentPorts;

      while (portsToPropagate.isNotEmpty) {
        if (!currentParent.isExpanded && !currentParent.isPartiallyExpanded) {
          break;
        }

        final nextPorts = <String>{};

        for (final pIdStr in portsToPropagate) {
          final propKey = (currentParent.id, pIdStr);
          if (visited.contains(propKey)) {
            continue;
          }
          visited.add(propKey);

          // Reveal siblings + edges at this level.
          if (expandPortThrough(currentParent.id, pIdStr)) {
            anyRecursive = true;
          }

          // Convert string portId to index for parent's lookup.
          final pIdxVal = currentParent.portIndexById(pIdStr);
          if (pIdxVal < 0) {
            continue;
          }
          final pIdx = currentParent.portHyperedgeIndex;
          final pMatching = pIdx[pIdxVal];
          if (pMatching == null) {
            continue;
          }

          // Also need current node's port index for the involves check.
          final currentNodePortIdx = currentNode.portIndexById(pIdStr);

          // Find hyperedges that reference (currentNode.id, portIdx).
          for (final h in pMatching) {
            var involves = false;
            for (final (nId, hpIdx) in h.sources) {
              if (nId == currentNode.id && hpIdx == currentNodePortIdx) {
                involves = true;
                break;
              }
            }
            if (!involves) {
              for (final (nId, hpIdx) in h.targets) {
                if (nId == currentNode.id && hpIdx == currentNodePortIdx) {
                  involves = true;
                  break;
                }
              }
            }
            if (!involves) {
              continue;
            }

            for (final (nId, hpIdx) in h.sources) {
              if (nId == currentNode.id) {
                continue;
              }
              if (nId == currentParent.id) {
                nextPorts.add(currentParent.portIdAt(hpIdx));
              } else {
                final sibling = nodeMap[nId];
                if (sibling != null &&
                    (sibling.isExpanded || sibling.isPartiallyExpanded)) {
                  final sibPortStr = sibling.portIdAt(hpIdx);
                  if (expandPortThroughRecursive(
                    nId,
                    sibPortStr,
                    visited: visited,
                  )) {
                    anyRecursive = true;
                  }
                }
              }
            }
            for (final (nId, hpIdx) in h.targets) {
              if (nId == currentNode.id) {
                continue;
              }
              if (nId == currentParent.id) {
                nextPorts.add(currentParent.portIdAt(hpIdx));
              } else {
                final sibling = nodeMap[nId];
                if (sibling != null &&
                    (sibling.isExpanded || sibling.isPartiallyExpanded)) {
                  final sibPortStr = sibling.portIdAt(hpIdx);
                  if (expandPortThroughRecursive(
                    nId,
                    sibPortStr,
                    visited: visited,
                  )) {
                    anyRecursive = true;
                  }
                }
              }
            }
          }
        }

        // Climb one level higher.
        if (nextPorts.isEmpty || currentParent.parent == null) {
          break;
        }
        currentNode = currentParent;
        currentParent = currentParent.parent!;
        portsToPropagate = nextPorts;
      }
    }

    return changed || anyRecursive;
  }

  /// Partially expand a node to reveal a specific wire (hyperedge) by name.
  ///
  /// Finds the hyperedge on `nodeId` whose `hwMeta.name` matches `wireName`,
  /// then reveals all child nodes connected by that hyperedge plus the
  /// hyperedge itself.  Used by the search routine to show a wire without
  /// fully expanding the containing module.
  ///
  /// Returns `true` if new children/edges were revealed.
  bool expandWire(String nodeId, String wireName) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    // Node must have hidden children for partial expansion to make sense.
    if (node.hiddenChildren == null || node.hiddenChildren!.isEmpty) {
      return false;
    }

    final hyperedges = node.hyperedges;
    if (hyperedges == null || hyperedges.isEmpty) {
      return false;
    }

    final matchingHyperedgeIds = <String>{};
    final connectedChildIds = <String>{};

    for (final h in hyperedges) {
      if (h.name != wireName) {
        continue;
      }

      matchingHyperedgeIds.add(h.id);
      for (final (nId, _) in h.sources) {
        if (nId != node.id) {
          connectedChildIds.add(nId);
        }
      }
      for (final (nId, _) in h.targets) {
        if (nId != node.id) {
          connectedChildIds.add(nId);
        }
      }
    }

    if (connectedChildIds.isEmpty && matchingHyperedgeIds.isEmpty) {
      return false;
    }

    // Check if everything is already visible (idempotent)
    final existingChildren = node.partialChildIds ?? {};
    final existingEdges = node.partialHyperedgeIds ?? {};
    if (existingChildren.containsAll(connectedChildIds) &&
        existingEdges.containsAll(matchingHyperedgeIds)) {
      return false;
    }

    // Additive: merge into existing partial sets.
    final mergedChildren = {...existingChildren, ...connectedChildIds};
    final mergedEdges = {...existingEdges, ...matchingHyperedgeIds};

    node
      ..partialChildIds = mergedChildren
      ..partialHyperedgeIds = mergedEdges;

    return true;
  }

  /// Collapse a partially expanded node back to fully collapsed.
  ///
  /// Clears `partialChildIds` and `partialHyperedgeIds` on the node,
  /// returning it to a fully collapsed state (all children hidden).
  ///
  /// Returns `true` if the node was partially expanded and is now collapsed.
  bool collapsePartialExpansion(String nodeId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }
    if (!node.isPartiallyExpanded) {
      return false;
    }

    node
      ..partialChildIds = null
      ..partialHyperedgeIds = null;
    return true;
  }

  /// Convert a fully expanded node to blocks-only mode.
  ///
  /// Collapses the node (toggle), then re-expands only its non-primitive
  /// children without edges.  This is an atomic operation — the caller
  /// only needs a single re-layout afterwards.
  ///
  /// Returns `true` if the conversion happened.
  bool convertToBlocksOnly(String nodeId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    // Must be fully expanded (not partially expanded).
    if (!node.isExpanded) {
      return false;
    }

    // Pre-check: at least one child must be non-primitive (has its own
    // children or hiddenChildren).  Without this, we'd collapse the node
    // and have nothing to show in blocks-only mode.
    final hasNonPrimitive = node.children.any(
      (c) =>
          c.children.isNotEmpty ||
          (c.hiddenChildren != null && c.hiddenChildren!.isNotEmpty),
    );
    if (!hasNonPrimitive) {
      return false;
    }

    // Toggle collapses it (children → hiddenChildren).
    node.toggle();

    // Now expand non-primitives in blocks-only mode.
    final result = expandNonPrimitives(nodeId, includeEdges: false);
    return result;
  }

  /// Expand all non-primitive (submodule) hidden children of a node.
  ///
  /// A non-primitive child is one that has children or hidden children
  /// of its own (i.e. it is a submodule, not a leaf/primitive gate).
  /// This also reveals the hyperedges that connect to those children.
  ///
  /// Returns `true` if new children/edges were revealed.
  bool expandNonPrimitives(String nodeId, {bool includeEdges = true}) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    // Node must have hidden children for this to make sense.
    if (node.hiddenChildren == null || node.hiddenChildren!.isEmpty) {
      return false;
    }

    // Find non-primitive hidden children (have children or hiddenChildren).
    final nonPrimitiveIds = <String>{};
    for (final child in node.hiddenChildren!) {
      if (child.children.isNotEmpty || child.isExpandable) {
        nonPrimitiveIds.add(child.id);
      }
    }

    if (nonPrimitiveIds.isEmpty) {
      return false;
    }

    // Find hyperedges that connect to these non-primitive children.
    final matchingHyperedgeIds = <String>{};
    if (includeEdges) {
      final hyperedges = node.hyperedges;
      if (hyperedges != null) {
        for (final h in hyperedges) {
          var involves = false;
          for (final (nId, _) in h.sources) {
            if (nonPrimitiveIds.contains(nId)) {
              involves = true;
              break;
            }
          }
          if (!involves) {
            for (final (nId, _) in h.targets) {
              if (nonPrimitiveIds.contains(nId)) {
                involves = true;
                break;
              }
            }
          }
          if (involves) {
            matchingHyperedgeIds.add(h.id);
          }
        }
      }
    }

    // Check if everything is already visible (idempotent)
    final existingChildren = node.partialChildIds ?? {};
    final existingEdges = node.partialHyperedgeIds ?? {};
    if (existingChildren.containsAll(nonPrimitiveIds) &&
        existingEdges.containsAll(matchingHyperedgeIds)) {
      return false; // Already visible
    }

    // Additive: merge into existing partial sets
    node
      ..partialChildIds = {...existingChildren, ...nonPrimitiveIds}
      ..partialHyperedgeIds = {...existingEdges, ...matchingHyperedgeIds};

    return true;
  }

  /// Partially expand a specific hidden child by name.
  ///
  /// Finds the hidden child whose label (in hwMeta) matches `childName`
  /// and marks it (plus its connecting hyperedges) as partially visible.
  /// Used by the search/navigate routine to reveal only the path to a
  /// target without fully expanding every level.
  ///
  /// Returns `true` if a new child was revealed.
  bool expandChild(String nodeId, String childName) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return false;
    }

    if (node.hiddenChildren == null || node.hiddenChildren!.isEmpty) {
      return false;
    }

    // Find the hidden child by name.
    //
    // We check both hwMeta.name (display name) AND the last segment of
    // hierarchyNodeId (instance name from the netlist). These can
    // differ for operator/primitive cells whose display name is the
    // translated operator name (e.g. "MUX") while the hierarchy uses the
    // cell instance name (e.g. "mux_0").
    String? targetChildId;
    for (final child in node.hiddenChildren!) {
      if (child.hwMeta.name == childName) {
        targetChildId = child.id;
        break;
      }
      // Fallback: match on instance name from hierarchy path.
      final hid = child.hierarchyNodeId;
      if (hid != null) {
        final lastSeg =
            hid.contains('/') ? hid.substring(hid.lastIndexOf('/') + 1) : hid;
        if (lastSeg == childName) {
          targetChildId = child.id;
          break;
        }
      }
    }
    if (targetChildId == null) {
      return false;
    }

    // If the target is already visible in the partial set, nothing to do.
    // Do NOT recompute matching hyperedges here: the parent may be in
    // blocks-only mode (edges intentionally hidden) and recalculating
    // edges would upgrade it to a wired partial expansion — defeating
    // the purpose of blocks-only mode.
    final existingChildren = node.partialChildIds ?? {};
    if (existingChildren.contains(targetChildId)) {
      return false;
    }

    // Find hyperedges that connect only visible children (including
    // the newly-revealed target) and/or the parent boundary.
    // Edges that reference hidden siblings are excluded — they would
    // create dangling wires to nodes the user hasn't expanded yet.
    final matchingHyperedgeIds = <String>{};
    final mergedChildren = <String>{...existingChildren, targetChildId};
    // Also include already-visible children (from full expansion).
    for (final child in node.children) {
      mergedChildren.add(child.id);
    }
    final hyperedges = node.hyperedges;
    if (hyperedges != null) {
      for (final h in hyperedges) {
        final allEndpointsVisible = h.sources.every(
              (s) => s.$1 == node.id || mergedChildren.contains(s.$1),
            ) &&
            h.targets.every(
              (t) => t.$1 == node.id || mergedChildren.contains(t.$1),
            );
        if (allEndpointsVisible) {
          matchingHyperedgeIds.add(h.id);
        }
      }
    }

    final existingEdges = node.partialHyperedgeIds ?? {};

    // Additive: merge into existing partial sets.
    node
      ..partialChildIds = mergedChildren
      ..partialHyperedgeIds = {...existingEdges, ...matchingHyperedgeIds};

    return true;
  }

  /// Batch-expand an entire hierarchy path in a single pass.
  ///
  /// Walks `pathSegments` from the top-level expanded node downward,
  /// calling `expandChild` at each intermediate level and optionally
  /// `expandWire` at the final level.  All graph mutations happen
  /// before any serialisation or layout, so the caller only needs a
  /// single `toJsGraph()` → ELK → `setState()` cycle afterwards.
  ///
  /// `pathSegments` are the instance names along the path (e.g.
  /// ``'CPU', 'ALU', 'adder_0'``).
  ///
  /// If `targetWireName` is non-null the last segment is treated as
  /// Resolve a list of instance-name path segments to the node address
  /// (ID) of the last segment's node.
  ///
  /// Walks the graph from the root using the same parent-resolution
  /// logic as `expandPath` but without mutating the graph.  Returns
  /// `null` if any segment cannot be found.
  String? resolvePathToNodeId(List<String> pathSegments) {
    if (pathSegments.isEmpty) {
      return null;
    }

    final firstName = pathSegments.first;
    String? currentParentId;

    if (_findChildIdByName(root.children, firstName) != null ||
        _findChildIdByName(root.hiddenChildren ?? [], firstName) != null) {
      currentParentId = root.id;
    } else {
      for (final child in root.children) {
        if (_findChildIdByName(child.children, firstName) != null ||
            _findChildIdByName(child.hiddenChildren ?? [], firstName) != null) {
          currentParentId = child.id;
          break;
        }
      }
    }

    if (currentParentId == null) {
      return null;
    }

    String? lastNodeId;
    for (final name in pathSegments) {
      final parent = nodeMap[currentParentId];
      if (parent == null) {
        return null;
      }
      final childId = _findChildIdByName(parent.children, name) ??
          _findChildIdByName(parent.hiddenChildren ?? [], name);
      if (childId == null) {
        return null;
      }
      lastNodeId = childId;
      currentParentId = childId;
    }

    return lastNodeId;
  }

  /// the container of that wire: the container is revealed via
  /// `expandChild`, then `expandWire` is called on it.  When null the
  /// last segment is treated as the final target itself (module
  /// search).
  ///
  /// Returns `true` if at least one graph mutation occurred.
  bool expandPath(List<String> pathSegments, {String? targetWireName}) {
    if (pathSegments.isEmpty) {
      return false;
    }

    var changed = false;

    // Locate the starting parent — the node that contains the first
    // path segment as a child (visible or hidden).
    //
    // In the real app the structure is:
    //   root → `topModule`  (topModule is partially/blocks-only expanded)
    //   topModule → CPU, Memory, ...
    //
    // The path segments start at "CPU", so we need to descend through
    // root's visible children to find who actually owns "CPU".
    final firstName = pathSegments.first;
    String? currentParentId;

    // Check root itself first (matches the unit-test fixture).
    if (_findChildIdByName(root.children, firstName) != null ||
        _findChildIdByName(root.hiddenChildren ?? [], firstName) != null) {
      currentParentId = root.id;
    } else {
      // Check root's visible children (e.g. the top module).
      for (final child in root.children) {
        if (_findChildIdByName(child.children, firstName) != null ||
            _findChildIdByName(child.hiddenChildren ?? [], firstName) != null) {
          currentParentId = child.id;
          break;
        }
      }
    }

    if (currentParentId == null) {
      return false;
    }

    for (var i = 0; i < pathSegments.length; i++) {
      final name = pathSegments[i];
      final isLast = i == pathSegments.length - 1;

      final parent = nodeMap[currentParentId];
      if (parent == null) {
        break;
      }

      // Try to find the child among visible children first.
      var childNodeId = _findChildIdByName(parent.children, name);

      // Also check partially-expanded children: they live in
      // hiddenChildren but are conceptually visible via partialChildIds.
      if (childNodeId == null && parent.isPartiallyExpanded) {
        final candidate = _findChildIdByName(parent.hiddenChildren ?? [], name);
        if (candidate != null && parent.partialChildIds!.contains(candidate)) {
          childNodeId = candidate;
        }
      }

      // If not visible, it's in hiddenChildren — expandChild will reveal it.
      if (childNodeId == null) {
        if (expandChild(currentParentId!, name)) {
          changed = true;
        }
        // After expandChild the child's ID is now in partialChildIds.
        // Re-search hidden children to get the ID.
        childNodeId = _findChildIdByName(parent.hiddenChildren ?? [], name);
      }

      if (childNodeId == null) {
        break;
      }

      if (isLast) {
        if (targetWireName != null) {
          // Wire search: the last segment is the wire's container.
          // Ensure the container is visible, then reveal the wire inside it.
          if (expandWire(childNodeId, targetWireName)) {
            changed = true;
          }
        } else {
          // Module search: ensure the target itself is visible in its
          // parent. expandChild is additive/idempotent.
          if (expandChild(currentParentId!, name)) {
            changed = true;
          }
        }
      } else {
        // Intermediate: reveal the *next* segment inside this child.
        // First, make sure *this* child is visible in the parent.
        if (expandChild(currentParentId!, name)) {
          changed = true;
        }
      }

      currentParentId = childNodeId;
    }

    return changed;
  }

  /// Find a child node's ID by instance name.
  ///
  /// Checks `hwMeta.name` and falls back to the last segment of
  /// `hierarchyNodeId` (for primitives whose display name differs).
  String? _findChildIdByName(List<LayoutNode> children, String name) {
    for (final child in children) {
      if (child.hwMeta.name == name) {
        return child.id;
      }
      final hid = child.hierarchyNodeId;
      if (hid != null) {
        final lastSeg =
            hid.contains('/') ? hid.substring(hid.lastIndexOf('/') + 1) : hid;
        if (lastSeg == name) {
          return child.id;
        }
      }
    }
    return null;
  }

  /// Set parent references for all nodes.
  ///
  /// Must be called after building the graph.
  void initNodeParents() {
    _initNodeParentsRecursive(root, null);
  }

  void _initNodeParentsRecursive(LayoutNode node, LayoutNode? parent) {
    node.parent = parent;
    nodeMap[node.id] = node;

    for (final child in node.children) {
      _initNodeParentsRecursive(child, node);
    }

    if (node.hiddenChildren != null) {
      for (final child in node.hiddenChildren!) {
        _initNodeParentsRecursive(child, node);
      }
    }
  }

  /// Get all currently visible nodes (flattened).
  List<LayoutNode> get visibleNodes {
    final nodes = <LayoutNode>[];
    _collectVisibleNodes(root, nodes);
    return nodes;
  }

  void _collectVisibleNodes(LayoutNode node, List<LayoutNode> result) {
    result.add(node);
    for (final child in node.children) {
      _collectVisibleNodes(child, result);
    }
  }

  /// Get all currently visible ports (flattened).
  List<ElkPort> get visiblePorts {
    final ports = <ElkPort>[];
    for (final node in visibleNodes) {
      ports.addAll(node.allPorts);
    }
    return ports;
  }

  /// Convert to JSON string for ELK layout serialization.
  ///
  /// Hyperedges are expanded on-the-fly during `LayoutNode.toJson` — no
  /// separate expansion or filtering step is needed.
  String toJsGraph() {
    // Phase 1: Temporarily move partial children into visible lists.
    _applyPartialExpansions(root);

    // Phase 2: Ensure all nodes have sizes calculated.
    _prepareNodeSizes(root);

    // Phase 3: Serialize (edge expansion + filtering happen inside toJson).
    final json = jsonEncode(root.toJson());

    // Phase 4: Restore original child/hidden-child lists.
    _restorePartialExpansions(root);

    return json;
  }

  // -----------------------------------------------------------------------
  // Partial expansion helpers
  // -----------------------------------------------------------------------

  /// Temporarily move partial children from `hiddenChildren` to `children`
  /// so that ELK, edge expansion, and size calculation see them as visible.
  void _applyPartialExpansions(LayoutNode node) {
    if (node.isPartiallyExpanded &&
        node.hiddenChildren != null &&
        node.hiddenChildren!.isNotEmpty) {
      final toReveal = <LayoutNode>[];
      node.hiddenChildren!.removeWhere((child) {
        if (node.partialChildIds!.contains(child.id)) {
          toReveal.add(child);
          return true;
        }
        return false;
      });
      node.children.addAll(toReveal);
    }

    // Recurse into visible children AND hidden children — a hidden
    // child may itself be partially expanded (e.g. it was open then
    // the parent was collapsed around it).
    node.children.forEach(_applyPartialExpansions);
    (node.hiddenChildren ?? <LayoutNode>[]).forEach(_applyPartialExpansions);
  }

  /// Reverse the effect of `_applyPartialExpansions`: move partial
  /// children back from `children` to `hiddenChildren`.
  void _restorePartialExpansions(LayoutNode node) {
    if (node.isPartiallyExpanded) {
      final toHide = <LayoutNode>[];
      node.children.removeWhere((child) {
        if (node.partialChildIds!.contains(child.id)) {
          toHide.add(child);
          return true;
        }
        return false;
      });
      (node.hiddenChildren ??= []).addAll(toHide);
    }

    node.children.forEach(_restorePartialExpansions);
    (node.hiddenChildren ?? <LayoutNode>[]).forEach(_restorePartialExpansions);
  }

  /// Prepare node sizes for ELK layout.
  ///
  /// This mirrors the JS `prepareNodesForLayout()` function.
  void _prepareNodeSizes(LayoutNode node) {
    // COMBINATIONAL still gets generic sizing.
    // SLICE and CONCAT now get dedicated vertical-bar sizing.
    // Note: CONST nodes from $const cells now have name="0xff" and
    // cls="" to match JS dynamically-created constant nodes, so they go through
    // the generic path naturally without special handling here.
    const genericSliceRendererTypes = {'COMBINATIONAL'};
    final isGenericSliceType = genericSliceRendererTypes.contains(
      node.hwMeta.name,
    );
    final isConcatSlice = OperatorShapes.isConcatSlice(node.hwMeta.name);
    // Legacy $struct_field / $struct_compose cells use the same vertical-bar
    // sizing as SLICE/CONCAT so port labels (field names) fit inside the block.
    final isStructFieldCell = !isConcatSlice &&
        node.hwMeta.extra?['instanceName'] != null &&
        (node.hwMeta.extra!['instanceName'].toString().startsWith(
                  'struct_field',
                ) ||
            node.hwMeta.extra!['instanceName'].toString().startsWith(
                  'struct_compose',
                ));

    // Set CONCAT/SLICE sizes based on port counts and label widths
    if (node.hwMeta.cls == 'Operator' && isConcatSlice) {
      final size = _getConcatSliceSize(node);
      node
        ..width = size.$1
        ..height = size.$2;
      // Tell ELK to respect our pre-calculated size
      node.properties['org.eclipse.elk.nodeSize.constraints'] = 'MINIMUM_SIZE';
      node.properties['org.eclipse.elk.nodeSize.minimum'] =
          '(${size.$1},${size.$2})';
    }
    // Struct field/compose cells: size to fit centered field name text
    else if (node.hwMeta.cls == 'Operator' && isStructFieldCell) {
      final fieldName = node.hwMeta.name;
      const renderedCW = SchematicSizeConstants.renderedCharWidth;
      const charH = SchematicSizeConstants.charHeight;
      const padding = 16.0; // horizontal padding around text
      final textW = fieldName.length * renderedCW;
      final w = math.max<double>(textW + padding, 40);
      // Height: one port on each side, with some vertical padding
      final h = math.max<double>(2 * charH, 25);
      node
        ..width = w
        ..height = h;
      node.properties['org.eclipse.elk.nodeSize.constraints'] = 'MINIMUM_SIZE';
      node.properties['org.eclipse.elk.nodeSize.minimum'] = '($w,$h)';
    }
    // Set operator sizes (but not for generic slice renderer types,
    // concat/slice, or struct field/compose cells)
    else if (node.hwMeta.cls == 'Operator' &&
        !isGenericSliceType &&
        !isConcatSlice &&
        !isStructFieldCell) {
      final size = _getOperatorSize(node.hwMeta.name);
      if (size != null) {
        node
          ..width = size.$1
          ..height = size.$2;
      }
    }

    // Set generic node sizes if not already set, or for generic slice types
    if (node.hwMeta.cls != 'Operator' ||
        isGenericSliceType ||
        node.width == null) {
      _initGenericNodeSize(node);
    }

    // Set port sizes
    for (final port in node.elkPorts) {
      port.width ??= SchematicSizeConstants.portPinSize.$1;
      port.height ??= SchematicSizeConstants.portPinSize.$2;
    }

    // Reserve vertical space above blocks that display an instance-name
    // label so ELK routes edges around the label rather than through it.
    // The renderer draws the label at node.y − charHeight*0.85 ≈ 11 px
    // above the node box, so a 14 px top margin gives comfortable clearance.
    final hasLabel = node.hwMeta.cls != 'Operator' &&
        node.hwMeta.isExternalPort != true &&
        node.hwMeta.name.isNotEmpty;
    if (hasLabel) {
      node.properties['org.eclipse.elk.margins'] =
          '[top=14,left=0,bottom=0,right=0]';
    }

    // For compound nodes (those with visible children), set per-node ELK
    // padding so the outer block is wide enough for port labels and wire
    // routing to clear the inner children. The global padding
    // `top=30,left=60,bottom=10,right=60` uses a fixed 60px side margin,
    // which is too narrow when the outer block has long port names.
    if (node.children.isNotEmpty && node.elkPorts.isNotEmpty) {
      _setCompoundNodePadding(node);
    }

    // Recurse to children (including hidden) so all nodes have sizes.
    node.children.forEach(_prepareNodeSizes);
    if (node.hiddenChildren != null) {
      node.hiddenChildren!.forEach(_prepareNodeSizes);
    }
  }

  /// Set per-node ELK padding for compound nodes so that port labels on the
  /// outer block don't overlap with internal children or wire bends.
  ///
  /// ELK uses the `org.eclipse.elk.padding` property to reserve space between
  /// the node boundary and its children. By default, a global 60px left/right
  /// padding is applied. For compound nodes whose port labels are wider than
  /// that, we override the padding on the node itself.
  void _setCompoundNodePadding(LayoutNode node) {
    const renderedCW = SchematicSizeConstants.renderedCharWidth;
    const portPinPad = 10.0; // port pin width (7) + gap (3)
    const wireBendPad = 15.0; // extra space for orthogonal wire bends
    const defaultSidePad = 60.0;
    const topPad = 30.0;
    const bottomPad = 10.0;

    var maxWestLabelW = 0.0;
    var maxEastLabelW = 0.0;

    for (final port in node.elkPorts) {
      final labelW = port.hwMeta.name.length * renderedCW;
      if (port.side == 'WEST') {
        if (labelW > maxWestLabelW) {
          maxWestLabelW = labelW;
        }
      } else if (port.side == 'EAST') {
        if (labelW > maxEastLabelW) {
          maxEastLabelW = labelW;
        }
      }
    }

    // Padding = max(default 60, portLabel + pinPad + wireBendPad)
    final leftPad = [
      defaultSidePad,
      maxWestLabelW + portPinPad + wireBendPad,
    ].reduce((a, b) => a > b ? a : b);

    final rightPad = [
      defaultSidePad,
      maxEastLabelW + portPinPad + wireBendPad,
    ].reduce((a, b) => a > b ? a : b);

    // Only override if either side exceeds the default
    if (leftPad > defaultSidePad || rightPad > defaultSidePad) {
      node.properties['org.eclipse.elk.padding'] =
          '[top=${topPad.round()},left=${leftPad.round()},'
          'bottom=${bottomPad.round()},right=${rightPad.round()}]';
    }
  }

  /// Get operator size from name (matches JS OPERATOR_SIZES).
  (double, double)? _getOperatorSize(String name) {
    const defaultSize = (25.0, 25.0);
    if (name.startsWith('FF_SRST_EN_') || name.startsWith('FF_ARST_EN_')) {
      return (40.0, 60.0);
    }
    if (name.startsWith('FF_EN_') ||
        name.startsWith('FF_SRST_') ||
        name.startsWith('FF_ARST_')) {
      return (40.0, 50.0);
    }
    if (name.startsWith('FF_clk')) {
      return (25.0, 40.0);
    }
    const sizes = <String, (double, double)>{
      'BUF': defaultSize,
      'NOT': defaultSize,
      'AND': defaultSize,
      'NAND': defaultSize,
      'OR': defaultSize,
      'NOR': defaultSize,
      'XOR': defaultSize,
      'NXOR': defaultSize,
      'RISING_EDGE': defaultSize,
      'FALLING_EDGE': defaultSize,
      'ADD': defaultSize,
      'SUB': defaultSize,
      'EQ': defaultSize,
      'NE': defaultSize,
      'LT': defaultSize,
      'LE': defaultSize,
      'GE': defaultSize,
      'GT': defaultSize,
      'SHL': defaultSize,
      'SHR': defaultSize,
      'SHIFT': (50.0, 50.0),
      'MUL': defaultSize,
      'DIV': defaultSize,
      'FF': (25.0, 40.0),
      'MUX': (20.0, 40.0),
      'LATCHED_MUX': (20.0, 40.0),
      'DLATCH_en0': (50.0, 25.0),
      'DLATCH_en1': (50.0, 25.0),
    };
    return sizes[name] ?? defaultSize;
  }

  /// Calculate size for CONCAT/SLICE nodes based on their port counts
  /// and label widths.
  (double, double) _getConcatSliceSize(LayoutNode node) {
    var westCount = 0;
    var eastCount = 0;
    var maxWestLabelW = 0.0;
    var maxEastLabelW = 0.0;
    const renderedCW = SchematicSizeConstants.renderedCharWidth;
    for (final port in node.elkPorts) {
      final labelW = port.hwMeta.name.length * renderedCW;
      if (port.side == 'WEST') {
        westCount++;
        if (labelW > maxWestLabelW) {
          maxWestLabelW = labelW;
        }
      } else if (port.side == 'EAST') {
        eastCount++;
        if (labelW > maxEastLabelW) {
          maxEastLabelW = labelW;
        }
      }
    }
    final isConcat =
        node.hwMeta.name == 'CONCAT' || node.hwMeta.name == 'STRUCT_PACK';
    final isMultiOutput = node.hwMeta.name == 'STRUCT_UNPACK';
    final size = OperatorShapes.getConcatSliceSize(
      westCount,
      eastCount,
      maxWestLabelWidth: maxWestLabelW,
      maxEastLabelWidth: maxEastLabelW,
      isConcat: isConcat,
      isMultiOutput: isMultiOutput,
    );
    return (size.width, size.height);
  }

  /// Calculate size for generic (non-operator) nodes.
  void _initGenericNodeSize(LayoutNode node) {
    const charWidth = SchematicSizeConstants.charWidth;
    const renderedCW = SchematicSizeConstants.renderedCharWidth;
    const charHeight = SchematicSizeConstants.charHeight;
    const portHeight = SchematicSizeConstants.portHeight;
    const bodyTextPadding = SchematicSizeConstants.bodyTextPadding;
    const constNodePadding = SchematicSizeConstants.constNodePadding;
    const maxBodyTextSize = SchematicSizeConstants.maxBodyTextSize;

    // Determine if this is a constant node (radixString or legacy 0x).
    final isConstNode = isConstantName(node.hwMeta.name);
    final effectivePadding = isConstNode ? constNodePadding : bodyTextPadding;

    // Calculate body text size (matches JS initBodyTextLines)
    var bodyTextW = 0.0;
    var bodyTextH = 0.0;
    final bodyText = node.hwMeta.bodyText;
    if (bodyText != null && bodyText.isNotEmpty) {
      var maxLineLen = 0;
      for (final line in bodyText) {
        if (line.length > maxLineLen) {
          maxLineLen = line.length;
        }
      }
      bodyTextW = maxLineLen * renderedCW;
      bodyTextH = bodyText.length * charHeight;
      // Add padding
      if (bodyTextW > 0) {
        bodyTextW += effectivePadding.$2 + effectivePadding.$4; // right + left
      }
      if (bodyTextH > 0) {
        bodyTextH += effectivePadding.$1 + effectivePadding.$3; // top + bottom
      }
      // Clamp to max
      if (bodyTextW > maxBodyTextSize.$1) {
        bodyTextW = maxBodyTextSize.$1;
      }
      if (bodyTextH > maxBodyTextSize.$2) {
        bodyTextH = maxBodyTextSize.$2;
      }
    }

    // Calculate label width (node name is drawn above the block but we keep
    // it as a minimum-width contributor so narrow nodes are still readable).
    // Add padding to ensure the instance name doesn't overflow the block
    // boundary even with font rendering variations.
    final labelW = node.hwMeta.name.length * renderedCW + 2 * renderedCW;

    // Count ports per side and track per-side max label widths
    final portCounts = <String, int>{
      'WEST': 0,
      'EAST': 0,
      'NORTH': 0,
      'SOUTH': 0,
    };
    var maxWestLabelW = 0.0;
    var maxEastLabelW = 0.0;

    for (final port in node.elkPorts) {
      portCounts[port.side] = (portCounts[port.side] ?? 0) + 1;
      final portW = port.hwMeta.name.length * renderedCW;
      if (port.side == 'WEST') {
        if (portW > maxWestLabelW) {
          maxWestLabelW = portW;
        }
      } else if (port.side == 'EAST') {
        if (portW > maxEastLabelW) {
          maxEastLabelW = portW;
        }
      }
    }

    final westCount = portCounts['WEST']!;
    final eastCount = portCounts['EAST']!;
    final northCount = portCounts['NORTH']!;
    final southCount = portCounts['SOUTH']!;

    // Calculate width using per-side label widths.
    // Include port-pin indicator width + gap (portPinWidth + 3 = 10px) per
    // side so that labels actually fit inside the block boundary.
    const portPinPad = 10.0; // portPinSize width (7) + gap (3)
    const middleSpacing = 25.0;
    final hasWest = westCount > 0;
    final hasEast = eastCount > 0;
    final spacing = (hasWest && hasEast) ? middleSpacing : 0.0;
    final portColumnsWidth = (hasWest ? maxWestLabelW + portPinPad : 0) +
        (hasEast ? maxEastLabelW + portPinPad : 0) +
        spacing;

    // Width = max(portColumnsWidth, labelWidth, N/S ports) + bodyTextW + pad
    node
      ..width = [
            portColumnsWidth,
            labelW,
            (northCount > southCount ? northCount : southCount) * portHeight,
          ].reduce((a, b) => a > b ? a : b) +
          bodyTextW +
          renderedCW
      // Calculate height = max(E/W ports, bodyTextHeight, N/S port width)
      // When the node has children (expandable), reserve room for the
      // expand/collapse/blocks-only icon cluster in the upper-right
      // corner so it doesn't collide with east ports.  The icon itself
      // occupies one portHeight, plus we need a minimum gap (half a
      // portHeight) between the icon area and the first east port.
      // ELK spreads N east ports evenly → topmost at H/(N+1).
      // Add the extra whenever eastCount + 1 >= maxPortCount.
      ..height = () {
        final maxPortCount = westCount > eastCount ? westCount : eastCount;
        final portStackH = maxPortCount * portHeight;
        final isExpandable = node.children.isNotEmpty ||
            (node.hiddenChildren?.isNotEmpty ?? false);
        final iconPadH =
            (isExpandable && eastCount > 0 && eastCount + 1 >= maxPortCount)
                ? portHeight + portHeight * 0.5
                : 0.0;
        return [
          portStackH + iconPadH,
          bodyTextH,
          (northCount > southCount ? northCount : southCount) * charWidth,
        ].reduce((a, b) => a > b ? a : b);
      }();

    // Ensure minimum dimensions
    // Constants (0x...) can be smaller since they're just a label
    // Regular nodes need 20x20 minimum for readability
    final minSize = isConstNode ? 10.0 : 20.0;
    if (node.width! < minSize) {
      node.width = minSize;
    }
    if (node.height! < minSize) {
      node.height = minSize;
    }

    // Prevent ELK from re-expanding generic nodes for port/node labels.
    // Our width already accounts for port label text at the rendered font
    // size, so ELK's PORT_LABELS / NODE_LABELS constraints would
    // double-count and make blocks too wide.
    node.properties['org.eclipse.elk.nodeSize.constraints'] = 'MINIMUM_SIZE';
    node.properties['org.eclipse.elk.nodeSize.minimum'] =
        '(${node.width},${node.height})';
  }

  /// Convert to JSON map.
  Map<String, dynamic> toJson() => root.toJson();

  /// Create a deep copy of this graph.
  ///
  /// Useful for toggle operations that need a fresh state.
  SchematicGraph copy() {
    // Deep copy by serializing and deserializing
    final json = toJson();
    return SchematicGraph.fromJson(jsonEncode(json), hierarchy: hierarchy);
  }

  /// Parse a SchematicGraph from JSON.
  ///
  /// This is the inverse of toJson()/toJsGraph().
  factory SchematicGraph.fromJson(
    String jsonString, {
    HierarchyService? hierarchy,
  }) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final root = _parseNode(json);

    final graph = SchematicGraph(root: root, hierarchy: hierarchy)
      ..initNodeParents();
    return graph;
  }

  static LayoutNode _parseNode(Map<String, dynamic> json) {
    final hwMeta = _parseHwMeta(json['hwMeta'] as Map<String, dynamic>?);
    final nodeId = json['id'] as String;

    final ports = (json['ports'] as List<dynamic>?)
            ?.map((p) => _parsePort(p as Map<String, dynamic>))
            .toList() ??
        [];

    final children = (json['children'] as List<dynamic>?)
            ?.map((c) => _parseNode(c as Map<String, dynamic>))
            .toList() ??
        [];

    final hiddenChildren = (json['_children'] as List<dynamic>?)
        ?.map((c) => _parseNode(c as Map<String, dynamic>))
        .toList();

    // Build a portId → portIndex lookup for this scope so that edge
    // source/target port strings can be resolved without any assumption
    // about the ID format (address-based, sequential integers, or opaque).
    final portIdToIndex = <String, int>{};
    for (var i = 0; i < ports.length; i++) {
      portIdToIndex[ports[i].id] = i;
    }
    for (final child in children) {
      for (var i = 0; i < child.elkPorts.length; i++) {
        portIdToIndex[child.elkPorts[i].id] = i;
      }
    }
    if (hiddenChildren != null) {
      for (final child in hiddenChildren) {
        for (var i = 0; i < child.elkPorts.length; i++) {
          portIdToIndex[child.elkPorts[i].id] = i;
        }
      }
    }

    final parsedEdges = (json['edges'] as List<dynamic>?)
            ?.map((e) => _parseEdge(e as Map<String, dynamic>, portIdToIndex))
            .toList() ??
        [];

    final parsedHiddenEdges = (json['_edges'] as List<dynamic>?)
            ?.map((e) => _parseEdge(e as Map<String, dynamic>, portIdToIndex))
            .toList() ??
        [];

    final allParsedEdges = [...parsedEdges, ...parsedHiddenEdges];

    // Create a placeholder HierarchyOccurrence for JSON-parsed graphs.
    final occurrence = _createPlaceholderHierarchyOccurrence(
      nodeId,
      hwMeta.name,
      ports,
    );

    return LayoutNode(
      occurrence: occurrence,
      id: nodeId, // preserve address-based id from JSON (mirrors _makeNode)
      hwMeta: hwMeta,
      properties: json['properties'] as Map<String, dynamic>? ?? {},
      elkPorts: ports,
      children: children,
      hiddenChildren: hiddenChildren,
      hyperedges: allParsedEdges.isEmpty ? null : allParsedEdges,
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      width: (json['width'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
    );
  }

  static ElkPort _parsePort(Map<String, dynamic> json) {
    final hwMeta = _parseHwMeta(json['hwMeta'] as Map<String, dynamic>?);
    final props = json['properties'] as Map<String, dynamic>? ?? {};

    final children = (json['children'] as List<dynamic>?)
            ?.map((c) => _parsePort(c as Map<String, dynamic>))
            .toList() ??
        [];

    return ElkPort(
      id: json['id'] as String,
      hwMeta: hwMeta,
      direction: json['direction'] as String? ?? 'INOUT',
      side: props['side'] as String? ?? 'WEST',
      index: props['index'] as int? ?? 0,
      children: children,
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      width: (json['width'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
    );
  }

  static LayoutHyperedge _parseEdge(
    Map<String, dynamic> json,
    Map<String, int> portIdToIndex,
  ) {
    final hwMeta = _parseHwMeta(json['hwMeta'] as Map<String, dynamic>?);
    final id = json['id'] as String;
    final srcPortStr = json['sourcePort'] as String;
    final tgtPortStr = json['targetPort'] as String;

    // Resolve port IDs to indices via the lookup map — works for any
    // ID format (address-based, sequential integers, opaque strings).
    final srcPortIdx = portIdToIndex[srcPortStr] ?? 0;
    final tgtPortIdx = portIdToIndex[tgtPortStr] ?? 0;

    return LayoutHyperedge(
      id: id,
      signal: SignalOccurrence(name: hwMeta.name, width: 1),
      sources: [(json['source'] as String, srcPortIdx)],
      targets: [(json['target'] as String, tgtPortIdx)],
    );
  }

  static HwMeta _parseHwMeta(Map<String, dynamic>? json) {
    if (json == null) {
      return const HwMeta(name: '');
    }

    return HwMeta(
      name: json['name'] as String? ?? '',
      cls: json['cls'] as String? ?? '',
      bodyText: (json['bodyText'] as List<dynamic>?)?.cast<String>(),
      isExternalPort: json['isExternalPort'] as bool?,
      maxId: json['maxId'] as int?,
      signalWidth: json['signalWidth'] as int?,
    );
  }

  /// Look up the signal (hyperedge) name that connects to `portId`
  /// at the parent scope of the node that owns the port.
  ///
  /// Returns the hyperedge name, or `null` if no match is found.
  String? signalNameForPort(String nodeId, String portId) {
    final node = nodeMap[nodeId];
    if (node == null) {
      return null;
    }

    final parent = node.parent;
    if (parent == null) {
      return null;
    }
    final hyperedges = parent.hyperedges;
    if (hyperedges == null) {
      return null;
    }
    final portIdx = node.portIndexById(portId);
    if (portIdx < 0) {
      return null;
    }
    for (final h in hyperedges) {
      for (final (nId, pIdx) in h.sources) {
        if (pIdx == portIdx && nId == nodeId) {
          return h.name;
        }
      }
      for (final (nId, pIdx) in h.targets) {
        if (pIdx == portIdx && nId == nodeId) {
          return h.name;
        }
      }
    }
    return null;
  }

  /// Returns the directly connected port that drives [wireName] in [scopePath].
  ///
  /// A driver is either an output port of an instance in the scope or an input
  /// port on the scope itself. Returns null for missing, ambiguous, or inout
  /// connections so cross-probing never guesses at connectivity.
  String? directDriverSignalPath(String wireName, String scopePath) {
    LayoutNode? scope;
    for (final node in nodeMap.values) {
      if (node.occurrence.path() == scopePath) {
        scope = node;
        break;
      }
    }
    if (scope == null) {
      return null;
    }

    final matchingEdges = scope.hyperedges
        ?.where((hyperedge) => hyperedge.name == wireName)
        .toList();
    if (matchingEdges == null || matchingEdges.length != 1) {
      return null;
    }

    final drivers = <String>{};
    for (final (nodeId, portIndex) in matchingEdges.single.sources) {
      final node = nodeMap[nodeId];
      if (node == null || portIndex < 0 || portIndex >= node.elkPorts.length) {
        continue;
      }
      final port = node.elkPorts[portIndex];
      final isScopeInput =
          node == scope && port.direction == PortDirection.input;
      final isChildOutput =
          node.parent == scope && port.direction == PortDirection.output;
      if (isScopeInput || isChildOutput) {
        drivers.add('${node.occurrence.path()}/${port.hwMeta.name}');
      }
    }

    return drivers.length == 1 ? drivers.single : null;
  }

  /// Create a placeholder HierarchyOccurrence when the actual one
  /// isn't available.
  /// Used by `_parseNode` for JSON-parsed graphs without a hierarchy service.
  static HierarchyOccurrence _createPlaceholderHierarchyOccurrence(
    String id,
    String name,
    List<ElkPort> elkPorts,
  ) {
    final portSignals = elkPorts
        .map(
          (elkPort) => SignalOccurrence(
            name: elkPort.hwMeta.name,
            direction: elkPort.direction.toLowerCase(),
            width: 1,
          ),
        )
        .toList()
        .cast<SignalOccurrence>();

    return HierarchyOccurrence(name: name, signals: portSignals);
  }

  @override
  String toString() => 'SchematicGraph(nodes: ${nodeMap.length}, '
      'expanded: ${expandedNodeIds.length})';
}
