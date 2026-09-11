// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_schematic_adapter.dart
// Yosys JSON to ROHD schematic graph adapter.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:rohd/rohd.dart' hide Port, State;
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/perf_log.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';
import 'package:rohd_source_navigator/flc_data.dart';

/// Adapter that builds ROHD schematic data directly from documented
/// Yosys JSON concepts: modules, ports, cells, connections, and netnames.
///
/// ROHD netlists (`creator: "NetlistSynthesizer (rohd)"`) add a small set
/// of fields beyond standard Yosys JSON -- e.g. `logic_type` on ports and
/// netnames, `attributes.rohd.src_trace` on modules, and the
/// `$struct_pack`/`$struct_unpack` cell types. See
/// `doc/netlist_json_format.md` in this repository for the full list.
class NetlistSchematicAdapter {
  /// The newest ROHD netlist schema version known to this adapter.
  ///
  /// This value is informational and must never be used to reject a netlist.
  /// Call [isRohdNetlistVersion] only when enabling behavior that depends on
  /// a specific ROHD extension format.
  static const String latestKnownRohdNetlistVersion = '0.0.2';

  /// Hierarchy service used for search/navigation.
  final HierarchyService hierarchy;

  /// ELK-ready schematic graph.
  final SchematicGraph schematic;

  /// The `creator` field from the parsed netlist JSON, or `null` if absent.
  final String? netlistCreator;

  /// The scalar `version` field from the parsed netlist JSON.
  ///
  /// Numeric and boolean values are preserved as strings. Missing or
  /// structured values produce `null`. This metadata never controls whether
  /// the underlying Yosys-compatible netlist can be rendered.
  final String? netlistVersion;

  /// Source locations embedded in the netlist's `rohd.src_trace` attributes.
  ///
  /// A standalone FLC sidecar can take precedence in a host integration, but
  /// this map keeps native netlist cross-probing available when no sidecar is
  /// present.
  final FlcData embeddedFlcData;

  /// Whether this is a ROHD-authored netlist with the specified [version].
  ///
  /// Use this to enable features tied to one schema version, not as a
  /// prerequisite for fundamental rendering.
  bool isRohdNetlistVersion(String version) =>
      netlistCreator == 'NetlistSynthesizer (rohd)' &&
      netlistVersion == version;

  NetlistSchematicAdapter._({
    required this.hierarchy,
    required this.schematic,
    required this.embeddedFlcData,
    this.netlistCreator,
    this.netlistVersion,
  });

  /// Parse a Yosys-compatible JSON netlist into hierarchy and schematic data.
  factory NetlistSchematicAdapter.fromJson(
    String netlistJson, {
    HierarchyService? externalHierarchy,
  }) {
    final decoded = jsonDecode(netlistJson) as Map<String, dynamic>;
    final creator = _readMetadataString(decoded['creator']);
    final version = _readMetadataString(decoded['version']);
    final modulesJson = decoded['modules'] as Map<String, dynamic>?;
    if (modulesJson == null || modulesJson.isEmpty) {
      throw const FormatException('Yosys JSON contained no modules');
    }

    final modules = <String, _YosysModule>{};
    for (final entry in modulesJson.entries) {
      modules[entry.key] = _YosysModule(entry.key, entry.value);
    }

    final topName = _topModuleName(modules);
    final builder = _SchematicBuilder(
      modules: modules,
      externalHierarchy: externalHierarchy,
    );
    final result = builder.build(topName);

    return NetlistSchematicAdapter._(
      hierarchy: externalHierarchy ?? result.hierarchy,
      schematic: result.graph,
      embeddedFlcData: FlcData.fromNetlistJson(decoded),
      netlistCreator: creator,
      netlistVersion: version,
    );
  }

  static String? _readMetadataString(Object? value) => switch (value) {
        String() => value,
        num() || bool() => value.toString(),
        _ => null,
      };

  static String _topModuleName(Map<String, _YosysModule> modules) {
    for (final module in modules.values) {
      if (module.attributes['top'] == 1) {
        return module.name;
      }
    }
    return modules.keys.first;
  }

  /// Serialize the current visible schematic state as ELK JSON.
  String toJsGraph() => schematic.toJsGraph();

  /// Toggle a node's expansion state.
  bool toggleNode(String nodeId) => schematic.toggleNode(nodeId);

  /// Reveal one collapsed-module port's connected interior path.
  bool expandPort(String nodeId, String portId) =>
      schematic.expandPort(nodeId, portId);

  /// Reveal a port path through transparent primitive gates.
  bool expandPortThrough(String nodeId, String portId) =>
      schematic.expandPortThrough(nodeId, portId);

  /// Reveal a port path recursively across opened hierarchy boundaries.
  bool expandPortThroughRecursive(String nodeId, String portId) =>
      schematic.expandPortThroughRecursive(nodeId, portId);

  /// Collapse a transparent port expansion.
  bool collapsePort(String nodeId, String portId) =>
      schematic.collapsePortThrough(nodeId, portId);

  /// Collapse a transparent port expansion and return removed gates.
  (bool changed, Set<String> removedGates) collapsePortWithRemoved(
    String nodeId,
    String portId,
  ) =>
      schematic.collapsePortThroughWithRemoved(nodeId, portId);

  /// Collapse a recursively expanded transparent port path.
  bool collapsePortRecursive(String nodeId, String portId) =>
      schematic.collapsePortThroughRecursive(nodeId, portId);

  /// Clear partial expansion state from a node.
  bool collapsePartialExpansion(String nodeId) =>
      schematic.collapsePartialExpansion(nodeId);

  /// Reveal non-primitive children without edges.
  bool expandNonPrimitives(String nodeId) =>
      schematic.expandNonPrimitives(nodeId, includeEdges: false);

  /// Convert an expanded node to blocks-only mode.
  bool convertToBlocksOnly(String nodeId) =>
      schematic.convertToBlocksOnly(nodeId);

  /// Recursively toggle a node and descendants.
  bool toggleNodeRecursive(String nodeId) =>
      schematic.toggleNodeRecursive(nodeId);

  /// Recursively reveal non-primitive children in blocks-only mode.
  bool expandNonPrimitivesRecursive(String nodeId) =>
      schematic.expandNonPrimitivesRecursive(nodeId);

  /// Recursively convert to blocks-only mode.
  bool convertToBlocksOnlyRecursive(String nodeId) =>
      schematic.convertToBlocksOnlyRecursive(nodeId);

  /// Partially reveal a wire by name.
  bool expandWire(String nodeId, String wireName) =>
      schematic.expandWire(nodeId, wireName);

  /// Partially reveal a child by instance name.
  bool expandChild(String nodeId, String childName) =>
      schematic.expandChild(nodeId, childName);

  /// Batch-expand a hierarchy path.
  bool expandPath(List<String> pathSegments, {String? targetWireName}) =>
      schematic.expandPath(pathSegments, targetWireName: targetWireName);

  /// Whether a node is currently expanded.
  bool isExpanded(String nodeId) => schematic.isExpanded(nodeId);

  /// Look up an embedded source entry for a signal in [moduleName].
  FlcEntry? lookupEmbeddedSignal(String moduleName, String signalName) =>
      embeddedFlcData.lookupSignalEntry(moduleName, signalName);

  /// Look up an embedded source entry for an instance in [moduleName].
  FlcEntry? lookupEmbeddedInstance(String moduleName, String instanceName) =>
      embeddedFlcData.lookupInstanceEntry(moduleName, instanceName);

  @override
  String toString() =>
      'NetlistSchematicAdapter(hierarchy: ${hierarchy.root.name}, '
      'schematic: ${schematic.nodeMap.length} nodes)';
}

class _BuildResult {
  const _BuildResult({required this.hierarchy, required this.graph});

  final HierarchyService hierarchy;
  final SchematicGraph graph;
}

/// Clean-local classification of documented Yosys primitive cell types.
class _YosysOperator {
  static const _names = <String, String>{
    'Modulo': 'MOD',
    'ReplicationOp': 'CONCAT',
    r'$mux': 'MUX',
    r'$pmux': 'MUX',
    r'$gt': 'GT',
    r'$lt': 'LT',
    r'$ge': 'GE',
    r'$le': 'LE',
    r'$buf': 'BUF',
    r'$not': 'NOT',
    r'$logic_not': 'NOT',
    r'$and': 'AND',
    r'$logic_and': 'AND',
    r'$or': 'OR',
    r'$logic_or': 'OR',
    r'$xor': 'XOR',
    r'$xnor': 'NXOR',
    r'$eq': 'EQ',
    r'$ne': 'NE',
    r'$add': 'ADD',
    r'$sub': 'SUB',
    r'$mul': 'MUL',
    r'$div': 'DIV',
    r'$mod': 'MOD',
    r'$slice': 'SLICE',
    r'$concat': 'CONCAT',
    r'$struct_unpack': 'STRUCT_UNPACK',
    r'$struct_pack': 'STRUCT_PACK',
    r'$dff': 'FF',
    r'$dffe': 'FF',
    r'$sdff': 'FF',
    r'$sdffe': 'FF',
    r'$adff': 'FF',
    r'$adffe': 'FF',
    r'$aldff': 'FF',
    r'$aldffe': 'FF',
    r'$shift': 'SHIFT',
    r'$shiftx': 'SHIFT',
    r'$shl': 'SHL',
    r'$sshl': 'SHL',
    r'$shr': 'SHR',
    r'$sshr': 'SHR',
    r'$reduce_and': 'AND',
    r'$reduce_or': 'OR',
    r'$reduce_xor': 'XOR',
    r'$reduce_xnor': 'NXOR',
    r'$reduce_bool': 'NOT',
    r'$nand': 'NAND',
    r'$nor': 'NOR',
    r'$pos': 'ADD',
    r'$neg': 'SUB',
    r'$tribuf': 'TRIBUF',
  };

  static (String name, String cls)? translate(
    String cellType,
    Map<String, dynamic> parameters,
  ) {
    if (cellType == r'$dlatch') {
      return (
        'DLATCH_en${_isOne(parameters['EN_POLARITY']) ? 1 : 0}',
        'Operator',
      );
    }
    if (parameters.containsKey('CLK_POLARITY')) {
      final clk = _isOne(parameters['CLK_POLARITY']) ? 1 : 0;
      final en = _isOne(parameters['EN_POLARITY']) ? 1 : 0;
      final rstParameter =
          cellType.startsWith(r'$adff') ? 'ARST_POLARITY' : 'SRST_POLARITY';
      final rst = _isOne(parameters[rstParameter]) ? 1 : 0;
      final flipFlopName = switch (cellType) {
        r'$dff' => 'FF_clk$clk',
        r'$dffe' => 'FF_EN_clk${clk}_en$en',
        r'$sdff' => 'FF_SRST_clk${clk}_rst$rst',
        r'$sdffe' => 'FF_SRST_EN_clk${clk}_rst${rst}_en$en',
        r'$adff' => 'FF_ARST_clk${clk}_rst$rst',
        r'$adffe' => 'FF_ARST_EN_clk${clk}_rst${rst}_en$en',
        _ => null,
      };
      if (flipFlopName != null) {
        return (flipFlopName, 'Operator');
      }
    }
    final name = _names[cellType];
    return name == null ? null : (name, 'Operator');
  }

  static bool _isOne(Object? value) =>
      value == true || value == 1 || value?.toString() == '1';
}

class _SchematicBuilder {
  _SchematicBuilder({required this.modules, required this.externalHierarchy});

  final Map<String, _YosysModule> modules;
  final HierarchyService? externalHierarchy;
  final _SimpleHierarchyAdapter hierarchyAdapter = _SimpleHierarchyAdapter();
  final Map<String, LayoutNode> nodeMap = {};

  bool get hasExternalHierarchy => externalHierarchy != null;

  _BuildResult build(String topName) {
    final root = _node(id: 'root', displayName: 'root', path: 'root');
    final topModule = modules[topName]!;
    final started = DateTime.now();
    final top = _moduleNode(
      module: topModule,
      instanceName: topName,
      definitionName: topName,
      address: const [0],
      path: topName,
    );
    if (kPerfLog) {
      debugPrint(
        '[PERF] NetlistSchematicAdapter build: '
        '${DateTime.now().difference(started).inMilliseconds} ms, '
        '${nodeMap.length} nodes built',
      );
    }

    root.children.add(top);
    top.parent = root;

    final hierarchy = externalHierarchy ?? hierarchyAdapter;
    if (!hasExternalHierarchy) {
      top.occurrence.buildAddresses();
      hierarchyAdapter.root = top.occurrence;
    }

    final graph = SchematicGraph(
      root: root,
      nodeMap: nodeMap,
      hierarchy: hierarchy,
    )..initNodeParents();

    if (!graph.expandNonPrimitives(top.id, includeEdges: false)) {
      graph.toggleNode(top.id);
    }

    return _BuildResult(hierarchy: hierarchy, graph: graph);
  }

  LayoutNode _moduleNode({
    required _YosysModule module,
    required String instanceName,
    required String definitionName,
    required List<int> address,
    required String path,
  }) {
    final id = _addressId(address);
    final occurrence = HierarchyOccurrence(
      name: instanceName,
      definition: definitionName,
    );
    final node = _node(
      id: id,
      displayName: instanceName,
      path: path,
      occurrence: hasExternalHierarchy ? null : occurrence,
    );
    // Record the module type (definition) separately from the instance
    // name. Cross-probe/source lookups are keyed by module type (e.g.
    // "FilterChannel_T3_W16_0"), not by the cell's instance name (e.g.
    // "ch0"), so this must survive into the serialized layout.
    node.hwMeta = node.hwMeta.copyWith(
      extra: {...?node.hwMeta.extra, 'definitionName': definitionName},
    );

    _addModulePorts(node: node, module: module, path: path);

    final cellNodes = <String, LayoutNode>{};
    var index = 0;
    for (final cell in module.cells) {
      final childAddress = [...address, index++];
      final childPath = '$path/${cell.name}';
      final child = _cellNode(
        cell: cell,
        address: childAddress,
        path: childPath,
      );
      node.children.add(child);
      child.parent = node;
      cellNodes[cell.name] = child;
      if (!hasExternalHierarchy) {
        occurrence.children.add(child.occurrence);
      }
    }

    _addModuleSignals(node: node, module: module, occurrence: occurrence);
    _addNetEdges(container: node, module: module, cellNodes: cellNodes);

    if (instanceName != definitionName && node.children.isNotEmpty) {
      node.hwMeta = node.hwMeta.copyWith(
        name: '$instanceName ($definitionName)',
      );
    }

    if (node.children.isNotEmpty) {
      node
        ..hiddenChildren = node.children
        ..children = [];
    }

    return node;
  }

  LayoutNode _cellNode({
    required _YosysCell cell,
    required List<int> address,
    required String path,
  }) {
    final module = modules[cell.type];
    final translated = _YosysOperator.translate(cell.type, cell.parameters);
    final primitive = cell.type.startsWith(r'$') ||
        HierarchyOccurrence.isPrimitiveType(cell.type) ||
        translated != null ||
        module == null;
    if (!primitive) {
      return _moduleNode(
        module: module,
        instanceName: cell.name,
        definitionName: cell.type,
        address: address,
        path: path,
      );
    }
    return _primitiveNode(cell: cell, address: address, path: path);
  }

  LayoutNode _primitiveNode({
    required _YosysCell cell,
    required List<int> address,
    required String path,
  }) {
    final id = _addressId(address);
    final occurrence = HierarchyOccurrence(
      name: cell.name,
      definition: cell.type,
      isPrimitive: true,
    );
    final node = _node(
      id: id,
      displayName: cell.name,
      path: path,
      occurrence: hasExternalHierarchy ? null : occurrence,
    );

    _addCellPorts(node: node..hwMeta = _primitiveMeta(cell), cell: cell);
    return node;
  }

  LayoutNode _node({
    required String id,
    required String displayName,
    required String path,
    HierarchyOccurrence? occurrence,
  }) {
    final hNode = occurrence ?? HierarchyOccurrence(name: displayName);
    final node = LayoutNode(
      occurrence: hNode,
      id: id,
      hwMeta: HwMeta(name: displayName),
    )..hierarchyNodeId = path;
    nodeMap[id] = node;
    return node;
  }

  void _addModulePorts({
    required LayoutNode node,
    required _YosysModule module,
    required String path,
  }) {
    var portIndex = 0;
    for (final port in module.ports) {
      final direction = PortDirection.fromNetlist(port.direction);
      final width = port.bits.length;
      if (direction == PortDirection.inout && node.id == '0') {
        node.elkPorts.add(
          _port(
            ownerId: node.id,
            index: portIndex++,
            name: port.name,
            direction: PortDirection.inout,
            side: PortSide.west,
            width: width,
          ),
        );
        node.elkPorts.add(
          _port(
            ownerId: node.id,
            index: portIndex++,
            name: port.name,
            direction: PortDirection.inout,
            side: PortSide.east,
            width: width,
          ),
        );
      } else {
        node.elkPorts.add(
          _port(
            ownerId: node.id,
            index: portIndex++,
            name: port.name,
            direction: direction,
            side: PortSide.fromDirection(direction),
            width: width,
          ),
        );
      }

      final logicType = port.logicType == null
          ? null
          : _remapLogicTypeBits(port.logicType!, port.bits);
      if (!hasExternalHierarchy) {
        node.occurrence.signals.add(
          SignalOccurrence(
            name: port.name,
            direction: port.direction,
            width: width,
            logicType: logicType,
          ),
        );
      } else if (logicType != null && externalHierarchy != null) {
        final address = externalHierarchy!.pathnameToAddress(
          '$path/${port.name}',
        );
        final signal = address == null
            ? null
            : externalHierarchy!.signalByAddress(address);
        signal?.logicType ??= logicType;
      }
    }
  }

  void _addCellPorts({required LayoutNode node, required _YosysCell cell}) {
    var index = 0;
    final structFieldCount = cell.isStructPack || cell.isStructUnpack
        ? cell.portDirections.keys
            .where((name) => cell.isStructUnpack ? name != 'A' : name != 'Y')
            .length
        : 0;

    for (final entry in cell.portDirections.entries) {
      final portName = entry.key;
      final direction = PortDirection.fromNetlist(entry.value);
      final displayName = _displayPortName(cell, portName);
      final side = _portSide(cell, portName, direction);
      final width = cell.connections[portName]?.length ?? 1;
      final layoutIndex = _layoutPortIndex(
        cell: cell,
        portName: portName,
        emittedIndex: index,
        structFieldCount: structFieldCount,
      );
      node.elkPorts.add(
        _port(
          ownerId: node.id,
          index: index,
          name: displayName,
          direction: direction,
          side: side,
          width: width,
          layoutIndex: layoutIndex,
          netlistPortName: displayName == portName ? null : portName,
        ),
      );
      index++;
    }
  }

  ElkPort _port({
    required String ownerId,
    required int index,
    required String name,
    required String direction,
    required String side,
    required int width,
    int? layoutIndex,
    String? netlistPortName,
  }) =>
      ElkPort(
        id: '$ownerId:$index',
        hwMeta: HwMeta(
          name: name,
          signalWidth: width,
          extra: netlistPortName == null
              ? null
              : {'netlistPortName': netlistPortName},
        ),
        direction: direction,
        side: side,
        index: layoutIndex ?? index,
      );

  void _addModuleSignals({
    required LayoutNode node,
    required _YosysModule module,
    required HierarchyOccurrence occurrence,
  }) {
    if (hasExternalHierarchy) {
      return;
    }
    final existing = occurrence.signals.map((signal) => signal.name).toSet();
    for (final net in module.netnames) {
      if (existing.contains(net.name)) {
        continue;
      }
      occurrence.signals.add(
        SignalOccurrence(
          name: net.name,
          width: net.bits.length,
          logicType: net.logicType,
        ),
      );
    }
  }

  void _addNetEdges({
    required LayoutNode container,
    required _YosysModule module,
    required Map<String, LayoutNode> cellNodes,
  }) {
    if (_recordSlimConnectedPorts(container: container, module: module)) {
      return;
    }

    final connectionsByBit = <int, _BitEndpoints>{};
    void addEndpoint(int bit, _Endpoint endpoint) {
      connectionsByBit.putIfAbsent(bit, _BitEndpoints.new).add(endpoint);
    }

    for (final port in module.ports) {
      for (var bitIndex = 0; bitIndex < port.bits.length; bitIndex++) {
        final bit = port.bits[bitIndex];
        if (bit == null) {
          continue;
        }
        if (port.direction == 'input' || port.direction == 'inout') {
          addEndpoint(bit, _Endpoint.modulePort(port.name, source: true));
        }
        if (port.direction == 'output') {
          addEndpoint(bit, _Endpoint.modulePort(port.name, source: false));
        }
      }
    }

    for (final cell in module.cells) {
      for (final entry in cell.connections.entries) {
        final portName = entry.key;
        final direction = cell.portDirections[portName] ?? 'inout';
        for (final bit in entry.value) {
          if (bit == null) {
            continue;
          }
          if (direction == 'output') {
            addEndpoint(
              bit,
              _Endpoint.cellPort(cell.name, portName, source: true),
            );
          }
          if (direction == 'input' || direction == 'inout') {
            addEndpoint(
              bit,
              _Endpoint.cellPort(cell.name, portName, source: false),
            );
          }
        }
      }
    }

    final processedBits = <int>{};
    final emitted = <String>{};
    for (final net in module.netnames) {
      for (final bit in net.bits) {
        if (bit == null || !processedBits.add(bit)) {
          continue;
        }
        final endpoints = connectionsByBit[bit];
        if (endpoints == null ||
            endpoints.sources.isEmpty ||
            endpoints.targets.isEmpty) {
          continue;
        }
        final sources = endpoints.sources
            .map(
              (endpoint) => _resolveEndpoint(
                endpoint: endpoint,
                container: container,
                cellNodes: cellNodes,
                forSource: true,
              ),
            )
            .whereType<(String, int)>()
            .toList();
        final targets = endpoints.targets
            .map(
              (endpoint) => _resolveEndpoint(
                endpoint: endpoint,
                container: container,
                cellNodes: cellNodes,
                forSource: false,
              ),
            )
            .whereType<(String, int)>()
            .toList();
        if (sources.isEmpty || targets.isEmpty) {
          continue;
        }
        final key = _edgeKey(sources, targets);
        if (!emitted.add(key)) {
          continue;
        }
        container.hyperedges ??= [];
        container.hyperedges!.add(
          LayoutHyperedge(
            id: '${container.id}:h${container.hyperedges!.length}',
            signal: SignalOccurrence(name: net.name, width: net.bits.length),
            sources: sources,
            targets: targets,
          ),
        );
      }
    }
  }

  bool _recordSlimConnectedPorts({
    required LayoutNode container,
    required _YosysModule module,
  }) {
    if (module.cells.isEmpty) {
      return false;
    }
    if (module.cells.any((cell) => cell.connections.isNotEmpty)) {
      return false;
    }
    for (final port in module.ports) {
      if (port.connected) {
        final index = _findPort(container, port.name);
        if (index >= 0) {
          container.slimConnectedPortIds ??= <String>{};
          container.slimConnectedPortIds!.add(container.portIdAt(index));
        }
      }
    }
    return true;
  }

  (String, int)? _resolveEndpoint({
    required _Endpoint endpoint,
    required LayoutNode container,
    required Map<String, LayoutNode> cellNodes,
    required bool forSource,
  }) {
    if (endpoint.isModulePort) {
      final side = forSource ? PortSide.west : PortSide.east;
      final portIndex = _findPort(container, endpoint.portName, side: side);
      return portIndex < 0 ? null : (container.id, portIndex);
    }
    final cell = cellNodes[endpoint.nodeName];
    if (cell == null) {
      final side = forSource ? PortSide.west : PortSide.east;
      final portIndex = _findPort(container, endpoint.portName, side: side);
      return portIndex < 0 ? null : (container.id, portIndex);
    }
    final portIndex = _findPort(cell, endpoint.portName);
    return portIndex < 0 ? null : (cell.id, portIndex);
  }

  int _findPort(LayoutNode node, String netlistPortName, {String? side}) {
    var first = -1;
    for (var i = 0; i < node.elkPorts.length; i++) {
      final port = node.elkPorts[i];
      final matches = port.hwMeta.name == netlistPortName ||
          port.hwMeta.extra?['netlistPortName'] == netlistPortName;
      if (!matches) {
        continue;
      }
      if (side != null && port.side == side) {
        return i;
      }
      first = first < 0 ? i : first;
    }
    return first;
  }

  HwMeta _primitiveMeta(_YosysCell cell) {
    final translation = _YosysOperator.translate(cell.type, cell.parameters);
    if (translation != null) {
      return HwMeta(
        name: translation.$1,
        cls: translation.$2,
        extra: translation.$1 == cell.name ? null : {'instanceName': cell.name},
      );
    }
    if (cell.type == r'$const') {
      return HwMeta(
        name: _constantLabel(cell) ?? "1'h0",
        extra: {'instanceName': cell.name},
      );
    }
    if (cell.type == r'$struct_field' || cell.type == r'$struct_compose') {
      final fieldName = cell.stringParameter('FIELD_NAME') ??
          _lastUnderscoreSegment(cell.name);
      return HwMeta(
        name: fieldName,
        cls: 'Operator',
        extra: {'instanceName': cell.name},
      );
    }
    if (cell.type == r'$struct_unpack') {
      return HwMeta(
        name: 'STRUCT_UNPACK',
        cls: 'Operator',
        extra: {
          'instanceName': cell.name,
          'structName': cell.stringParameter('STRUCT_NAME') ?? 'struct',
        },
      );
    }
    if (cell.type == r'$struct_pack') {
      return HwMeta(
        name: 'STRUCT_PACK',
        cls: 'Operator',
        extra: {
          'instanceName': cell.name,
          'structName': cell.stringParameter('STRUCT_NAME') ?? 'struct',
        },
      );
    }
    if (cell.type.startsWith(r'$')) {
      final name = cell.type.substring(1).toUpperCase();
      return HwMeta(
        name: name,
        cls: 'Operator',
        extra: name == cell.name ? null : {'instanceName': cell.name},
      );
    }
    final module = modules[cell.type];
    if (module != null && module.cells.isEmpty) {
      return HwMeta(name: cell.name, cls: 'Leaf');
    }
    return HwMeta(name: cell.name);
  }

  String _displayPortName(_YosysCell cell, String portName) {
    if (cell.type == 'ReplicationOp') {
      final width = cell.connections[portName]?.length ?? 0;
      final range = _rangeLabel(0, width);
      if (cell.portDirections[portName] != 'output') {
        return range;
      }

      var inputWidth = 0;
      for (final entry in cell.portDirections.entries) {
        if (entry.value == 'input') {
          inputWidth = cell.connections[entry.key]?.length ?? 0;
          break;
        }
      }
      if (inputWidth == 0 || width % inputWidth != 0) {
        return range;
      }

      final repeatCount = width ~/ inputWidth;
      return '$repeatCount X --> $range';
    }
    if (cell.isSliceLike) {
      if (portName == 'Y') {
        return cell.isStructField
            ? cell.stringParameter('FIELD_NAME') ?? ''
            : '';
      }
      if (portName == 'A') {
        final width = cell.intParameter('Y_WIDTH') == 0
            ? cell.intParameter('WIDTH')
            : cell.intParameter('Y_WIDTH');
        return _rangeLabel(cell.intParameter('OFFSET'), width);
      }
    }
    if (cell.type == r'$concat') {
      final aWidth = cell.intParameter('A_WIDTH');
      final bWidth = cell.intParameter('B_WIDTH');
      if (portName == 'Y') {
        return '';
      }
      if (portName == 'A') {
        return _rangeLabel(bWidth, aWidth);
      }
      if (portName == 'B') {
        return _rangeLabel(0, bWidth);
      }
    }
    if (cell.isStructUnpack && portName == 'A') {
      return '';
    }
    if (cell.isStructPack && portName == 'Y') {
      return '';
    }
    return portName;
  }

  String _portSide(_YosysCell cell, String portName, String direction) {
    final opName = _YosysOperator.translate(cell.type, cell.parameters)?.$1;
    if (opName == 'MUX' && portName == 'S') {
      return PortSide.south;
    }
    if (opName == 'FF' && portName == 'CLK') {
      return PortSide.south;
    }
    if (opName == 'TRIBUF' && portName == 'EN') {
      return PortSide.south;
    }
    if (opName == 'TRIBUF' && portName == 'Y') {
      return PortSide.east;
    }
    return PortSide.fromDirection(direction);
  }

  int _layoutPortIndex({
    required _YosysCell cell,
    required String portName,
    required int emittedIndex,
    required int structFieldCount,
  }) {
    if (cell.type == r'$concat' && portName == 'A') {
      return 1;
    }
    if (cell.type == r'$concat' && portName == 'B') {
      return 0;
    }
    if (cell.isStructUnpack && portName != 'A') {
      return structFieldCount - (emittedIndex - 1);
    }
    return emittedIndex;
  }

  static Map<String, dynamic> _remapLogicTypeBits(
    Map<String, dynamic> logicType,
    List<int?> portBits,
  ) {
    final wireToLocal = <int, int>{};
    for (var index = 0; index < portBits.length; index++) {
      final bit = portBits[index];
      if (bit != null) {
        wireToLocal[bit] = index;
      }
    }
    final fields = logicType['fields'] as List<dynamic>?;
    if (fields == null) {
      return logicType;
    }
    return {
      ...logicType,
      'fields': fields.map((raw) {
        final field = Map<String, dynamic>.from(raw as Map);
        final bits = field['bits'] as List<dynamic>?;
        if (bits != null) {
          field['bits'] = bits
              .map((bit) => bit is int ? wireToLocal[bit] ?? bit : bit)
              .toList();
        }
        final nested = field['type'] as Map<String, dynamic>?;
        if (nested != null) {
          field['type'] = _remapLogicTypeBits(nested, portBits);
        }
        return field;
      }).toList(),
    };
  }

  static String _edgeKey(
    List<(String, int)> sources,
    List<(String, int)> targets,
  ) {
    final src = sources.map((source) => '${source.$1},${source.$2}').join(';');
    final tgt = targets.map((target) => '${target.$1},${target.$2}').join(';');
    return '$src|$tgt';
  }

  static String _rangeLabel(int start, int width) {
    if (width == 1) {
      return '[$start]';
    }
    if (width > 1) {
      return '[${start + width - 1}:$start]';
    }
    return '';
  }

  static String _lastUnderscoreSegment(String value) {
    final parts = value.split('_');
    return parts.length > 3 ? parts.last : value;
  }

  static String _addressId(List<int> address) => address.join('.');

  static String? _constantLabel(_YosysCell cell) {
    final width = cell.parameters['WIDTH'];
    final value = cell.parameters['VALUE'];
    if (width != null && value != null) {
      final parsedWidth = _asInt(width);
      final parsedValue = _asInt(value);
      if (parsedValue != null) {
        return LogicValue.ofBigInt(
          BigInt.from(parsedValue),
          parsedWidth == null || parsedWidth < 1 ? 1 : parsedWidth,
        ).toString();
      }
    }
    for (final name in cell.portDirections.keys) {
      try {
        return LogicValue.ofRadixString(name).toString();
      } on Object {
        // Not a literal port name.
      }
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }
}

class _YosysModule {
  _YosysModule(this.name, Object? json)
      : data = Map<String, dynamic>.from(json! as Map);

  final String name;
  final Map<String, dynamic> data;

  Map<String, dynamic> get attributes =>
      Map<String, dynamic>.from(data['attributes'] as Map? ?? const {});

  List<_YosysPort> get ports {
    final rawPorts = data['ports'] as Map<String, dynamic>? ?? const {};
    return rawPorts.entries
        .map((entry) => _YosysPort(entry.key, entry.value))
        .toList();
  }

  List<_YosysCell> get cells {
    final rawCells = data['cells'] as Map<String, dynamic>? ?? const {};
    return rawCells.entries
        .map((entry) => _YosysCell(entry.key, entry.value))
        .toList();
  }

  List<_YosysNet> get netnames {
    final rawNets = data['netnames'] as Map<String, dynamic>? ?? const {};
    return rawNets.entries
        .map((entry) => _YosysNet(entry.key, entry.value))
        .toList();
  }
}

class _YosysPort {
  _YosysPort(this.name, Object? json)
      : data = Map<String, dynamic>.from(json! as Map);

  final String name;
  final Map<String, dynamic> data;

  String get direction => data['direction']?.toString() ?? 'inout';
  List<int?> get bits => _bits(data['bits']);
  bool get connected => data['connected'] == true;
  Map<String, dynamic>? get logicType => data['logic_type'] == null
      ? null
      : Map<String, dynamic>.from(data['logic_type'] as Map);
}

class _YosysCell {
  _YosysCell(this.name, Object? json)
      : data = Map<String, dynamic>.from(json! as Map);

  final String name;
  final Map<String, dynamic> data;

  String get type => data['type']?.toString() ?? '';
  Map<String, dynamic> get parameters =>
      Map<String, dynamic>.from(data['parameters'] as Map? ?? const {});
  Map<String, String> get portDirections {
    final raw = data['port_directions'] as Map? ?? const {};
    return raw.map((key, value) => MapEntry(key.toString(), value.toString()));
  }

  Map<String, List<int?>> get connections {
    final raw = data['connections'] as Map? ?? const {};
    return raw.map((key, value) => MapEntry(key.toString(), _bits(value)));
  }

  bool get isStructField =>
      type == r'$struct_field' || type == r'$struct_compose';
  bool get isSliceLike => type == r'$slice' || isStructField;
  bool get isStructPack => type == r'$struct_pack';
  bool get isStructUnpack => type == r'$struct_unpack';

  int intParameter(String name) =>
      _SchematicBuilder._asInt(parameters[name]) ?? 0;
  String? stringParameter(String name) => parameters[name]?.toString();
}

class _YosysNet {
  _YosysNet(this.name, Object? json)
      : data = Map<String, dynamic>.from(json! as Map);

  final String name;
  final Map<String, dynamic> data;

  List<int?> get bits => _bits(data['bits']);
  Map<String, dynamic>? get logicType => data['logic_type'] == null
      ? null
      : Map<String, dynamic>.from(data['logic_type'] as Map);
}

class _Endpoint {
  const _Endpoint._({
    required this.nodeName,
    required this.portName,
    required this.isModulePort,
    required this.isSource,
  });

  factory _Endpoint.modulePort(String portName, {required bool source}) =>
      _Endpoint._(
        nodeName: '',
        portName: portName,
        isModulePort: true,
        isSource: source,
      );

  factory _Endpoint.cellPort(
    String cellName,
    String portName, {
    required bool source,
  }) =>
      _Endpoint._(
        nodeName: cellName,
        portName: portName,
        isModulePort: false,
        isSource: source,
      );

  final String nodeName;
  final String portName;
  final bool isModulePort;
  final bool isSource;
}

class _BitEndpoints {
  final sources = <_Endpoint>[];
  final targets = <_Endpoint>[];

  void add(_Endpoint endpoint) {
    (endpoint.isSource ? sources : targets).add(endpoint);
  }
}

List<int?> _bits(Object? raw) {
  final list = raw as List? ?? const [];
  return list.map((bit) => bit is int ? bit : null).toList();
}

class _SimpleHierarchyAdapter extends BaseHierarchyAdapter {
  @override
  set root(HierarchyOccurrence value) => super.root = value;
}
