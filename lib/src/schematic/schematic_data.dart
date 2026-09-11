// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_data.dart
// Core data models for ELK graph representation in Dart. These classes hold
// schematic-specific data used with the Dart ELK layout path.
//
// 2026 February
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

bool _hasRadixPrefix(String value) {
  final apostrophe = value.indexOf("'");
  if (apostrophe <= 0 || apostrophe + 1 >= value.length) {
    return false;
  }
  for (var index = 0; index < apostrophe; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit < 0x30 || codeUnit > 0x39) {
      return false;
    }
  }
  return 'bqodh'.contains(value[apostrophe + 1]);
}

/// Whether `name` looks like a constant value.
///
/// Recognises:
///  - ROHD radixString format (`8'hff`, `1'b0`)
///  - legacy hex (`0xff`)
///  - `const_`-prefixed instance names
bool isConstantName(String name) {
  if (name.isEmpty) {
    return false;
  }
  if (_hasRadixPrefix(name)) {
    return true;
  }
  final lower = name.toLowerCase();
  if (lower.startsWith('0x')) {
    return true;
  }
  if (lower.startsWith('const_')) {
    return true;
  }
  return false;
}

/// Hardware metadata attached to nodes, ports, and edges.
///
/// Mirrors the `hwMeta` object used in the ELK graph format.
class HwMeta {
  /// Display name for the component.
  final String name;

  /// Class/type indicator: "Operator", "", etc.
  final String cls;

  /// Body text lines for display inside nodes.
  final List<String>? bodyText;

  /// Whether this is an external port.
  final bool? isExternalPort;

  /// Maximum ID used in this subtree (for ID generation).
  final int? maxId;

  /// SignalOccurrence bit-width (e.g. 8 for an 8-bit bus).
  /// Null or 1 means a single bit.
  final int? signalWidth;

  /// Additional metadata fields.
  final Map<String, dynamic>? extra;

  /// Constructor for `HwMeta`.
  const HwMeta({
    required this.name,
    this.cls = '',
    this.bodyText,
    this.isExternalPort,
    this.maxId,
    this.signalWidth,
    this.extra,
  });

  /// Create a copy with updated fields.
  HwMeta copyWith({
    String? name,
    String? cls,
    List<String>? bodyText,
    bool? isExternalPort,
    int? maxId,
    int? signalWidth,
    Map<String, dynamic>? extra,
  }) =>
      HwMeta(
        name: name ?? this.name,
        cls: cls ?? this.cls,
        bodyText: bodyText ?? this.bodyText,
        isExternalPort: isExternalPort ?? this.isExternalPort,
        maxId: maxId ?? this.maxId,
        signalWidth: signalWidth ?? this.signalWidth,
        extra: extra ?? this.extra,
      );

  /// Convert to JSON map for JS serialization.
  Map<String, dynamic> toJson() => {
        'name': name,
        if (cls.isNotEmpty) 'cls': cls,
        if (bodyText != null && bodyText!.isNotEmpty) 'bodyText': bodyText,
        if (isExternalPort != null) 'isExternalPort': isExternalPort,
        if (maxId != null) 'maxId': maxId,
        if (signalWidth != null && signalWidth! > 1) 'signalWidth': signalWidth,
        // parent is not serialized directly; it's a reference
        if (extra != null) ...extra!,
      };

  @override
  String toString() => 'HwMeta(name: $name, cls: $cls)';
}

/// Padding for ELK layout.
class ElkPadding {
  /// Padding values in pixels.
  final double left;

  /// Padding values in pixels.
  final double right;

  /// Padding values in pixels.
  final double top;

  /// Padding values in pixels.
  final double bottom;

  /// Constructor for `ElkPadding`.
  const ElkPadding({
    this.left = 0,
    this.right = 0,
    this.top = 0,
    this.bottom = 0,
  });

  /// A convenient constant for zero padding.
  static const zero = ElkPadding();

  /// Convert to JSON map.
  Map<String, dynamic> toJson() => {
        'left': left,
        'right': right,
        'top': top,
        'bottom': bottom,
      };

  @override
  String toString() =>
      'ElkPadding(left: $left, right: $right, top: $top, bottom: $bottom)';
}

/// A 2D point for edge routing.
class ElkPoint {
  /// X coordinate in pixels.
  final double x;

  /// Y coordinate in pixels.
  final double y;

  /// Constructor for `ElkPoint`.
  const ElkPoint(this.x, this.y);

  /// Convert to JSON map.
  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  String toString() => 'ElkPoint($x, $y)';
}

/// Edge section for complex routing (from ELK output).
class ElkEdgeSection {
  /// Start point of the section.
  final ElkPoint startPoint;

  /// Bend points along the section (if any).
  final List<ElkPoint> bendPoints;

  /// End point of the section.
  final ElkPoint endPoint;

  /// Constructor for `ElkEdgeSection`.
  const ElkEdgeSection({
    required this.startPoint,
    required this.endPoint,
    this.bendPoints = const [],
  });

  /// Get all points as a flat list.
  List<ElkPoint> get allPoints => [startPoint, ...bendPoints, endPoint];

  /// Convert to JSON map.
  Map<String, dynamic> toJson() => {
        'startPoint': startPoint.toJson(),
        if (bendPoints.isNotEmpty)
          'bendPoints': bendPoints.map((p) => p.toJson()).toList(),
        'endPoint': endPoint.toJson(),
      };
}

/// ELK port with schematic-specific data.
///
/// Mirrors the port structure from the ELK graph format.
class ElkPort {
  /// Unique port ID (may be array-joined format like "1_clk").
  final String id;

  /// Port metadata.
  final HwMeta hwMeta;

  /// Port direction: INPUT, OUTPUT, INOUT.
  final String direction;

  /// Port side for ELK: WEST, EAST, NORTH, SOUTH.
  final String side;

  /// Port index within its side (for FIXED_ORDER constraint).
  final int index;

  /// Child ports (for hierarchical/bus ports).
  final List<ElkPort> children;

  /// X coordinate in pixels.
  double? x;

  /// Y coordinate in pixels.
  double? y;

  /// Width in pixels (for hierarchical ports).
  double? width;

  /// Height in pixels (for hierarchical ports).
  double? height;

  /// Constructor for `ElkPort`.
  ElkPort({
    required this.id,
    required this.hwMeta,
    required this.direction,
    required this.side,
    this.index = 0,
    List<ElkPort>? children,
    this.x,
    this.y,
    this.width,
    this.height,
  }) : children = children ?? [];

  /// Create a copy with updated fields.
  ElkPort copyWith({
    String? id,
    HwMeta? hwMeta,
    String? direction,
    String? side,
    int? index,
    List<ElkPort>? children,
    double? x,
    double? y,
    double? width,
    double? height,
  }) =>
      ElkPort(
        id: id ?? this.id,
        hwMeta: hwMeta ?? this.hwMeta,
        direction: direction ?? this.direction,
        side: side ?? this.side,
        index: index ?? this.index,
        children: children ?? this.children,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );

  /// Convert to JSON map for JS serialization.
  Map<String, dynamic> toJson() => {
        'id': id,
        'hwMeta': hwMeta.toJson(),
        'direction': direction,
        'properties': {'side': side, 'index': index},
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };

  @override
  String toString() => 'ElkPort(id: $id, name: ${hwMeta.name}, '
      'side: $side, direction: $direction)';
}

/// Combined net representation wrapping a hierarchy `SignalOccurrence`.
///
/// This class merges the former `Hyperedge` and `ElkEdge` roles:
///
/// * **Connectivity** — multi-source/multi-target `(nodeId, portIndex)` tuples
///   (one net may fan out to several ports).
/// * **Semantics** — wraps a `SignalOccurrence` from `rohd_hierarchy` so name/width/type
///   are never duplicated.
/// * **Serialization** — `toElkEdges` expands the hyperedge into one or more
///   ELK JSON edge maps on-the-fly during `LayoutNode.toJson`; no separate
///   `ElkEdge` objects are stored.
class LayoutHyperedge {
  /// Unique hyperedge ID.
  final String id;

  /// Reference to the hierarchy signal (single source of truth for name/width).
  final SignalOccurrence signal;

  /// Source connections: (nodeId, portIndex) pairs.
  final List<(String nodeId, int portIndex)> sources;

  /// Target connections: (nodeId, portIndex) pairs.
  final List<(String nodeId, int portIndex)> targets;

  /// Constructor for `LayoutHyperedge`.
  LayoutHyperedge({
    required this.id,
    required this.signal,
    required this.sources,
    required this.targets,
  });

  /// Delegate signal name (for display and search).
  String get name => signal.name;

  /// Delegate signal bit-width (for bus rendering).
  int get width => signal.width;

  /// Whether this is a 1:1 hyperedge (single source, single target).
  bool get isOneToOne => sources.length == 1 && targets.length == 1;

  /// Whether this is an N:M hyperedge (multiple sources or targets).
  bool get isNtoM => sources.length > 1 || targets.length > 1;

  /// Generate ELK JSON edge maps for this hyperedge.
  ///
  /// For a 1:1 edge returns a single map keyed on `id`.
  /// For N:M, returns the cartesian product with deterministic sub-IDs
  /// of the form `"${id}_$n"`.
  ///
  /// `resolvePort` maps `(nodeId, portIndex)` to the temporary string port
  /// ID that ELK expects, supplied by `LayoutNode.toJson`.
  List<Map<String, dynamic>> toElkEdges(
    String Function(String nodeId, int portIndex) resolvePort,
  ) {
    final hwMeta = <String, dynamic>{
      'name': name,
      if (width > 1) 'signalWidth': width,
      if (signal.address != null) 'addr': signal.address!.path,
    };

    // Tell ELK to allocate more routing space for multi-bit buses.
    final edgeProps = <String, dynamic>{
      if (width > 1) 'org.eclipse.elk.edge.thickness': 3,
    };

    if (isOneToOne) {
      final (src, srcPort) = sources.first;
      final (tgt, tgtPort) = targets.first;
      return [
        {
          'id': id,
          'source': src,
          'sourcePort': resolvePort(src, srcPort),
          'target': tgt,
          'targetPort': resolvePort(tgt, tgtPort),
          'hwMeta': hwMeta,
          if (edgeProps.isNotEmpty) 'properties': edgeProps,
        },
      ];
    }

    // N:M: cartesian product with deterministic sub-IDs.
    final edges = <Map<String, dynamic>>[];
    var sub = 0;
    for (final (src, srcPort) in sources) {
      for (final (tgt, tgtPort) in targets) {
        edges.add({
          'id': '${id}_$sub',
          'source': src,
          'sourcePort': resolvePort(src, srcPort),
          'target': tgt,
          'targetPort': resolvePort(tgt, tgtPort),
          'hwMeta': hwMeta,
          if (edgeProps.isNotEmpty) 'properties': edgeProps,
        });
        sub++;
      }
    }
    return edges;
  }

  /// Convert to JSON map for state persistence (hyperedge format).
  Map<String, dynamic> toJson() => {
        'id': id,
        'sources': sources.map((s) => [s.$1, s.$2]).toList(),
        'targets': targets.map((t) => [t.$1, t.$2]).toList(),
        'hwMeta': {
          'name': name,
          if (width > 1) 'signalWidth': width,
          if (signal.address != null) 'addr': signal.address!.path,
        },
      };

  @override
  String toString() => 'LayoutHyperedge(id: $id, name: $name, '
      '${sources.length}→${targets.length})';
}

/// Direction constants for ports.
class PortDirection {
  /// Port direction constant for input ports.
  static const input = 'INPUT';

  /// Port direction constant for output ports.
  static const output = 'OUTPUT';

  /// Port direction constant for bidirectional ports.
  static const inout = 'INOUT';

  /// Convert netlist direction to ELK direction.
  static String fromNetlist(String netlistDir) {
    switch (netlistDir.toLowerCase()) {
      case 'input':
        return input;
      case 'output':
        return output;
      case 'inout':
        return inout;
      default:
        return inout;
    }
  }
}

/// Side constants for ports.
class PortSide {
  /// Port side constant for west (left) ports.
  static const west = 'WEST';

  /// Port side constant for east (right) ports.
  static const east = 'EAST';

  /// Port side constant for north (top) ports.
  static const north = 'NORTH';

  /// Port side constant for south (bottom) ports.
  static const south = 'SOUTH';

  /// Get default side for a direction.
  static String fromDirection(String direction) {
    switch (direction) {
      case PortDirection.input:
        return west;
      case PortDirection.output:
        return east;
      case PortDirection.inout:
        return west;
      default:
        return west;
    }
  }
}

/// Size calculation constants for schematic layout.
class SchematicSizeConstants {
  /// Character width at the base font size (`charHeight` = 13).
  static const charWidth = 7.55;

  /// Base character height (matches default monospace metric).
  static const charHeight = 13.0;

  /// Font size actually used when rendering labels on the canvas.
  static const textFontSize = 10.0;

  /// Effective character width at the rendered `textFontSize`.
  ///
  /// Labels on the canvas are drawn at `textFontSize`, which is smaller than
  /// `charHeight`. This constant gives the true pixel-width per character so
  /// that layout calculations match the visual output.
  static const renderedCharWidth = charWidth * textFontSize / charHeight;

  /// Height per port.
  static const portHeight = 20.0;

  /// Port pin size `width, height`.
  static const portPinSize = (7.0, 13.0);

  /// Minimum node width.
  static const minNodeWidth = 30.0;

  /// Minimum node height.
  static const minNodeHeight = 20.0;

  /// Body text padding `top, right, bottom, left`.
  static const bodyTextPadding = (15.0, 10.0, 0.0, 10.0);

  /// Maximum body text size `width, height`.
  static const maxBodyTextSize = (400.0, 400.0);

  /// Padding for constant blocks `top, right, bottom, left`.
  /// Constants are small leaf nodes with just a label, so use minimal padding.
  /// About 1/8th the padding of bodyTextPadding to make them much smaller.
  static const constNodePadding = (0.5, 1.0, 0.0, 1.0);
}

/// Translates netlist cell types to operator names for rendering.
///
/// Translates netlist cell types to operator names for rendering.
/// Returns a tuple of (operatorName, cls) or null if not an operator.
class NetlistOperatorTranslator {
  /// Map from netlist cell type to (operator name, cls).
  static const _translations = <String, (String name, String cls)>{
    'Modulo': ('MOD', 'Operator'),
    'ReplicationOp': ('CONCAT', 'Operator'),
    r'$mux': ('MUX', 'Operator'),
    r'$pmux': ('MUX', 'Operator'),
    r'$gt': ('GT', 'Operator'),
    r'$lt': ('LT', 'Operator'),
    r'$ge': ('GE', 'Operator'),
    r'$le': ('LE', 'Operator'),
    r'$buf': ('BUF', 'Operator'),
    r'$not': ('NOT', 'Operator'),
    r'$logic_not': ('NOT', 'Operator'),
    r'$and': ('AND', 'Operator'),
    r'$logic_and': ('AND', 'Operator'),
    r'$or': ('OR', 'Operator'),
    r'$logic_or': ('OR', 'Operator'),
    r'$xor': ('XOR', 'Operator'),
    r'$xnor': ('NXOR', 'Operator'),
    r'$eq': ('EQ', 'Operator'),
    r'$ne': ('NE', 'Operator'),
    r'$add': ('ADD', 'Operator'),
    r'$sub': ('SUB', 'Operator'),
    r'$mul': ('MUL', 'Operator'),
    r'$div': ('DIV', 'Operator'),
    r'$mod': ('MOD', 'Operator'),
    r'$slice': ('SLICE', 'Operator'),
    r'$concat': ('CONCAT', 'Operator'),
    r'$struct_unpack': ('STRUCT_UNPACK', 'Operator'),
    r'$struct_pack': ('STRUCT_PACK', 'Operator'),
    r'$dff': ('FF', 'Operator'),
    r'$dffe': ('FF', 'Operator'),
    r'$sdff': ('FF', 'Operator'),
    r'$sdffe': ('FF', 'Operator'),
    r'$adff': ('FF', 'Operator'),
    r'$adffe': ('FF', 'Operator'),
    r'$aldff': ('FF', 'Operator'),
    r'$aldffe': ('FF', 'Operator'),
    r'$shift': ('SHIFT', 'Operator'),
    r'$shiftx': ('SHIFT', 'Operator'),
    r'$shl': ('SHL', 'Operator'),
    r'$sshl': ('SHL', 'Operator'),
    r'$shr': ('SHR', 'Operator'),
    r'$sshr': ('SHR', 'Operator'),
    r'$reduce_and': ('AND', 'Operator'),
    r'$reduce_or': ('OR', 'Operator'),
    r'$reduce_xor': ('XOR', 'Operator'),
    r'$reduce_xnor': ('NXOR', 'Operator'),
    r'$reduce_bool': ('NOT', 'Operator'),
    r'$nand': ('NAND', 'Operator'),
    r'$nor': ('NOR', 'Operator'),
    r'$pos': ('ADD', 'Operator'),
    r'$neg': ('SUB', 'Operator'),
    r'$tribuf': ('TRIBUF', 'Operator'),
  };

  /// Translate a netlist cell type to operator name and cls.
  ///
  /// Parameters are used for DLATCH variants.
  static (String name, String cls)? translate(
    String cellType, [
    Map<String, dynamic>? parameters,
  ]) {
    if (cellType == r'$dlatch') {
      final en = _isOne(parameters?['EN_POLARITY']) ? 1 : 0;
      return ('DLATCH_en$en', 'Operator');
    }

    if (parameters?.containsKey('CLK_POLARITY') ?? false) {
      final clk = _isOne(parameters?['CLK_POLARITY']) ? 1 : 0;
      final en = _isOne(parameters?['EN_POLARITY']) ? 1 : 0;
      final rstParameter =
          cellType.startsWith(r'$adff') ? 'ARST_POLARITY' : 'SRST_POLARITY';
      final rst = _isOne(parameters?[rstParameter]) ? 1 : 0;
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

    // Check direct translation table
    return _translations[cellType];
  }

  static bool _isOne(Object? value) =>
      value == true || value == 1 || value?.toString() == '1';

  /// Check if a cell type is an operator.
  static bool isOperator(String cellType) => cellType.startsWith(r'$');
}

// NEW CONSOLIDATED SCHEMA: LayoutNode and LayoutEdge
// ============================================================================
//
// These classes implement the consolidated schema design that uses
// HierarchyService as the single source of truth for semantic information
// (names, hierarchy, port definitions, signal definitions), while keeping
// layout-specific metadata (position, size, visibility) separate.
//
// This eliminates duplication of ElkNode/HierarchyOccurrence and Hyperedge/SignalOccurrence
// while maintaining compatibility with the ELK layout engine.

/// Layout-specific metadata wrapped around a HierarchyOccurrence.
///
/// This class represents a node in the schematic layout WITH a reference to
/// the semantic HierarchyOccurrence, avoiding duplication of names/hierarchy info.
///
/// The HierarchyOccurrence is the single source of truth for:
/// - Node name and type
/// - Parent-child hierarchical relationships
/// - Port definitions (rohd_hierarchy Port)
/// - Internal signal definitions (rohd_hierarchy SignalOccurrence)
///
/// This LayoutNode adds ELK layout and display data:
/// - Position, size, padding (layout results from ELK)
/// - ELK ports with side/index (for FIXED_ORDER port constraints)
/// - ELK layout properties
/// - Display metadata (hwMeta: cls, bodyText, instanceName)
/// - Hyperedges (connectivity within this node's scope)
/// - Visibility state (expanded vs collapsed)
/// - Partial expansion tracking (SHIFT+click)
class LayoutNode {
  /// Reference to the semantic source of truth (never duplicated elsewhere).
  ///
  /// All semantic information (names, hierarchy, ports, signals) comes
  /// from this HierarchyOccurrence. Do NOT duplicate fields here.
  final HierarchyOccurrence occurrence;

  /// Address-based ID used as the key in `SchematicGraph.nodeMap`.
  ///
  /// For netlist-derived nodes this is the dot-separated address path
  /// (e.g. "0", "0.1").  Set at construction time and never changed.
  String? _id;

  /// Hardware metadata for display (cls, bodyText, instanceName).
  ///
  /// Name is delegated to `occurrence` — hwMeta.name is kept in sync
  /// but the hierarchy node is the source of truth for identity.
  HwMeta hwMeta;

  /// ELK layout properties (e.g. portConstraints, mergeEdges).
  final Map<String, dynamic> properties;

  /// ELK ports with layout-specific data (side, index, position).
  ///
  /// Hierarchy Port has direction but not side/index/position.
  /// ELK needs these for FIXED_ORDER port constraints and rendering.
  final List<ElkPort> elkPorts;

  /// Visible layout children nodes (for expanded state).
  List<LayoutNode> children;

  /// Hidden layout children (for collapsed state).
  List<LayoutNode>? hiddenChildren;

  /// Hyperedges: one per SignalOccurrence net in this node's scope.
  ///
  /// Expanded on-the-fly to ELK JSON edges during `toJson`.
  List<LayoutHyperedge>? hyperedges;

  /// Parent reference in the layout tree.
  LayoutNode? parent;

  /// Layout result X position in pixels.
  double? x;

  /// Layout result Y position in pixels.
  double? y;

  /// Layout result width in pixels.
  double? width;

  /// Layout result height in pixels.
  double? height;

  /// Layout padding.
  ElkPadding? padding;

  /// Link to corresponding HierarchyOccurrence ID (optional, for bridge code).
  String? hierarchyNodeId;

  /// Partial expansion state from SHIFT+click on a port.
  ///
  /// When non-null and non-empty, this node is partially expanded:
  /// only the children whose IDs (from hierarchy) are in this set
  /// are visible. Remaining hidden children stay collapsed.
  Set<String>? partialChildIds;

  /// IDs of signals to treat as visible during partial expansion.
  ///
  /// Only the signals whose IDs are in this set are included as
  /// visible edges when the node is partially expanded.
  Set<String>? partialHyperedgeIds;

  /// Port IDs that have internal connectivity in a slim module.
  ///
  /// Set by the adapter when a slim module's ports carry
  /// `"connected": true`.  Emitted as `_connectedPorts` in the ELK
  /// JSON so that `ElkLayoutExtractor` can show interior port markers
  /// without full edge data.
  Set<String>? slimConnectedPortIds;

  /// Cached port→hyperedge index: maps a port index (position in `elkPorts`)
  /// to the list of hyperedges that reference it (as source or target).
  Map<int, List<LayoutHyperedge>>? _portHyperedgeIndex;

  /// Returns the port→hyperedge index for this node, building it on first
  /// access.
  Map<int, List<LayoutHyperedge>> get portHyperedgeIndex {
    if (_portHyperedgeIndex != null) {
      return _portHyperedgeIndex!;
    }
    final idx = <int, List<LayoutHyperedge>>{};
    final hes = hyperedges;
    if (hes != null) {
      for (final h in hes) {
        for (final (nId, pIdx) in h.sources) {
          if (nId == id) {
            (idx[pIdx] ??= []).add(h);
          }
        }
        for (final (nId, pIdx) in h.targets) {
          if (nId == id) {
            (idx[pIdx] ??= []).add(h);
          }
        }
      }
    }
    _portHyperedgeIndex = idx;
    return idx;
  }

  /// Invalidate the cached port→hyperedge index (e.g. after modifying
  /// `hyperedges`).
  void invalidatePortIndex() {
    _portHyperedgeIndex = null;
  }

  /// Lazily-built port→hyperedge cache.  The port-ID-to-index map has been
  /// eliminated: port IDs are now "nodeId:portIndex" so the index can be
  /// parsed directly from the string.

  /// Return the index of the port whose ID equals `portId`, or -1 if not found.
  ///
  /// Scans `elkPorts` by ID — works for any ID format (address-based,
  /// sequential integers, or opaque strings from external sources).
  int portIndexById(String portId) =>
      elkPorts.indexWhere((p) => p.id == portId);

  /// Return the ID of the port at `portIndex` in `elkPorts`.
  ///
  /// Falls back to a synthesized string only when `portIndex` is out of range
  /// (defensive — should not happen with well-formed data).
  String portIdAt(int portIndex) =>
      portIndex >= 0 && portIndex < elkPorts.length
          ? elkPorts[portIndex].id
          : '$id:$portIndex';

  /// Resolve a string port ID to (ownerNodeId, portIndex) by searching
  /// this node's ports first, then all children and hidden children.
  (String nodeId, int portIndex)? resolvePortId(String portId) {
    final selfIdx = portIndexById(portId);
    if (selfIdx >= 0) {
      return (id, selfIdx);
    }
    for (final child in children) {
      final idx = child.portIndexById(portId);
      if (idx >= 0) {
        return (child.id, idx);
      }
    }
    if (hiddenChildren != null) {
      for (final child in hiddenChildren!) {
        final idx = child.portIndexById(portId);
        if (idx >= 0) {
          return (child.id, idx);
        }
      }
    }
    return null;
  }

  /// Constructor for `LayoutNode`.
  LayoutNode({
    required this.occurrence,
    String? id,
    HwMeta? hwMeta,
    Map<String, dynamic>? properties,
    List<ElkPort>? elkPorts,
    List<LayoutNode>? children,
    this.hiddenChildren,
    this.hyperedges,
    this.parent,
    this.x,
    this.y,
    this.width,
    this.height,
    this.padding,
    this.hierarchyNodeId,
    this.partialChildIds,
    this.partialHyperedgeIds,
  })  : _id = id,
        hwMeta = hwMeta ?? HwMeta(name: occurrence.name),
        properties = properties ??
            {
              'org.eclipse.elk.portConstraints': 'FIXED_ORDER',
              'org.eclipse.elk.layered.mergeEdges': 1,
            },
        elkPorts = elkPorts ?? [],
        children = children ?? [];

  /// Delegate ID to stored address or hierarchy node path.
  String get id => _id ?? occurrence.path();

  /// Sets the address-based ID (used by `_makeNode` in the netlist adapter).
  set id(String value) => _id = value;

  /// Delegate name to hierarchy node (single source of truth).
  String get name => occurrence.name;

  /// Delegate definition to hierarchy node.
  String? get definition => occurrence.definition;

  /// Get ports from hierarchy's signals (no duplication).
  List<SignalOccurrence> get ports => occurrence.ports;

  /// Get internal signals from hierarchy (excludes ports).
  List<SignalOccurrence> get signals =>
      occurrence.signals.where((s) => !s.isPort).toList();

  /// Whether this node has hidden children (is expandable).
  bool get isExpandable => hiddenChildren != null && hiddenChildren!.isNotEmpty;

  /// Whether this node is currently expanded (visible children present).
  bool get isExpanded => children.isNotEmpty;

  /// Whether this node is partial expanded via SHIFT+click.
  bool get isPartiallyExpanded =>
      partialChildIds != null && partialChildIds!.isNotEmpty;

  /// Toggle expansion state (same as ElkNode).
  ///
  /// Moves children between `children` and `hiddenChildren`.
  /// Also clears any partial expansion state on this node and descendants.
  void toggle() {
    if (isExpandable) {
      // Expand: move hidden children to visible
      children = hiddenChildren!;
      hiddenChildren = null;
    } else if (isExpanded) {
      // Collapse: move visible children to hidden
      clearDescendantMarks(children);
      hiddenChildren = children;
      children = [];
    }
    // Clear partial expansion on any full toggle
    partialChildIds = null;
    partialHyperedgeIds = null;
  }

  /// Partially expand this node to reveal non-primitive children (blocks-only).
  ///
  /// Marks non-primitive children and their connecting edges as visible
  /// without doing a full expand. Returns true if new children were revealed.
  /// This mirrors ElkNode behavior but operates on the LayoutNode tree.
  ///
  /// Non-primitive nodes are those that have their own children (submodules),
  /// whereas primitive nodes are leaf gates/operators.
  bool expandNonPrimitivesPartial() {
    if (hiddenChildren == null || hiddenChildren!.isEmpty) {
      return false;
    }

    // Find non-primitive hidden children (have children themselves)
    final nonPrimitiveIds = <String>{};
    for (final child in hiddenChildren!) {
      if (child.children.isNotEmpty || child.isExpandable) {
        nonPrimitiveIds.add(child.id);
      }
    }

    if (nonPrimitiveIds.isEmpty) {
      return false;
    }

    // Check if already visible (idempotent)
    final existingChildren = partialChildIds ?? {};
    if (existingChildren.containsAll(nonPrimitiveIds)) {
      return false; // Already visible
    }

    // Additive: merge into existing partial set
    partialChildIds = {...existingChildren, ...nonPrimitiveIds};
    // Also mark edges to these children as visible (same as blocks-only)
    // For now, reveal all edges (could be optimized to show only edges
    // connecting to revealed children)
    partialHyperedgeIds ??= {};

    return true;
  }

  /// Collapse partial expansion back to fully hidden state.
  ///
  /// Clears `partialChildIds` and `partialHyperedgeIds`. Returns true if
  /// the node was partially expanded.
  bool collapsePartialExpansion() {
    if (!isPartiallyExpanded) {
      return false;
    }
    partialChildIds = null;
    partialHyperedgeIds = null;
    return true;
  }

  /// Temporarily move partial children from `hiddenChildren` to `children`.
  ///
  /// Used during layout serialization to show partial children as visible
  /// to the layout engine. Call `restorePartialExpansion` after serialization.
  void applyPartialExpansion() {
    if (isPartiallyExpanded &&
        hiddenChildren != null &&
        hiddenChildren!.isNotEmpty) {
      final toReveal = <LayoutNode>[];
      hiddenChildren!.removeWhere((child) {
        if (partialChildIds!.contains(child.id)) {
          toReveal.add(child);
          return true;
        }
        return false;
      });
      children.addAll(toReveal);
    }

    // Recurse into visible children (which may themselves be partially
    // expanded) and hidden children (which may have been partially
    // expanded before being hidden)
    for (final child in children) {
      child.applyPartialExpansion();
    }
    for (final child in hiddenChildren ?? <LayoutNode>[]) {
      child.applyPartialExpansion();
    }
  }

  /// Reverse the effect of `applyPartialExpansion`.
  ///
  /// Moves partial children back from `children` to `hiddenChildren`.
  void restorePartialExpansion() {
    if (isPartiallyExpanded) {
      final toHide = <LayoutNode>[];
      children.removeWhere((child) {
        if (partialChildIds!.contains(child.id)) {
          toHide.add(child);
          return true;
        }
        return false;
      });
      hiddenChildren ??= [];
      hiddenChildren!.addAll(toHide);
    }

    // Recurse into all children
    for (final child in children) {
      child.restorePartialExpansion();
    }
    if (hiddenChildren != null) {
      for (final child in hiddenChildren!) {
        child.restorePartialExpansion();
      }
    }
  }

  /// Recursively clear partial marks on all descendants.
  static void clearDescendantMarks(List<LayoutNode> nodes) {
    for (final node in nodes) {
      node
        ..partialChildIds = null
        ..partialHyperedgeIds = null;
      // Recurse into visible children
      if (node.children.isNotEmpty) {
        clearDescendantMarks(node.children);
      }
      // Also recurse into hidden children
      if (node.hiddenChildren != null && node.hiddenChildren!.isNotEmpty) {
        clearDescendantMarks(node.hiddenChildren!);
      }
    }
  }

  /// Get all descendant nodes (BFS traversal).
  Iterable<LayoutNode> get descendants sync* {
    final queue = <LayoutNode>[...children];
    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      yield node;
      queue.addAll(node.children);
    }
  }

  /// Get all ELK ports including nested children's ports (flattened).
  Iterable<ElkPort> get allPorts sync* {
    for (final port in elkPorts) {
      yield port;
      yield* _flattenPorts(port.children);
    }
  }

  Iterable<ElkPort> _flattenPorts(List<ElkPort> ports) sync* {
    for (final port in ports) {
      yield port;
      yield* _flattenPorts(port.children);
    }
  }

  /// Convert to JSON map for ELK JS serialization.
  Map<String, dynamic> toJson() {
    // Build a local resolver: nodeId → (portIndex → portId string).
    String resolvePort(String nodeId, int portIndex) {
      if (nodeId == id) {
        return portIdAt(portIndex);
      }
      for (final child in children) {
        if (child.id == nodeId) {
          return child.portIdAt(portIndex);
        }
      }
      if (hiddenChildren != null) {
        for (final child in hiddenChildren!) {
          if (child.id == nodeId) {
            return child.portIdAt(portIndex);
          }
        }
      }
      return portIndex.toString(); // fallback
    }

    // Build edge JSON from hyperedges on-the-fly (expansion + visibility).
    final visibleEdgeJson = <Map<String, dynamic>>[];
    final hiddenEdgeJson = <Map<String, dynamic>>[];
    // Self-referencing edges (port-to-port passthrough) that need dummy
    // split nodes for ELK routing.  Deduplicated by (srcPort, tgtPort).
    final selfEdgesByPortPair = <String, Map<String, dynamic>>{};
    if (hyperedges != null) {
      final visibleIds = <String>{id};
      for (final child in children) {
        visibleIds.add(child.id);
      }
      final allowedIds = isPartiallyExpanded ? partialHyperedgeIds : null;
      for (final h in hyperedges!) {
        final allowed = allowedIds == null || allowedIds.contains(h.id);
        for (final edgeMap in h.toElkEdges(resolvePort)) {
          final srcNode = edgeMap['source'] as String;
          final tgtNode = edgeMap['target'] as String;
          final isSelfEdge = srcNode == id && tgtNode == id;
          if (isSelfEdge) {
            if (allowed && children.isNotEmpty) {
              // Deduplicate by port pair — multi-bit nets produce identical
              // self-edges that should be a single routed wire.
              final key = '${edgeMap['sourcePort']}|${edgeMap['targetPort']}';
              selfEdgesByPortPair.putIfAbsent(key, () => edgeMap);
            } else {
              hiddenEdgeJson.add(edgeMap);
            }
            continue;
          }
          final bothVisible =
              visibleIds.contains(srcNode) && visibleIds.contains(tgtNode);
          if (allowed && bothVisible) {
            visibleEdgeJson.add(edgeMap);
          } else {
            hiddenEdgeJson.add(edgeMap);
          }
        }
      }
    }

    // Split each unique self-edge through a zero-size dummy child so ELK
    // routes input→dummy and dummy→output inside the compound node.
    final dummyChildren = <Map<String, dynamic>>[];
    var dummyIdx = 0;
    for (final edge in selfEdgesByPortPair.values) {
      final edgeId = edge['id'] as String;
      final dummyId = '${id}_pt$dummyIdx';
      final dummyInPort = '$dummyId:0';
      final dummyOutPort = '$dummyId:1';
      dummyIdx++;

      dummyChildren.add({
        'id': dummyId,
        'hwMeta': {'name': '', '_passthrough': true},
        'properties': {'org.eclipse.elk.portConstraints': 'FIXED_ORDER'},
        'ports': [
          {
            'id': dummyInPort,
            'hwMeta': {'name': ''},
            'direction': 'INPUT',
            'properties': {'side': 'WEST', 'index': 0},
          },
          {
            'id': dummyOutPort,
            'hwMeta': {'name': ''},
            'direction': 'OUTPUT',
            'properties': {'side': 'EAST', 'index': 1},
          },
        ],
        'width': 0,
        'height': 0,
      });

      visibleEdgeJson
        ..add({
          'id': '${edgeId}_a',
          'source': id,
          'sourcePort': edge['sourcePort'],
          'target': dummyId,
          'targetPort': dummyInPort,
          'hwMeta': edge['hwMeta'],
          '_passthroughGroup': edgeId,
        })
        ..add({
          'id': '${edgeId}_b',
          'source': dummyId,
          'sourcePort': dummyOutPort,
          'target': id,
          'targetPort': edge['targetPort'],
          'hwMeta': edge['hwMeta'],
          '_passthroughGroup': edgeId,
        });
    }

    // Assemble children list including dummy passthrough nodes.
    final childrenJson = children.map((c) => c.toJson()).toList()
      ..addAll(dummyChildren);

    return {
      'id': id,
      'hwMeta': hwMeta.toJson(),
      'properties': properties,
      if (hierarchyNodeId != null) 'hierarchyNodeId': hierarchyNodeId,
      if (elkPorts.isNotEmpty)
        'ports': elkPorts.map((p) => p.toJson()).toList(),
      if (childrenJson.isNotEmpty) 'children': childrenJson,
      if (hiddenChildren != null && hiddenChildren!.isNotEmpty)
        '_children': hiddenChildren!.map((c) => c.toJson()).toList(),
      if (visibleEdgeJson.isNotEmpty) 'edges': visibleEdgeJson,
      if (hiddenEdgeJson.isNotEmpty) '_edges': hiddenEdgeJson,
      if (isPartiallyExpanded) 'isPartiallyExpanded': true,
      if (slimConnectedPortIds != null && slimConnectedPortIds!.isNotEmpty)
        '_connectedPorts': slimConnectedPortIds!.toList(),
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (padding != null) 'padding': padding!.toJson(),
    };
  }

  @override
  String toString() => 'LayoutNode(id: $id, name: ${hwMeta.name}, '
      'ports: ${elkPorts.length}, children: ${children.length})';
}
