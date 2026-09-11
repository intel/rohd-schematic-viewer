// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_models.dart
// Data models for schematic layout.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Result of the schematic layout computation.
class SchematicLayoutResult {
  /// List of schematic instances (nodes).
  final List<SchematicInstanceData> instances;

  /// List of schematic ports.
  final List<SchematicPortData> ports;

  /// List of schematic edges (wires).
  final List<SchematicEdgeData> edges;

  /// Width of the layout.
  final double width;

  /// Height of the layout.
  final double height;

  /// Optional error message if layout failed.
  final String? error;

  /// Port IDs that have a hidden parent-scope wire (wire exists but is not
  /// currently visible).  Ports in this set should show an exterior marker.
  final Set<String> exteriorHiddenPortIds;

  /// Port IDs that have a hidden module-internal wire (wire exists but is
  /// not currently visible).  Ports in this set should show an interior marker.
  final Set<String> interiorHiddenPortIds;

  /// Port IDs on visible children of expanded nodes that have no
  /// parent-scope edge referencing them.  Exterior outline-only marker.
  final Set<String> unconnectedPortIds;

  /// Port IDs on expanded scope-nodes whose interior has no edge
  /// referencing them.  Interior outline-only marker.
  final Set<String> interiorUnconnectedPortIds;

  /// Create a new [SchematicLayoutResult].
  SchematicLayoutResult({
    required this.instances,
    required this.ports,
    required this.edges,
    required this.width,
    required this.height,
    this.error,
    Set<String>? exteriorHiddenPortIds,
    Set<String>? interiorHiddenPortIds,
    Set<String>? unconnectedPortIds,
    Set<String>? interiorUnconnectedPortIds,
  })  : exteriorHiddenPortIds = exteriorHiddenPortIds ?? const {},
        interiorHiddenPortIds = interiorHiddenPortIds ?? const {},
        unconnectedPortIds = unconnectedPortIds ?? const {},
        interiorUnconnectedPortIds = interiorUnconnectedPortIds ?? const {};

  /// Create an empty [SchematicLayoutResult].
  factory SchematicLayoutResult.empty() => SchematicLayoutResult(
        instances: [],
        ports: [],
        edges: [],
        width: 800,
        height: 600,
      );

  /// Whether the layout has an error.
  bool get hasError => error != null;

  /// Cached map from child instance ID to parent instance ID.
  ///
  /// Built lazily from [instances] children lists. Root instances map to null.
  late final Map<String, String?> parentMap = _buildParentMap();

  Map<String, String?> _buildParentMap() {
    final map = <String, String?>{};
    for (final instance in instances) {
      for (final childId in instance.children) {
        map[childId] = instance.id;
      }
      map.putIfAbsent(instance.id, () => null);
    }
    return map;
  }
}

/// Data for a schematic instance (visual representation of a module instance/cell).
class SchematicInstanceData {
  /// Unique identifier for this instance within the schematic.
  final String id;

  /// X-coordinate of the instance's top-left corner in the schematic layout.
  final double x;

  /// Y-coordinate of the instance's top-left corner in the schematic layout.
  final double y;

  /// Width of the instance's bounding box.
  final double width;

  /// Height of the instance's bounding box.
  final double height;

  /// Display name/label for this instance (e.g., module instance name).
  final String name;

  /// Original cell instance name from the netlist.
  ///
  /// For operator/primitive cells the display [name] is the translated
  /// operator symbol (e.g. "MUX") while this field holds the Yosys cell
  /// instance name (e.g. "mux_0").  Null when [name] already IS the
  /// instance name.
  final String? instanceName;

  /// Classification or type of this instance (e.g., 'Operator', 'Module').
  final String cls;

  /// Multi-line text content displayed inside the instance box.
  final String bodyText;

  /// True if this instance represents an external I/O port/pad.
  final bool isExternalPort;

  /// CSS class(es) for styling (carries over from original schematic format).
  final String cssClass;

  /// List of child instance IDs contained within this hierarchical instance.
  final List<String> children;

  /// Width allocated for port label text rendering; null if not specified.
  final double? portLabelWidth;

  /// Whether this instance has expandable children (visible or hidden).
  final bool hasChildren;

  /// Whether this instance is currently expanded (children visible).
  final bool isExpanded;

  /// Whether this instance is partially expanded via port-click.
  ///
  /// A partially expanded instance has *some* of its hidden children
  /// revealed through incremental port expansion, but has not been
  /// fully toggled with the +/- button.
  final bool isPartiallyExpanded;

  /// Whether this instance has hidden children that themselves have children
  /// (i.e. non-primitive / submodule children that are not yet visible).
  ///
  /// When true, the "expand non-primitives" button should be shown.
  final bool hasHiddenNonPrimitiveChildren;

  /// Whether this instance has any non-primitive children (visible or hidden).
  ///
  /// When true on a fully expanded node, the "convert to blocks-only" button
  /// can be shown so the user can return to blocks-only view.
  final bool hasNonPrimitiveChildren;

  /// Full hierarchy path for this instance (e.g. "top/adder0").
  ///
  /// When available (Dart-first path), used by the canvas to construct
  /// fully-qualified signal paths for value lookups.  Null in the JS-first
  /// path where the hierarchy info isn't available in the layout.
  final String? hierarchyPath;

  /// Module type (definition) name for this instance, e.g.
  /// "FilterChannel_T3_W16_0" for an instance named "ch0".
  ///
  /// Distinct from [instanceName]/[name] (the netlist cell name). Source
  /// lookups (FLC/embedded trace) are keyed by module type, so this is
  /// used — not the instance name — when resolving cross-probe targets.
  /// Null for primitives and leaf nodes that have no module definition.
  final String? definitionName;

  /// Create a new [SchematicInstanceData].
  SchematicInstanceData({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.name,
    this.instanceName,
    this.cls = '',
    this.bodyText = '',
    this.isExternalPort = false,
    this.cssClass = '',
    this.children = const [],
    this.portLabelWidth,
    this.hasChildren = false,
    this.isExpanded = false,
    this.isPartiallyExpanded = false,
    this.hasHiddenNonPrimitiveChildren = false,
    this.hasNonPrimitiveChildren = false,
    this.hierarchyPath,
    this.definitionName,
  });

  /// Create a new [SchematicInstanceData] from JSON data.
  factory SchematicInstanceData.fromJson(Map<String, dynamic> json) {
    final childList = <String>[];
    if (json['children'] is List) {
      for (final c in json['children'] as List) {
        if (c != null) {
          childList.add(c.toString());
        }
      }
    }

    return SchematicInstanceData(
      id: json['id']?.toString() ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toDouble() ?? 50.0,
      height: (json['height'] as num?)?.toDouble() ?? 30.0,
      name: json['name']?.toString() ?? '',
      cls: json['cls']?.toString() ?? '',
      bodyText: json['bodyText']?.toString() ?? '',
      isExternalPort: json['isExternalPort'] == true,
      cssClass: json['cssClass']?.toString() ?? '',
      children: childList,
      portLabelWidth: (json['portLabelWidth'] as num?)?.toDouble(),
      hasChildren: json['hasChildren'] == true,
      isExpanded: json['isExpanded'] == true,
      isPartiallyExpanded: json['isPartiallyExpanded'] == true,
      hasHiddenNonPrimitiveChildren:
          json['hasHiddenNonPrimitiveChildren'] == true,
      hasNonPrimitiveChildren: json['hasNonPrimitiveChildren'] == true,
      hierarchyPath: json['hierarchyPath']?.toString(),
      definitionName: json['definitionName']?.toString(),
    );
  }
}

/// Data for a schematic port (I/O connection point on an instance).
class SchematicPortData {
  /// Unique identifier for this port within the schematic.
  final String id;

  /// ID of the instance this port belongs to (parent container).
  final String instanceId;

  /// X-coordinate of the port's position in the schematic layout.
  final double x;

  /// Y-coordinate of the port's position in the schematic layout.
  final double y;

  /// Width of the port's visual representation (marker and label area).
  final double width;

  /// Height of the port's visual representation (marker and label area).
  final double height;

  /// Display name/label for the port (e.g., "clk", "data_in", "reset").
  final String name;

  /// SignalOccurrence direction: 'INPUT', 'OUTPUT', or 'INOUT' (bidirectional).
  final String direction;

  /// Side of the parent instance where port appears: 'NORTH', 'SOUTH', 'EAST',
  /// 'WEST'.
  final String side;

  /// SignalOccurrence bit-width (e.g. 8 for an 8-bit bus). 1 = single bit wire.
  final int signalWidth;

  /// Create a new [SchematicPortData].
  SchematicPortData({
    required this.id,
    required this.instanceId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.name,
    this.direction = 'INOUT',
    this.side = 'EAST',
    this.signalWidth = 1,
  });

  /// Create a new [SchematicPortData] from JSON data.
  factory SchematicPortData.fromJson(Map<String, dynamic> json) =>
      SchematicPortData(
        id: json['id']?.toString() ?? '',
        instanceId: json['nodeId']?.toString() ?? '', // JS still uses 'nodeId'
        x: (json['x'] as num?)?.toDouble() ?? 0.0,
        y: (json['y'] as num?)?.toDouble() ?? 0.0,
        width: (json['width'] as num?)?.toDouble() ?? 10.0,
        height: (json['height'] as num?)?.toDouble() ?? 10.0,
        name: json['name']?.toString() ?? '',
        direction: json['direction']?.toString() ?? 'INOUT',
        side: json['side']?.toString() ?? 'EAST',
        signalWidth: (json['signalWidth'] as num?)?.toInt() ?? 1,
      );

  /// Whether this port is an input port.
  bool get isInput => direction == 'INPUT';

  /// Whether this port is an output port.
  bool get isOutput => direction == 'OUTPUT';

  /// Whether this port is a bidirectional (inout) port.
  bool get isInout => direction == 'INOUT';
}

/// A point in 2D space.
class SchematicPoint {
  /// X-coordinate.
  final double x;

  /// Y-coordinate.
  final double y;

  /// Create a new [SchematicPoint].
  SchematicPoint(this.x, this.y);

  /// Create a [SchematicPoint] from JSON data.
  factory SchematicPoint.fromJson(Map<String, dynamic> json) => SchematicPoint(
        (json['x'] as num?)?.toDouble() ?? 0.0,
        (json['y'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Data for a schematic edge (wire/connection).
class SchematicEdgeData {
  /// Unique identifier for this edge within the schematic.
  final String id;

  /// ID of the source instance that this edge originates from; null if
  /// unconnected.
  final String? source;

  /// ID of the source port on the source instance; null if edge is not
  /// port-to-port.
  final String? sourcePort;

  /// ID of the target instance that this edge connects to; null if unconnected.
  final String? target;

  /// ID of the target port on the target instance; null if edge is not
  /// port-to-port.
  final String? targetPort;

  /// Ordered list of 2D points defining the wire path through the schematic
  /// (polyline routing).
  final List<SchematicPoint> points;

  /// Optional list of junction points where multiple wires intersect or
  /// connect.
  final List<SchematicPoint>? junctionPoints;

  /// Optional list of drawable dots (connection points) along the wire path.
  ///
  /// Dots represent junction points where multiple wires meet or pass through:
  /// - Connection endpoints (source/target ports are NOT dots)
  /// - Points where 3+ wires converge
  /// - T-junction points (2 wires where at least one passes through)
  ///
  /// Exclusions (no dot):
  /// - Simple corners where 2 wires meet at both endpoints (no extent overlap)
  ///
  /// Rules for dot inclusion (from schematic_canvas.dart):
  /// 1. Always draw dot if 3+ edges are incident
  /// 2. For exactly 2 edges: draw dot only if extent overlap (T-junction)
  ///    - Draw if at least one edge is NOT just an endpoint
  ///    - Skip if both edges meet at both of their endpoints (simple corner)
  ///
  /// Benefits:
  /// - Can be culled based on wire bounding box for efficient rendering
  /// - Can be colored when wire is selected (orange when edges are selected)
  /// - Provides visual feedback for wire connections
  /// - Enables hit-testing for wire selection
  /// - Optional to support different rendering backends (some may not need
  ///   dots)
  final List<SchematicPoint>? dots;

  /// Display name/label for this edge (e.g., signal or net name).
  final String name;

  /// ID of parent hyper-edge (for grouping related edges into a single logical
  /// signal).
  final String? parentId;

  /// Name of parent hyper-edge (for grouping related edges into a single
  /// logical signal).
  final String parentName;

  /// CSS class(es) for styling (carries over from original schematic format).
  final String cssClass;

  /// SignalOccurrence bit-width (e.g. 8 for an 8-bit bus). 1 = single bit wire.
  final int signalWidth;

  /// Full hierarchy path of the scope (parent node) that owns this edge.
  ///
  /// For an edge inside the top module, this would be `"top"`.
  /// For an edge inside an expanded sub-module, e.g. `"top/adder0"`.
  /// Used to construct fully-qualified signal paths for value lookups.
  /// Null when not available.
  final String? scopeHierarchyPath;

  /// Hierarchy address for this signal (from rohd_hierarchy).
  ///
  /// When available, enables O(1) lookup in the snapshot by address
  /// instead of string path matching. Format: `[moduleIdx, ..., signalIdx]`.
  /// Null for computed/gate signals that don't originate from the hierarchy.
  final List<int>? addr;

  /// Create a new [SchematicEdgeData].
  SchematicEdgeData({
    required this.id,
    required this.points,
    this.source,
    this.sourcePort,
    this.target,
    this.targetPort,
    this.junctionPoints,
    this.dots,
    this.name = '',
    this.parentId,
    this.parentName = '',
    this.cssClass = '',
    this.signalWidth = 1,
    this.scopeHierarchyPath,
    this.addr,
  });

  /// Get the wire identifier for grouping - uses parentName, then parentId,
  /// then name, then id
  String get wireId {
    if (parentName.isNotEmpty) {
      return parentName;
    }
    if (parentId != null && parentId!.isNotEmpty) {
      return parentId!;
    }
    if (name.isNotEmpty) {
      return name;
    }
    return id;
  }

  /// Create a new [SchematicEdgeData] from JSON data.
  factory SchematicEdgeData.fromJson(Map<String, dynamic> json) {
    final pointList = <SchematicPoint>[];
    if (json['points'] is List) {
      for (final p in json['points'] as List) {
        if (p is Map<String, dynamic>) {
          pointList.add(SchematicPoint.fromJson(p));
        }
      }
    }

    List<SchematicPoint>? junctionList;
    if (json['junctionPoints'] is List) {
      junctionList = <SchematicPoint>[];
      for (final jp in json['junctionPoints'] as List) {
        if (jp is Map<String, dynamic>) {
          junctionList.add(SchematicPoint.fromJson(jp));
        }
      }
    }

    List<SchematicPoint>? dotsList;
    if (json['dots'] is List) {
      dotsList = <SchematicPoint>[];
      for (final dot in json['dots'] as List) {
        if (dot is Map<String, dynamic>) {
          dotsList.add(SchematicPoint.fromJson(dot));
        }
      }
    }

    return SchematicEdgeData(
      id: json['id']?.toString() ?? '',
      source: json['source']?.toString(),
      sourcePort: json['sourcePort']?.toString(),
      target: json['target']?.toString(),
      targetPort: json['targetPort']?.toString(),
      points: pointList,
      junctionPoints: junctionList,
      dots: dotsList,
      name: json['name']?.toString() ?? '',
      parentId: json['parentId']?.toString(),
      parentName: json['parentName']?.toString() ?? '',
      cssClass: json['cssClass']?.toString() ?? '',
      signalWidth: (json['signalWidth'] as num?)?.toInt() ?? 1,
      scopeHierarchyPath: json['scopeHierarchyPath']?.toString(),
    );
  }
}

/// Status of JavaScript dependencies.
class SchematicDependencyStatus {
  /// Whether ELK layout engine is loaded.
  final bool elk;

  /// Create a new [SchematicDependencyStatus].
  SchematicDependencyStatus({required this.elk});

  /// Whether all dependencies are loaded.
  bool get allLoaded => elk;

  /// Create a [SchematicDependencyStatus] from JSON data.
  factory SchematicDependencyStatus.fromJson(Map<String, dynamic> json) =>
      SchematicDependencyStatus(elk: json['elk'] == true);
}
