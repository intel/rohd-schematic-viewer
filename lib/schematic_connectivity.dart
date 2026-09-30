// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_connectivity.dart
// Public read-only API for schematic connectivity traversal.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Public schematic connectivity API for read-only tooling.
library;

import 'dart:collection' show ListQueue;
import 'dart:convert' show jsonDecode;

import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/transparent_traversal.dart';

export 'package:rohd_hierarchy/rohd_hierarchy.dart'
    show
        HierarchyOccurrence,
        HierarchyService,
        OccurrenceAddress,
        SignalOccurrence;

typedef _Endpoint = (String nodeId, int portIndex);
typedef _HyperedgeIndex = ({
  Map<_Endpoint, List<LayoutHyperedge>> bySource,
  Map<_Endpoint, List<LayoutHyperedge>> byTarget,
});

/// How far schematic connectivity traversal should pass through hierarchy.
enum SchematicTraversalMode {
  /// Return only endpoints directly connected by the queried signal.
  opaque,

  /// Traverse through transparent primitive gates.
  transparent,
}

/// An immutable schematic endpoint reached during connectivity traversal.
class SchematicPortOccurrence {
  /// Creates a stable schematic endpoint description.
  const SchematicPortOccurrence({
    required this.nodePath,
    required this.portId,
    required this.direction,
    this.nodeAddress,
  });

  /// Canonical hierarchy path of the node that owns the port.
  final String nodePath;

  /// Stable hierarchy address of the node, when one is assigned.
  final OccurrenceAddress? nodeAddress;

  /// Port identifier within the owning node.
  final String portId;

  /// Port direction declared by the netlist.
  final String direction;
}

/// Read-only connectivity extracted from a Yosys-compatible netlist.
///
/// This facade intentionally hides the mutable layout graph and adapter used
/// by the interactive viewer.
class NetlistSchematicConnectivity {
  NetlistSchematicConnectivity._(
    NetlistSchematicAdapter adapter,
    Map<String, Map<String, Set<int>>> signalBitsByModule,
  )   : _adapter = adapter,
        _hyperedgeIndex = _buildHyperedgeIndex(adapter.schematic.hyperedges) {
    _canonicalNodePaths = _buildCanonicalNodePaths(
      adapter.schematic.nodeMap.values,
      adapter.hierarchy,
    );
    _hyperedgeScopePaths = _buildHyperedgeScopePaths(
      adapter.schematic.nodeMap.values,
      _canonicalNodePaths,
    );
    _signalBitsByScope = _buildSignalBitsByScope(
      adapter.schematic.nodeMap.values,
      _canonicalNodePaths,
      signalBitsByModule,
    );
  }

  final NetlistSchematicAdapter _adapter;
  final _HyperedgeIndex _hyperedgeIndex;
  late final Map<String, String> _canonicalNodePaths;
  late final Map<LayoutHyperedge, String> _hyperedgeScopePaths;
  late final Map<String, Map<String, Set<int>>> _signalBitsByScope;

  /// Parses [netlistJson] into a read-only connectivity model.
  factory NetlistSchematicConnectivity.fromJson(
    String netlistJson, {
    HierarchyService? externalHierarchy,
  }) {
    final adapter = NetlistSchematicAdapter.fromJson(
      netlistJson,
      externalHierarchy: externalHierarchy,
    );
    return NetlistSchematicConnectivity._(
      adapter,
      _buildSignalBitsByModule(netlistJson),
    );
  }

  /// Hierarchy used to resolve signal paths and addresses.
  HierarchyService get hierarchy => _adapter.hierarchy;

  /// Returns schematic endpoints that drive [signal].
  List<SchematicPortOccurrence> fanin(
    SignalOccurrence signal, {
    SchematicTraversalMode mode = SchematicTraversalMode.opaque,
  }) =>
      _endpointsFor(signal, includeSources: true, mode: mode);

  /// Returns schematic endpoints that consume [signal].
  List<SchematicPortOccurrence> fanout(
    SignalOccurrence signal, {
    SchematicTraversalMode mode = SchematicTraversalMode.opaque,
  }) =>
      _endpointsFor(signal, includeSources: false, mode: mode);

  List<SchematicPortOccurrence> _endpointsFor(
    SignalOccurrence signal, {
    required bool includeSources,
    required SchematicTraversalMode mode,
  }) {
    final schematic = _adapter.schematic;
    final initialEndpoints = <(String, int)>[];
    final seenEndpoints = <(String, int)>{};
    for (final hyperedge in schematic.hyperedges) {
      if (!_matchesSignal(signal, hyperedge) ||
          !_matchesScope(signal, hyperedge)) {
        continue;
      }
      final pairs = includeSources ? hyperedge.sources : hyperedge.targets;
      for (final pair in pairs) {
        if (seenEndpoints.add(pair)) {
          initialEndpoints.add(pair);
        }
      }
    }
    if (mode == SchematicTraversalMode.transparent) {
      return _transparentEndpoints(
        initialEndpoints,
        traceUpstream: includeSources,
      );
    }
    return _describeEndpoints(initialEndpoints);
  }

  List<SchematicPortOccurrence> _transparentEndpoints(
    List<_Endpoint> initialEndpoints, {
    required bool traceUpstream,
  }) {
    final schematic = _adapter.schematic;
    final queue = ListQueue<_Endpoint>.from(initialEndpoints);
    final visited = <_Endpoint>{};
    final terminalEndpoints = <_Endpoint>[];
    final hyperedgesByExit =
        traceUpstream ? _hyperedgeIndex.byTarget : _hyperedgeIndex.bySource;

    while (queue.isNotEmpty) {
      final endpoint = queue.removeFirst();
      if (!visited.add(endpoint)) {
        continue;
      }
      final node = schematic.nodeMap[endpoint.$1];
      if (node == null ||
          endpoint.$2 < 0 ||
          endpoint.$2 >= node.elkPorts.length) {
        continue;
      }
      if (!isTransparentTraversalNode(node)) {
        terminalEndpoints.add(endpoint);
        continue;
      }

      for (final exitPort in transparentTraversalExitPorts(node, endpoint.$2)) {
        final exitEndpoint = (node.id, exitPort);
        for (final hyperedge
            in hyperedgesByExit[exitEndpoint] ?? const <LayoutHyperedge>[]) {
          queue.addAll(
            traceUpstream ? hyperedge.sources : hyperedge.targets,
          );
        }
      }
    }
    return _describeEndpoints(terminalEndpoints);
  }

  static _HyperedgeIndex _buildHyperedgeIndex(
    Iterable<LayoutHyperedge> hyperedges,
  ) {
    final bySource = <_Endpoint, List<LayoutHyperedge>>{};
    final byTarget = <_Endpoint, List<LayoutHyperedge>>{};

    for (final hyperedge in hyperedges) {
      for (final endpoint in hyperedge.sources) {
        bySource.putIfAbsent(endpoint, () => []).add(hyperedge);
      }
      for (final endpoint in hyperedge.targets) {
        byTarget.putIfAbsent(endpoint, () => []).add(hyperedge);
      }
    }

    return (bySource: bySource, byTarget: byTarget);
  }

  static Map<LayoutHyperedge, String> _buildHyperedgeScopePaths(
    Iterable<LayoutNode> nodes,
    Map<String, String> canonicalNodePaths,
  ) {
    final scopePaths = <LayoutHyperedge, String>{};

    for (final node in nodes) {
      final hyperedges = node.hyperedges;
      if (hyperedges == null) {
        continue;
      }
      final scopePath = canonicalNodePaths[node.id] ?? _adapterNodePath(node);
      for (final hyperedge in hyperedges) {
        scopePaths[hyperedge] = scopePath;
      }
    }

    return scopePaths;
  }

  static Map<String, Map<String, Set<int>>> _buildSignalBitsByModule(
    String netlistJson,
  ) {
    final netlist = jsonDecode(netlistJson) as Map<String, dynamic>;
    final modules = netlist['modules'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final signalBitsByModule = <String, Map<String, Set<int>>>{};

    for (final entry in modules.entries) {
      final module = entry.value as Map<String, dynamic>;
      final signalBits = <String, Set<int>>{};
      for (final tableName in const ['ports', 'netnames']) {
        final signals = module[tableName] as Map? ?? const <String, dynamic>{};
        for (final signal in signals.entries) {
          final bits = ((signal.value as Map?)?['bits'] as List? ?? const [])
              .whereType<int>();
          signalBits
              .putIfAbsent(signal.key.toString(), () => <int>{})
              .addAll(bits);
        }
      }
      signalBitsByModule[entry.key] = signalBits;
    }

    return signalBitsByModule;
  }

  static Map<String, Map<String, Set<int>>> _buildSignalBitsByScope(
    Iterable<LayoutNode> nodes,
    Map<String, String> canonicalNodePaths,
    Map<String, Map<String, Set<int>>> signalBitsByModule,
  ) {
    final signalBitsByScope = <String, Map<String, Set<int>>>{};

    for (final node in nodes) {
      final definitionName = node.hwMeta.extra?['definitionName']?.toString() ??
          node.occurrence.definition;
      final signalBits = signalBitsByModule[definitionName];
      if (signalBits == null) {
        continue;
      }
      final scopePath = canonicalNodePaths[node.id] ?? _adapterNodePath(node);
      signalBitsByScope[scopePath] = signalBits;
    }

    return signalBitsByScope;
  }

  static Map<String, String> _buildCanonicalNodePaths(
    Iterable<LayoutNode> nodes,
    HierarchyService hierarchy,
  ) {
    final paths = <String, String>{};
    for (final node in nodes) {
      final adapterPath = _adapterNodePath(node);
      final occurrence = hierarchy.occurrenceByPathname(adapterPath) ??
          _occurrenceForAdapterPath(hierarchy.root, adapterPath);
      paths[node.id] = occurrence?.path() ?? adapterPath;
    }
    return paths;
  }

  static String _adapterNodePath(LayoutNode node) =>
      node.hierarchyNodeId ?? node.occurrence.path();

  static HierarchyOccurrence? _occurrenceForAdapterPath(
    HierarchyOccurrence root,
    String adapterPath,
  ) {
    final segments = adapterPath.split('/');
    if (segments.isEmpty ||
        (root.name != segments.first && root.definition != segments.first)) {
      return null;
    }

    var occurrence = root;
    for (final segment in segments.skip(1)) {
      final index = occurrence.childIndexByName(segment);
      if (index < 0) {
        return null;
      }
      occurrence = occurrence.children[index];
    }
    return occurrence;
  }

  List<SchematicPortOccurrence> _describeEndpoints(
    List<_Endpoint> endpoints,
  ) =>
      [
        for (final (nodeId, portIndex) in endpoints)
          if (_adapter.schematic.nodeMap[nodeId] case final node?
              when portIndex >= 0 && portIndex < node.elkPorts.length)
            _endpoint(node, node.elkPorts[portIndex]),
      ];

  SchematicPortOccurrence _endpoint(LayoutNode node, ElkPort port) {
    final nodePath = _canonicalNodePaths[node.id] ?? _adapterNodePath(node);
    return SchematicPortOccurrence(
      nodePath: nodePath,
      nodeAddress:
          hierarchy.pathnameToAddress(nodePath) ?? node.occurrence.address,
      portId: port.id,
      direction: port.direction,
    );
  }

  bool _matchesSignal(
    SignalOccurrence signal,
    LayoutHyperedge hyperedge,
  ) {
    final other = hyperedge.signal;
    if (identical(signal, other)) {
      return true;
    }
    final signalAddress = signal.address;
    final otherAddress = other.address;
    if (signalAddress != null && otherAddress != null) {
      return signalAddress == otherAddress;
    }
    final otherPath = other.path();
    return signal.path() == otherPath ||
        (otherAddress == null &&
            otherPath == other.name &&
            signal.name == other.name) ||
        _sharesUnderlyingBit(signal, hyperedge);
  }

  bool _matchesScope(
    SignalOccurrence signal,
    LayoutHyperedge hyperedge,
  ) {
    if (hyperedge.signal.address != null ||
        hyperedge.signal.path() != hyperedge.signal.name) {
      return true;
    }

    final scopePath = signal.parent?.path();
    if (scopePath == null) {
      return signal.name == hyperedge.signal.name;
    }
    if (_hyperedgeScopePaths[hyperedge] != scopePath) {
      return false;
    }
    return signal.name == hyperedge.signal.name ||
        _sharesUnderlyingBit(signal, hyperedge);
  }

  bool _sharesUnderlyingBit(
    SignalOccurrence signal,
    LayoutHyperedge hyperedge,
  ) {
    final scopePath = signal.parent?.path();
    if (scopePath == null || _hyperedgeScopePaths[hyperedge] != scopePath) {
      return false;
    }

    final signalBits = _signalBitsByScope[scopePath]?[signal.name];
    final hyperedgeBits = _signalBitsByScope[scopePath]?[hyperedge.signal.name];
    if (signalBits == null || hyperedgeBits == null) {
      return false;
    }
    return signalBits.any(hyperedgeBits.contains);
  }
}
