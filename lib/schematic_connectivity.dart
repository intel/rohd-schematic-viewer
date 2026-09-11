// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_connectivity.dart
// Public read-only API for schematic connectivity traversal.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Public schematic connectivity data API for read-only tooling.
library;

import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';

export 'src/schematic/netlist_schematic_adapter.dart';
export 'src/schematic/schematic_data.dart'
    show ElkPort, LayoutHyperedge, LayoutNode;
export 'src/schematic/schematic_graph.dart' show SchematicGraph;

/// How far schematic connectivity traversal should pass through hierarchy.
enum SchematicTraversalMode {
  /// Return only endpoints directly connected by the queried signal.
  opaque,

  /// Traverse using the current adapter's available connectivity data.
  transparent,
}

/// A concrete schematic node/port endpoint reached during traversal.
class SchematicPortOccurrence {
  /// Creates a schematic port endpoint.
  const SchematicPortOccurrence({required this.node, required this.port});

  /// Node that owns [port].
  final LayoutNode node;

  /// Port reached on [node].
  final ElkPort port;
}

/// Connectivity traversal helpers for hierarchy signal handles.
extension SignalOccurrenceSchematicTraversal on SignalOccurrence {
  /// Returns schematic endpoints that drive this signal.
  List<SchematicPortOccurrence> fanin(
    SchematicGraph schematic, {
    SchematicTraversalMode mode = SchematicTraversalMode.opaque,
  }) =>
      _endpointsFor(schematic, includeSources: true);

  /// Returns schematic endpoints that consume this signal.
  List<SchematicPortOccurrence> fanout(
    SchematicGraph schematic, {
    SchematicTraversalMode mode = SchematicTraversalMode.opaque,
  }) =>
      _endpointsFor(schematic, includeSources: false);

  List<SchematicPortOccurrence> _endpointsFor(
    SchematicGraph schematic, {
    required bool includeSources,
  }) {
    final endpoints = <SchematicPortOccurrence>[];
    for (final hyperedge in schematic.hyperedges) {
      if (!_matchesSignal(hyperedge.signal)) {
        continue;
      }
      final pairs = includeSources ? hyperedge.sources : hyperedge.targets;
      for (final (nodeId, portIndex) in pairs) {
        final node = schematic.nodeMap[nodeId];
        if (node == null ||
            portIndex < 0 ||
            portIndex >= node.elkPorts.length) {
          continue;
        }
        endpoints.add(
          SchematicPortOccurrence(node: node, port: node.elkPorts[portIndex]),
        );
      }
    }
    return endpoints;
  }

  bool _matchesSignal(SignalOccurrence other) {
    if (identical(this, other)) {
      return true;
    }
    final thisAddress = address;
    final otherAddress = other.address;
    if (thisAddress != null && otherAddress != null) {
      return thisAddress == otherAddress;
    }
    return path() == other.path();
  }
}
