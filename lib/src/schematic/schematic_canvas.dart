// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_canvas.dart
// CustomPainter for drawing hardware schematics.
// Renders hardware schematics using Flutter CustomPaint.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show Timer, unawaited;
import 'dart:convert' show base64Encode;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/operator_shapes.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';
import 'package:rohd_schematic_viewer/src/schematic/wire_search_overlay.dart';
import 'package:rohd_schematic_viewer/src/services/layout_hierarchy_bridge.dart';
import 'package:rohd_schematic_viewer/src/services/services.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_webview_interop_stub.dart'
    if (dart.library.js_interop) '../services/vscode_webview_interop_web.dart'
    as vscode_interop;

bool _isDecimalDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

String? _radixLiteralDigits(
  String value,
  String radix,
  bool Function(int codeUnit) isAllowedDigit,
) {
  final apostrophe = value.indexOf("'");
  if (apostrophe <= 0 || apostrophe + 2 >= value.length) {
    return null;
  }
  for (var index = 0; index < apostrophe; index++) {
    if (!_isDecimalDigit(value.codeUnitAt(index))) {
      return null;
    }
  }
  if (value[apostrophe + 1] != radix) {
    return null;
  }
  final digits = value.substring(apostrophe + 2);
  for (final codeUnit in digits.codeUnits) {
    if (!isAllowedDigit(codeUnit)) {
      return null;
    }
  }
  return digits;
}

({String name, int? width, bool matched}) _parseTrailingBusWidth(String label) {
  if (!label.endsWith(')')) {
    return (name: label, width: null, matched: false);
  }
  var digitStart = label.length - 1;
  while (digitStart > 0 && _isDecimalDigit(label.codeUnitAt(digitStart - 1))) {
    digitStart--;
  }
  if (digitStart == label.length - 1 ||
      digitStart == 0 ||
      label[digitStart - 1] != '(') {
    return (name: label, width: null, matched: false);
  }
  var nameEnd = digitStart - 1;
  while (nameEnd > 0 && label.codeUnitAt(nameEnd - 1) == 0x20) {
    nameEnd--;
  }
  if (nameEnd == digitStart - 1) {
    return (name: label, width: null, matched: false);
  }
  return (
    name: label.substring(0, nameEnd),
    width: int.tryParse(label.substring(digitStart, label.length - 1)),
    matched: true,
  );
}

/// Extract raw hex digits from a formatted value.
///
/// Handles Verilog-style literals (e.g. "9'h1a" → "1a"), 0x-prefixed,
/// or bare hex strings.
String _extractRawHex(String formatted) {
  final hexDigits = _radixLiteralDigits(
    formatted,
    'h',
    (codeUnit) =>
        _isDecimalDigit(codeUnit) ||
        (codeUnit >= 0x41 && codeUnit <= 0x46) ||
        (codeUnit >= 0x61 && codeUnit <= 0x66) ||
        codeUnit == 0x78,
  );
  if (hexDigits != null) {
    return hexDigits;
  }
  // Binary literal → convert to hex.
  final binaryDigits = _radixLiteralDigits(
    formatted,
    'b',
    (codeUnit) =>
        codeUnit == 0x30 ||
        codeUnit == 0x31 ||
        codeUnit == 0x78 ||
        codeUnit == 0x7A,
  );
  if (binaryDigits != null) {
    final bits = binaryDigits;
    if (bits.contains('x')) {
      return 'x';
    }
    if (bits.contains('z')) {
      return 'z';
    }
    final big = BigInt.tryParse(bits, radix: 2);
    return big?.toRadixString(16) ?? formatted;
  }
  // Strip 0x prefix.
  if (formatted.startsWith('0x')) {
    return formatted.substring(2);
  }
  return formatted;
}

/// Color scheme for schematic visualization with light and dark theme support.
class SchematicColorScheme {
  /// Background color of the canvas.
  final Color background;

  /// Fill color for schematic node/block rectangles.
  final Color nodeBackground;

  /// Border/stroke color for schematic nodes.
  final Color nodeBorder;

  /// Text color for node labels and annotations.
  final Color nodeText;

  /// Stroke color for I/O port markers (arrows indicating input/output direction).
  final Color portStroke;

  /// Color for connection wires/edges between ports.
  final Color wire;

  /// Highlight color for selected or hovered wires.
  final Color wireHighlight;

  /// Fill color for external port nodes.
  final Color externalPortFill;

  /// Color for junction points where multiple wires intersect.
  final Color junctionPoint;

  /// Fill color for logic gate operator symbols (AND, OR, XOR, etc).
  final Color operatorFill;

  /// Fill color for constant-value nodes.
  final Color constantFill;

  /// The color scheme for our schematic viewer.
  const SchematicColorScheme({
    required this.background,
    required this.nodeBackground,
    required this.nodeBorder,
    required this.nodeText,
    required this.portStroke,
    required this.wire,
    required this.wireHighlight,
    required this.externalPortFill,
    required this.junctionPoint,
    required this.operatorFill,
    required this.constantFill,
  });

  /// Light theme - default color scheme
  static const light = SchematicColorScheme(
    // .node-0 { fill: white } - top level node is white
    background: Color(0xFFFFFFFF),
    // .node { fill: #e6ffff } - light cyan for child nodes
    nodeBackground: Color(0xFFE6FFFF),
    // .node { stroke: #D4D4D4 } - lighter gray so wires stand out
    nodeBorder: Color(0xFFD4D4D4),
    // .node text { fill: black }
    nodeText: Color(0xFF000000),
    // .port { stroke: #000 }
    portStroke: Color(0xFF000000),
    // .link { stroke: #000 } - black wires on white background
    wire: Color(0xFF000000),
    // .link-selected { stroke: orange }
    wireHighlight: Color(0xFFFFA500),
    // .node-external-port { fill: #BDBDBD }
    externalPortFill: Color(0xFFBDBDBD),
    // junction point circles - match wire color
    junctionPoint: Color(0xFF000000),
    // fill color for operator gates (mid-blue)
    operatorFill: Color(0xFF4F8AD9),
    // lighter blue for constants so black text stays readable
    constantFill: Color(0xFFBBD7FF),
  );

  /// Dark theme - matches VSCode dark theme (#1E1E1E background)
  static const dark = SchematicColorScheme(
    // VSCode dark background
    background: Color(0xFF1E1E1E),
    // Slightly lighter than background for child nodes
    nodeBackground: Color(0xFF2D2D30),
    // Medium gray borders - lighter than wires so signals stand out
    nodeBorder: Color(0xFF808080),
    // Light text
    nodeText: Color(0xFFD4D4D4),
    // Light port strokes - matches wires
    portStroke: Color(0xFFD4D4D4),
    // Light wires for dark background
    wire: Color(0xFFD4D4D4),
    // Bright orange highlight
    wireHighlight: Color(0xFFFFA500),
    // Light gray for external ports - matches wires
    externalPortFill: Color(0xFF6E6E6E),
    // Light junction points - matches wires
    junctionPoint: Color(0xFFD4D4D4),
    // Lighter blue for operator gates on dark background
    operatorFill: Color(0xFF569CD6),
    // Keep constants aligned with operator blocks in dark mode.
    constantFill: Color(0xFF569CD6),
  );

  /// Default theme (light)
  static const defaultScheme = light;
}

/// Schematic layout constants
class SchematicConstants {
  /// Port pin size `width, height`
  static const double portPinWidth = 7;

  /// Port pin height.
  static const double portPinHeight = 13;

  /// Character dimensions for monospace font
  /// Note: charWidth/Height are for LAYOUT calculations
  /// textFontSize is the actual rendered font size (smaller for visual balance)
  static const double charWidth = 7.55;

  /// Character height.
  static const double charHeight = 13;

  /// Text font size.
  static const double textFontSize = 10;

  /// Font size for constant nodes (smaller for visual balance).
  static const double constNodeFontSize = 7;

  /// Node corner radius (rx, ry in SVG)
  static const double nodeCornerRadius = 5;

  /// Node stroke width
  static const double nodeStrokeWidth = 1;

  /// Wire/link stroke width - increased for visibility
  static const double wireStrokeWidth = 1.5;

  /// Bus (multi-bit) wire stroke width
  static const double busWireStrokeWidth = 3;

  /// Port opacity
  static const double portOpacity = 0.6;

  /// Junction point radius
  static const double junctionRadius = 3;

  /// Corner rounding radius for orthogonal wire bends.
  static const double wireCornerRadius = 3;

  /// Bus width label threshold: label any segment longer than this many
  /// times the default primitive cell width (25px).
  static const double busLabelThresholdMultiplier = 25;

  /// Minimum segment length to label bus width (e.g. "bus`7:0`") - 25 * 25 =
  /// 625px.
  static const double busLabelMinSegmentLength =
      busLabelThresholdMultiplier * 25.0; // 625px
}

/// Icon types rendered inside expand/collapse control buttons.
enum _ControlIcon {
  /// Horizontal line (−) — collapse.
  minus,

  /// Cross (+) — expand.
  plus,

  /// Overlapping boxes (⊞) — blocks-only / non-primitive.
  blocks,
}

/// CustomPainter that draws the schematic.
class SchematicPainter extends CustomPainter {
  // DEBUG: Track paint frequency to diagnose flickering
  static int _paintCounter = 0;
  static DateTime? _lastPaintTime;
  static const bool _debugPaintFrequency = false; // Set to true to debug

  /// The schematic layout data to render.
  final SchematicLayoutResult layout;

  /// The color scheme to use for rendering.
  final SchematicColorScheme colorScheme;

  /// Name of wire to highlight (edges with this name)
  final String? highlightedWireName;

  /// The nodeId scope of the selected wire
  final String? selectedEdgeScope;

  /// Set of wire IDs that are currently selected (multi-select).
  final Set<String> selectedWireIds;

  /// Map from selected wire ID to its scope hierarchy path.
  /// Used to disambiguate identically-named wires in multi-instance blocks.
  final Map<String, String?> selectedWireScopePaths;

  /// Set of node/instance IDs currently selected (multi-select).
  final Set<String> selectedNodeIds;

  /// Node being highlighted (hovered or selected)
  final String? highlightedNodeId;

  /// Node being toggled - show flipped +/-
  final String? pendingToggleNodeId;

  /// View transform notifier (scale + offset) — updated directly by the
  /// widget state during zoom/pan to avoid rebuilding the widget tree.
  /// Passed as `repaint:` to CustomPaint so changes trigger paint only.
  final ValueNotifier<({double scale, Offset offset})> viewTransform;

  /// Callback to check if a node is in scope (provided by state)
  final bool Function(String? nodeId, String scopeId)? isNodeInScope;

  /// Notifier for the currently hovered boundary port.  Updated by the
  /// widget state's hover handler and merged into the `repaint:` listenable
  /// so that hover-state changes trigger `paint()` only — no widget rebuild.
  final ValueNotifier<({String? portId, bool isInterior})>
      hoveredBoundaryPortNotifier;

  /// When true, interactive-only decorations (expand/collapse icons) are
  /// suppressed so they don't appear in PNG snapshots.
  final ValueNotifier<bool> snapshotMode;

  /// Constructor for `SchematicPainter`.
  SchematicPainter({
    required this.layout,
    required this.viewTransform,
    required this.snapshotMode,
    required this.hoveredBoundaryPortNotifier,
    this.colorScheme = SchematicColorScheme.defaultScheme,
    this.highlightedWireName,
    this.selectedEdgeScope,
    this.selectedWireIds = const {},
    this.selectedWireScopePaths = const {},
    this.selectedNodeIds = const {},
    this.highlightedNodeId,
    this.pendingToggleNodeId,
    this.isNodeInScope,
  }) : super(
          repaint: Listenable.merge([
            viewTransform,
            hoveredBoundaryPortNotifier,
            snapshotMode,
          ]),
        );

  // Transient fields set at the start of each paint() call from viewTransform.
  double _currentScale = 1;
  Offset _currentOffset = Offset.zero;

  // ── Pre-computed lookup maps (built lazily, once per painter instance) ──

  late final Map<String, SchematicInstanceData> _instanceMap = {
    for (final inst in layout.instances) inst.id: inst,
  };

  late final Map<String, SchematicPortData> _portMap = {
    for (final port in layout.ports) port.id: port,
  };

  /// Whether `nodeId` should be drawn with highlight stroke.
  bool _isNodeHighlighted(String nodeId) =>
      nodeId == highlightedNodeId || selectedNodeIds.contains(nodeId);

  /// Port IDs that are connected to at least one visible edge.
  late final Set<String> _portsWithVisibleEdge = {
    for (final edge in layout.edges) ...[
      if (edge.sourcePort != null) edge.sourcePort!,
      if (edge.targetPort != null) edge.targetPort!,
    ],
  };

  // ── Cached Paint objects (depend only on colorScheme, which is final) ──

  late final Paint _bgPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.background;

  late final Paint _nodeFillPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.nodeBackground;

  late final Paint _nodeStrokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = SchematicConstants.nodeStrokeWidth
    ..color = colorScheme.nodeBorder;

  late final Paint _moduleBoundaryPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..color = colorScheme.nodeBorder;

  late final Paint _externalPortFillPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.externalPortFill;

  late final Paint _highlightStrokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..color = colorScheme.wireHighlight;

  late final Paint _operatorFillPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.operatorFill;

  late final Paint _constantFillPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.constantFill;

  late final Paint _operatorStrokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = colorScheme.operatorFill;

  late final Paint _wirePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = SchematicConstants.wireStrokeWidth
    ..color = colorScheme.wire;

  late final Paint _wireHighlightPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..color = colorScheme.wireHighlight;

  late final Paint _busHighlightPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = SchematicConstants.busWireStrokeWidth
    ..color = colorScheme.wireHighlight;

  late final Paint _junctionPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.junctionPoint;

  late final Paint _junctionHighlightPaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.wireHighlight;

  late final Paint _portStrokePaint = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.portStroke;

  /// Paint for exterior port markers drawn as outline only (no connection).
  late final Paint _portOutlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = colorScheme.portStroke;

  late final Paint _wireStubPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = SchematicConstants.wireStrokeWidth
    ..color = colorScheme.wire;

  late final Paint _busPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = SchematicConstants.busWireStrokeWidth
    ..color = colorScheme.wire;

  late final Paint _slashPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = colorScheme.operatorFill.withAlpha(160);

  // Expand-indicator paints (two variants: normal vs pending-toggle)
  // In light mode use a lighter gray so the white symbol stays legible
  // without the dark blob standing out against the white background.
  late final Paint _expandBgNormal = Paint()
    ..style = PaintingStyle.fill
    ..color = colorScheme.background.computeLuminance() > 0.5
        ? const Color(0xFFC0C0C0)
        : const Color(0xFF666666);

  late final Paint _expandBgPending = Paint()
    ..style = PaintingStyle.fill
    ..color = const Color(0xFFFF9800);

  // ── Paragraph text cache ──
  // Key: computed from text+fontSize+color+bold+center
  final Map<int, ui.Paragraph> _paragraphCache = {};

  // Cached viewport for text culling (set during paint)
  Rect _viewportRect = Rect.zero;

  // Map to store operator centering offsets calculated during _drawNodes()
  // Key: node.id, Value: (offsetX, offsetY) from node.x/y to centered position
  final Map<String, (double, double)> _operatorCenteringOffsets = {};

  // Returns centering offsets for a node, using cached values when available.
  // Falls back to recomputing from node size and intrinsic operator shape if
  // missing.
  (double, double) _getCenteringOffsetForNode(
    String nodeId,
    Map<String, SchematicInstanceData> instanceMap,
  ) {
    final cached = _operatorCenteringOffsets[nodeId];
    if (cached != null) {
      return cached;
    }
    // Operators are rendered at intrinsic size now; no centering offset needed.
    return (0.0, 0.0);
  }

  /// Check if a node is a descendant of (or equal to) the scope node

  /// Check if an edge is in the selected scope (hierarchical)
  bool _edgeInScope(SchematicEdgeData edge) {
    if (selectedEdgeScope == null) {
      return true; // No scope filter, show all edges
    }

    if (isNodeInScope == null) {
      return true; // No scope checking available, show all
    }

    String? sourceNodeId;
    String? targetNodeId;

    if (edge.sourcePort != null) {
      final sourcePort = _portMap[edge.sourcePort];
      if (sourcePort != null) {
        sourceNodeId = sourcePort.instanceId;
      }
    }

    if (edge.targetPort != null) {
      final targetPort = _portMap[edge.targetPort];
      if (targetPort != null) {
        targetNodeId = targetPort.instanceId;
      }
    }

    // Edge is in scope if any of its ports are descendants of the selected
    // scope
    return isNodeInScope!(sourceNodeId, selectedEdgeScope!) ||
        isNodeInScope!(targetNodeId, selectedEdgeScope!);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // DEBUG: Track paint frequency
    if (_debugPaintFrequency) {
      _paintCounter++;
      final now = DateTime.now();
      if (_lastPaintTime != null) {
        final delta = now.difference(_lastPaintTime!).inMilliseconds;
        if (delta < 1000) {
          // Only log if repainting faster than once per second
          debugPrint(
            '[SchematicPainter] paint #$_paintCounter, '
            'delta: ${delta}ms since last paint',
          );
        }
      }
      _lastPaintTime = now;
    }

    // Draw background (matching .node-0 { fill: white } for the canvas area)
    // Fill the viewport background before applying transforms
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), _bgPaint);

    // Read current view transform from the notifier (may change between
    // build() calls via the repaint listenable).
    final vt = viewTransform.value;
    _currentScale = vt.scale;
    _currentOffset = vt.offset;

    // Calculate the visible viewport in schematic coordinates for culling
    // This allows us to skip drawing elements that are off-screen
    final viewportRect = Rect.fromLTWH(
      -_currentOffset.dx / _currentScale,
      -_currentOffset.dy / _currentScale,
      size.width / _currentScale,
      size.height / _currentScale,
    );
    _viewportRect = viewportRect;

    // Apply transform
    canvas
      ..save()
      ..translate(_currentOffset.dx, _currentOffset.dy)
      ..scale(_currentScale);

    // Draw nodes (with culling)
    _drawNodes(canvas, viewportRect);

    // Draw expand/collapse indicators above sub-blocks but below edges
    // (hidden during snapshot capture — they are interactive-only UI).
    if (!snapshotMode.value) {
      _drawExpandIndicators(canvas, viewportRect);
    }

    // Draw edges ON TOP of nodes so they're visible (with culling)
    _drawEdges(canvas, viewportRect);

    // Draw ports on top (with culling)
    _drawPorts(canvas, viewportRect);

    canvas.restore();
  }

  void _drawExpandIndicators(Canvas canvas, Rect viewportRect) {
    for (final node in layout.instances) {
      // Draw expand/collapse indicator for nodes with children
      if (node.hasChildren && !node.isExternalPort) {
        _drawExpandIndicator(canvas, node);
      }
    }
  }

  void _drawNodes(Canvas canvas, Rect viewportRect) {
    // Clear operator centering offsets from previous frame
    _operatorCenteringOffsets.clear();

    for (final node in layout.instances) {
      final rect = Rect.fromLTWH(node.x, node.y, node.width, node.height);
      final lowerCls = node.cls.toLowerCase();
      final lowerCss = node.cssClass.toLowerCase();
      // Detect CONST nodes: cls is empty OR has 'const', AND name is a
      // constant value — radixString (e.g. "8'hff") or legacy "0x...".
      final isConstNode = (node.cls.isEmpty ||
              lowerCls == 'const' ||
              lowerCss.contains('const')) &&
          isConstantName(node.name);

      // Viewport culling: skip nodes that are completely off-screen
      if (!viewportRect.overlaps(rect)) {
        continue;
      }

      // Use rx=5, ry=5 for rounded corners
      final rrect = RRect.fromRectAndRadius(
        rect,
        const Radius.circular(SchematicConstants.nodeCornerRadius),
      );

      // Differentiate rendering based on node type:
      // - External ports: filled gray
      // - Container nodes (with children): boundary only (no fill)
      // - Leaf operator nodes: draw gate symbol paths
      // - Other leaf nodes: filled with background color
      if (node.isExternalPort) {
        // .node-external-port { fill: #BDBDBD; stroke-width: 0 }
        canvas.drawRRect(rrect, _externalPortFillPaint);
      } else if (node.hasChildren) {
        // Container/module nodes: draw as boundary only (no fill)
        // This makes the module boundary visible while showing children inside
        if (_isNodeHighlighted(node.id)) {
          canvas.drawRRect(rrect, _highlightStrokePaint);
        } else {
          canvas.drawRRect(rrect, _moduleBoundaryPaint);
        }
      } else if (node.cls == 'Operator' &&
          OperatorShapes.isConcatSlice(node.name)) {
        // CONCAT/SLICE: render as a thin filled vertical bar.
        // The ELK node is wider to space ports apart; the visual bar
        // is narrow (concatSliceBarWidth) drawn at the horizontal
        // center of the ELK bounding box.
        _operatorCenteringOffsets[node.id] = (0.0, 0.0);

        const barW = OperatorShapes.concatSliceBarWidth;
        final barCenterX = node.width / 2;
        final barPath = OperatorShapes.drawConcatSliceBar(barW, node.height);

        // Everything drawn in node-local coords; translate handles absolute.
        canvas
          ..save()
          ..translate(node.x, node.y)
          // Draw the bar centered
          ..save()
          ..translate(barCenterX - barW / 2, 0)
          ..drawPath(barPath, _operatorFillPaint)
          ..drawPath(
            barPath,
            _isNodeHighlighted(node.id)
                ? _highlightStrokePaint
                : _operatorStrokePaint,
          )
          ..restore();

        // Draw wire stubs from bar center to each port edge (node-local).
        // Extend stubs 1px past the port's inner edge so they overlap with
        // the edge chain, whose starting coordinates are snapped to a
        // half-pixel grid during adjacency-based chain building.  Without
        // this overlap a sub-pixel gap can appear at higher zoom levels.
        for (final port in layout.ports) {
          if (port.instanceId != node.id) {
            continue;
          }
          final localX = port.x - node.x;
          final localY = port.y - node.y;
          final portMidY = localY + port.height / 2;
          final double portEdgeX;
          if (port.side == 'WEST') {
            portEdgeX = localX + port.width - 1;
          } else {
            portEdgeX = localX + 1;
          }
          final stubPaint = port.signalWidth > 1 ? _busPaint : _wireStubPaint;
          canvas.drawLine(
            Offset(barCenterX, portMidY),
            Offset(portEdgeX, portMidY),
            stubPaint,
          );
        }

        canvas.restore();
      } else if (node.cls == 'Operator') {
        // Leaf operator nodes: render gate symbol using OperatorShapes
        final shapePath = OperatorShapes.getPathForOperator(node.name);

        if (shapePath != null) {
          // Match JS viewer: render operator at its intrinsic size without
          // scaling The ELK layout width/height is still used for ports/edges,
          // but the drawn symbol stays at the shape's native dimensions.
          const scaleX = 1.0;
          const scaleY = 1.0;
          const uniformScale = 1.0;

          final tx = node.x;
          final ty = node.y;

          // Store zero offset so ports/edges use ELK positions directly
          _operatorCenteringOffsets[node.id] = (0.0, 0.0);

          canvas
            ..save()
            ..translate(tx, ty)
            ..scale(scaleX, scaleY)
            ..drawPath(shapePath, _operatorFillPaint)
            ..drawPath(
              shapePath,
              _isNodeHighlighted(node.id)
                  ? _highlightStrokePaint
                  : _operatorStrokePaint,
            );

          // Draw additional stroke-only paths (e.g., XOR extra arc)
          final strokeOnlyPath = OperatorShapes.getStrokeOnlyPathForOperator(
            node.name,
          );
          if (strokeOnlyPath != null) {
            canvas.drawPath(strokeOnlyPath, _operatorStrokePaint);
          }

          canvas.restore();

          // Draw primary text label inside the operator, if any. We render text
          // after restoring the transform so coordinates are absolute and only
          // translated once.
          final label = OperatorShapes.getTextForOperator(node.name);
          if (label != null) {
            // Center text on the gate body, not the full shape bounds.
            // For gates with output negation bubbles (NOT, NAND, NOR,
            // NXOR) the bubble extends the bounds rightward, so we use
            // the body-only centroid when available.
            final bodyCenter = OperatorShapes.getBodyCenter(node.name);
            final bounds = shapePath.getBounds();
            final centerPt = bodyCenter ?? bounds.center;
            final basePosition = Offset(
              tx + (centerPt.dx * uniformScale),
              ty + (centerPt.dy * uniformScale),
            );

            // _drawText with center=true uses the actual measured
            // paragraph width to center horizontally — no manual
            // character-width offset needed.
            _drawText(
              canvas,
              label,
              basePosition,
              Colors.white,
              fontSize: SchematicConstants.textFontSize * uniformScale,
              center: true,
            );
          }

          // Draw any additional small labels (e.g., ARST, en)
          final extraLabels = OperatorShapes.getAdditionalTextForOperator(
            node.name,
          );
          if (extraLabels != null) {
            for (final (text, off, size) in extraLabels) {
              _drawText(
                canvas,
                text,
                Offset(off.dx * uniformScale + tx, off.dy * uniformScale + ty),
                Colors.white,
                fontSize: size * uniformScale,
              );
            }
          }
        } else {
          // Fallback for operators without a specific shape path
          // (e.g. COMBINATIONAL): use gate colors (operatorFill)
          canvas
            ..drawRRect(rrect, _operatorFillPaint)
            ..drawRRect(
              rrect,
              _isNodeHighlighted(node.id)
                  ? _highlightStrokePaint
                  : _operatorStrokePaint,
            );

          // Struct field/compose cells: draw field name centered in the box
          final instName = node.instanceName ?? '';
          if (instName.startsWith('struct_field') ||
              instName.startsWith('struct_compose')) {
            _drawText(
              canvas,
              node.name,
              Offset(node.x + node.width / 2, node.y + node.height / 2),
              Colors.white,
              fontSize: SchematicConstants.textFontSize,
              center: true,
            );
          }
        }
      } else if (isConstNode) {
        canvas.drawRRect(rrect, _constantFillPaint);
        if (_isNodeHighlighted(node.id)) {
          canvas.drawRRect(rrect, _highlightStrokePaint);
        } else {
          canvas.drawRRect(rrect, _operatorStrokePaint);
        }
      } else {
        // Leaf nodes: solid fill + stroke
        canvas.drawRRect(rrect, _nodeFillPaint);
        if (_isNodeHighlighted(node.id)) {
          canvas.drawRRect(rrect, _highlightStrokePaint);
        } else {
          canvas.drawRRect(rrect, _nodeStrokePaint);
        }
      }

      // Draw node name (if not external port)
      // Position text above the node to match extension behavior
      // Only draw block labels for non-operator nodes
      // Constants: do not draw label, they're just visual placeholders
      if (!isConstNode &&
          !node.isExternalPort &&
          node.name.isNotEmpty &&
          node.cls != 'Operator') {
        _drawText(
          canvas,
          node.name,
          // Place label above the block with a moderate gap
          Offset(node.x, node.y - (SchematicConstants.charHeight * 0.85)),
          colorScheme.nodeText,
          fontSize: SchematicConstants.textFontSize,
        );
      }

      // Draw body text (if any)
      if (!isConstNode && node.bodyText.isNotEmpty) {
        final lines = node.bodyText.split('\n');
        for (var i = 0; i < lines.length; i++) {
          _drawText(
            canvas,
            lines[i],
            Offset(
              node.x + (node.portLabelWidth ?? 0) + 15,
              node.y + 15 + i * SchematicConstants.charHeight,
            ),
            colorScheme.nodeText,
            fontSize: SchematicConstants.textFontSize,
          );
        }
      }
    }
  }

  // ── Screen-pixel constants for control buttons ──────────────────
  // These are used inside _drawControlButton where the canvas has been
  // counter-scaled to screen-pixel space.  Keeping them as constants
  // avoids per-frame divisions and ensures crisp rendering at every zoom.
  static const double _btnScreenRadius = 10; // 20 px diameter
  static const double _btnStrokeWidth = 1.8;
  static const double _btnArmLength = 5; // half-length of +/- arms

  static final Paint _btnSymbolPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = _btnStrokeWidth
    ..color = Colors.white;

  /// Draw a single control button (circle + symbol) at a fixed 20 screen-px
  /// diameter, regardless of the current canvas zoom level.
  void _drawControlButton(
    Canvas canvas, {
    required double cx,
    required double cy,
    required _ControlIcon icon,
    required bool isPending,
  }) {
    // Counter-scale so 1 unit == 1 screen pixel.
    final drawScale = 1.0 / _currentScale;

    final bgPaint = isPending ? _expandBgPending : _expandBgNormal;

    canvas
      ..save()
      ..translate(cx, cy)
      ..scale(drawScale)
      // Background circle
      ..drawCircle(Offset.zero, _btnScreenRadius, bgPaint);

    // Symbol
    switch (icon) {
      case _ControlIcon.minus:
        canvas.drawLine(
          const Offset(-_btnArmLength, 0),
          const Offset(_btnArmLength, 0),
          _btnSymbolPaint,
        );
      case _ControlIcon.plus:
        canvas
          ..drawLine(
            const Offset(-_btnArmLength, 0),
            const Offset(_btnArmLength, 0),
            _btnSymbolPaint,
          )
          ..drawLine(
            const Offset(0, -_btnArmLength),
            const Offset(0, _btnArmLength),
            _btnSymbolPaint,
          );
      case _ControlIcon.blocks:
        // Outer box (offset upper-left)
        const outerHalf = _btnArmLength * 0.85;
        canvas.drawRect(
          Rect.fromCenter(
            center: const Offset(-outerHalf * 0.15, -outerHalf * 0.15),
            width: outerHalf * 1.5,
            height: outerHalf * 1.5,
          ),
          _btnSymbolPaint,
        );
        // Inner box (offset lower-right)
        const innerHalf = _btnArmLength * 0.5;
        canvas.drawRect(
          Rect.fromCenter(
            center: const Offset(innerHalf * 0.3, innerHalf * 0.3),
            width: innerHalf * 1.2,
            height: innerHalf * 1.2,
          ),
          _btnSymbolPaint,
        );
    }

    canvas.restore();
  }

  /// Draw expand/collapse/blocks-only icons in the upper-right of an instance.
  void _drawExpandIndicator(Canvas canvas, SchematicInstanceData instance) {
    // ── Icon sizing ────────────────────────────────────────────────
    // The icon is a fixed 20 screen-px circle.  We simply stop drawing
    // it when the node's smaller screen dimension drops below 100 px
    // (5× the icon diameter), so the controls never overwhelm the block.
    const targetScreenDiameter = 20.0; // matches _btnScreenRadius * 2
    // Don't draw icons when the node is small on screen.  The 20 px
    // circle starts crowding the block below ~100 screen-px.
    final nodeScreenW = instance.width * _currentScale;
    final nodeScreenH = instance.height * _currentScale;
    final minNodeScreen = nodeScreenW < nodeScreenH ? nodeScreenW : nodeScreenH;
    if (minNodeScreen < 5 * targetScreenDiameter) {
      return; // < 100 px
    }

    final size = targetScreenDiameter / _currentScale;
    final padding = size * 0.4;
    // Anchor: upper-right corner of the block.
    // rightX is the center of the rightmost button; others stack leftward.
    final rightX = instance.x + instance.width - padding - size / 2;
    final centerY = instance.y + padding + size / 2;

    final isPending = pendingToggleNodeId == instance.id;

    if (instance.isPartiallyExpanded) {
      // Partially expanded: collapse (−), maybe (⊞), expand (+).
      // Rightmost button anchored at rightX; others stack leftward.
      final showNonPrim = instance.hasHiddenNonPrimitiveChildren;
      final gap = size * 0.15;

      final double collapseX;
      final double expandX;
      final double? nonPrimX;

      expandX = rightX;
      if (showNonPrim) {
        nonPrimX = rightX - size - gap;
        collapseX = rightX - 2 * (size + gap);
      } else {
        nonPrimX = null;
        collapseX = rightX - size - gap;
      }

      _drawControlButton(
        canvas,
        cx: collapseX,
        cy: centerY,
        icon: _ControlIcon.minus,
        isPending: isPending,
      );
      if (nonPrimX != null) {
        _drawControlButton(
          canvas,
          cx: nonPrimX,
          cy: centerY,
          icon: _ControlIcon.blocks,
          isPending: isPending,
        );
      }
      _drawControlButton(
        canvas,
        cx: expandX,
        cy: centerY,
        icon: _ControlIcon.plus,
        isPending: isPending,
      );
    } else if (!instance.isExpanded && instance.hasHiddenNonPrimitiveChildren) {
      // Collapsed with non-primitive hidden children:
      // Two buttons: (+) at rightX, (⊞) to its left.
      final gap = size * 0.15;
      final expandX = rightX;
      final nonPrimX = rightX - size - gap;

      _drawControlButton(
        canvas,
        cx: nonPrimX,
        cy: centerY,
        icon: _ControlIcon.blocks,
        isPending: isPending,
      );
      _drawControlButton(
        canvas,
        cx: expandX,
        cy: centerY,
        icon: _ControlIcon.plus,
        isPending: isPending,
      );
    } else if (instance.isExpanded && instance.hasNonPrimitiveChildren) {
      // Fully expanded with non-primitive children:
      // Two buttons: (⊞) at rightX, (−) to its left.
      final gap = size * 0.15;
      final blocksX = rightX;
      final collapseX = rightX - size - gap;

      _drawControlButton(
        canvas,
        cx: collapseX,
        cy: centerY,
        icon: _ControlIcon.minus,
        isPending: isPending,
      );
      _drawControlButton(
        canvas,
        cx: blocksX,
        cy: centerY,
        icon: _ControlIcon.blocks,
        isPending: isPending,
      );
    } else {
      // Normal two-state: single icon at rightX.
      final icon = (isPending ? !instance.isExpanded : instance.isExpanded)
          ? _ControlIcon.minus
          : _ControlIcon.plus;

      _drawControlButton(
        canvas,
        cx: rightX,
        cy: centerY,
        icon: icon,
        isPending: isPending,
      );
    }
  }

  void _drawPorts(Canvas canvas, Rect viewportRect) {
    for (final port in layout.ports) {
      final parentInstance = _instanceMap[port.instanceId];
      final instanceOffset = _getCenteringOffsetForNode(
        port.instanceId,
        _instanceMap,
      );

      final adjustedX = port.x + instanceOffset.$1;
      final adjustedY = port.y + instanceOffset.$2;
      final portRect = Rect.fromLTWH(
        adjustedX,
        adjustedY,
        port.width,
        port.height,
      );

      final expandedRect = portRect.inflate(50);
      if (!viewportRect.overlaps(expandedRect)) {
        continue;
      }

      // Draw exterior port marker triangle.
      // Drawn only when the port has a hidden parent-scope wire (a wire
      // exists but is not currently visible).  When the wire is already
      // visible or doesn't exist at all, the marker is suppressed.
      // Also drawn when hovering a boundary edge to enable collapse.
      {
        final hoverState = hoveredBoundaryPortNotifier.value;
        final isHoveredPort = port.id == hoverState.portId;
        if (layout.exteriorHiddenPortIds.contains(port.id) ||
            (isHoveredPort && !hoverState.isInterior)) {
          _drawIOMarker(canvas, port, instanceOffset);
        }
      }

      // Draw interior port marker to enable incremental expansion.
      // Drawn only when the port has a hidden module-internal wire
      // (a wire exists but is not currently visible).
      // Also drawn when hovering an interior boundary wire to enable collapse.
      {
        final hoverState = hoveredBoundaryPortNotifier.value;
        final isHoveredPort = port.id == hoverState.portId;
        if (layout.interiorHiddenPortIds.contains(port.id) ||
            (isHoveredPort && hoverState.isInterior)) {
          _drawInteriorIOMarker(canvas, port, instanceOffset);
        }
      }

      // Draw exterior outline-only marker for child ports with no
      // parent-scope edge (unconnected at the exterior).
      if (layout.unconnectedPortIds.contains(port.id)) {
        _drawIOMarker(canvas, port, instanceOffset, paint: _portOutlinePaint);
      }

      // Draw interior outline-only marker for scope-node ports with no
      // internal edge (unconnected on the interior).
      if (layout.interiorUnconnectedPortIds.contains(port.id)) {
        _drawInteriorIOMarker(
          canvas,
          port,
          instanceOffset,
          paint: _portOutlinePaint,
        );
      }

      final isOperatorParent = (parentInstance?.cls == 'Operator');
      final isConstParent = parentInstance != null &&
          (parentInstance.cls.isEmpty ||
              parentInstance.cls.toLowerCase() == 'const' ||
              parentInstance.cssClass.toLowerCase().contains('const')) &&
          parentInstance.name.startsWith('0x');
      final isSliceOrConcat = parentInstance != null &&
          OperatorShapes.isConcatSlice(parentInstance.name);

      // --- CONCAT/SLICE/STRUCT_PACK/STRUCT_UNPACK: draw port labels near
      //     the vertical bar.
      //     SLICE input labels → to the RIGHT of the bar
      //     CONCAT input labels → right-aligned to the LEFT of the bar
      //     CONCAT output labels → to the RIGHT when explicitly provided
      //     STRUCT_PACK input labels → right-aligned to the LEFT (like CONCAT)
      //     STRUCT_UNPACK output labels → to the RIGHT (like SLICE)
      if (isSliceOrConcat) {
        final showLabel = port.name.isNotEmpty;
        if (showLabel) {
          // Just above the wire
          final textY = adjustedY - SchematicConstants.textFontSize + 4;

          // Compute bar edges from parent node geometry
          final nodeX = parentInstance.x;
          final nodeW = parentInstance.width;
          const barW = OperatorShapes.concatSliceBarWidth;
          final barLeft = nodeX + (nodeW - barW) / 2;
          final barRight = barLeft + barW;

          double textX;
          bool rightAlign;
          if (parentInstance.name == 'SLICE' ||
              parentInstance.name == 'STRUCT_UNPACK' ||
              port.isOutput) {
            // SLICE inputs and explicitly named outputs are shown to the
            // right of the bar.
            textX = barRight + 8;
            rightAlign = false;
          } else {
            // CONCAT / STRUCT_PACK: right-align so the right edge of the
            // measured text sits just left of the bar with a gap.
            // _drawText with rightAlign uses the actual paragraph width.
            textX = barLeft - 8;
            rightAlign = true;
          }
          _drawText(
            canvas,
            port.name,
            Offset(textX, textY),
            colorScheme.operatorFill,
            fontSize: SchematicConstants.textFontSize,
            rightAlign: rightAlign,
          );
        }
        continue; // Skip normal port label logic for all CONCAT/SLICE ports
      }

      // Draw port labels unless this is an operator gate.
      if (port.name.isNotEmpty && !isOperatorParent) {
        // Const blocks have blue operator fill — use white text for contrast.
        final portLabelColor =
            isConstParent ? Colors.white : colorScheme.nodeText;
        final isParentExpanded = parentInstance?.isExpanded ?? false;

        var textY = adjustedY +
            (SchematicConstants.portPinHeight -
                    SchematicConstants.textFontSize) /
                2;

        if (isParentExpanded && _portsWithVisibleEdge.contains(port.id)) {
          textY -= SchematicConstants.textFontSize;
        }

        double textX;

        if (port.side == 'WEST') {
          // Add padding to push labels past the IO-marker triangle and
          // inside the block boundary.
          textX = adjustedX + SchematicConstants.portPinWidth + 6;
          _drawText(
            canvas,
            port.name,
            Offset(textX, textY),
            portLabelColor,
            fontSize: SchematicConstants.textFontSize,
          );
        } else if (port.side == 'EAST') {
          // Right-align text so its right edge sits portPinWidth + 3
          // inside the block boundary — symmetric with WEST ports.
          // Use rightAlign mode so the actual rendered width determines
          // placement, avoiding gaps from estimated vs real text width.
          final double rightEdgeX;
          if (parentInstance != null) {
            rightEdgeX = parentInstance.x +
                parentInstance.width +
                instanceOffset.$1 -
                SchematicConstants.portPinWidth -
                3;
          } else {
            rightEdgeX =
                adjustedX + port.width - SchematicConstants.portPinWidth - 3;
          }
          _drawText(
            canvas,
            port.name,
            Offset(rightEdgeX, textY),
            portLabelColor,
            fontSize: SchematicConstants.textFontSize,
            rightAlign: true,
          );
        } else if (port.side == 'NORTH') {
          // NORTH port label: centred horizontally on the port, drawn
          // just inside the block (below the boundary).
          final portCenterX = adjustedX + port.width / 2;
          final blockTouchY = adjustedY + port.height;
          final labelY = blockTouchY + 2;
          _drawText(
            canvas,
            port.name,
            Offset(portCenterX, labelY),
            portLabelColor,
            fontSize: SchematicConstants.textFontSize,
            center: true,
          );
        } else if (port.side == 'SOUTH') {
          // SOUTH port label: centred horizontally on the port, drawn
          // just inside the block (above the boundary).
          final portCenterX = adjustedX + port.width / 2;
          final blockTouchY = adjustedY;
          final labelY = blockTouchY - SchematicConstants.textFontSize - 2;
          _drawText(
            canvas,
            port.name,
            Offset(portCenterX, labelY),
            portLabelColor,
            fontSize: SchematicConstants.textFontSize,
            center: true,
          );
        }
      }
    }
  }

  void _drawIOMarker(
    Canvas canvas,
    SchematicPortData port,
    (double, double) nodeOffset, {
    Paint? paint,
  }) {
    final path = Path();
    const h = SchematicConstants.portPinHeight;

    const markerW = 5.0;
    const markerH = 8.0;
    const horizYOffset = (h - markerH) * 0.5;
    const horizYOffset2 = (h + markerH) * 0.5;
    const vertHalfH = markerH / 2;

    // Apply centering offset to port coordinates
    final portX = port.x + nodeOffset.$1;
    final portY = port.y + nodeOffset.$2;
    final portCenterY = portY + h / 2;

    final blockTouchX = port.side == 'WEST' ? portX + port.width : portX;

    if (port.isInput) {
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX - markerW, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX - markerW, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX + markerW, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX + markerW, portY + horizYOffset2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY - markerW)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY - markerW);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY + markerW)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY + markerW);
      }
    } else if (port.isOutput) {
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX, portY + horizYOffset)
          ..lineTo(blockTouchX - markerW, portCenterY)
          ..lineTo(blockTouchX, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX, portY + horizYOffset)
          ..lineTo(blockTouchX + markerW, portCenterY)
          ..lineTo(blockTouchX, portY + horizYOffset2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY)
          ..lineTo(portCenterX, blockTouchY - markerW)
          ..lineTo(portCenterX + vertHalfH, blockTouchY);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY)
          ..lineTo(portCenterX, blockTouchY + markerW)
          ..lineTo(portCenterX + vertHalfH, blockTouchY);
      }
    } else {
      // Inout: draw a diamond marker (bidirectional)
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX - markerW, portCenterY)
          ..lineTo(blockTouchX - markerW / 2, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX - markerW / 2, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX + markerW, portCenterY)
          ..lineTo(blockTouchX + markerW / 2, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX + markerW / 2, portY + horizYOffset2);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX, blockTouchY + markerW)
          ..lineTo(portCenterX - vertHalfH, blockTouchY + markerW / 2)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY + markerW / 2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX, blockTouchY - markerW)
          ..lineTo(portCenterX - vertHalfH, blockTouchY - markerW / 2)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY - markerW / 2);
      }
    }

    path.close();
    canvas.drawPath(path, paint ?? _portStrokePaint);
    // Always draw the outline so filled and unfilled markers are the same size.
    if (paint == null) {
      canvas.drawPath(path, _portOutlinePaint);
    }
  }

  /// Draw a mirrored port marker on the *interior* side of a child instance's
  /// boundary. This is the clickable zone for incremental port expansion.
  ///
  /// The marker is drawn as a mirror image of `_drawIOMarker` across the
  /// block boundary edge, so the two triangles form a bowtie shape at the
  /// port pin location.
  void _drawInteriorIOMarker(
    Canvas canvas,
    SchematicPortData port,
    (double, double) nodeOffset, {
    Paint? paint,
  }) {
    final path = Path();
    const h = SchematicConstants.portPinHeight;

    const markerW = 5.0;
    const markerH = 8.0;
    const horizYOffset = (h - markerH) * 0.5;
    const horizYOffset2 = (h + markerH) * 0.5;
    const vertHalfH = markerH / 2;

    final portX = port.x + nodeOffset.$1;
    final portY = port.y + nodeOffset.$2;
    final portCenterY = portY + h / 2;

    // blockTouchX is the edge where the port pin meets the block boundary.
    final blockTouchX = port.side == 'WEST' ? portX + port.width : portX;

    // Interior markers are the mirror of exterior markers across the boundary.
    if (port.isInput) {
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX + markerW, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX + markerW, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX - markerW, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX - markerW, portY + horizYOffset2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY + markerW)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY + markerW);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY - markerW)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY - markerW);
      }
    } else if (port.isOutput) {
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX, portY + horizYOffset)
          ..lineTo(blockTouchX + markerW, portCenterY)
          ..lineTo(blockTouchX, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX, portY + horizYOffset)
          ..lineTo(blockTouchX - markerW, portCenterY)
          ..lineTo(blockTouchX, portY + horizYOffset2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY)
          ..lineTo(portCenterX, blockTouchY + markerW)
          ..lineTo(portCenterX + vertHalfH, blockTouchY);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX - vertHalfH, blockTouchY)
          ..lineTo(portCenterX, blockTouchY - markerW)
          ..lineTo(portCenterX + vertHalfH, blockTouchY);
      }
    } else {
      // Inout: interior diamond marker (mirror of exterior diamond)
      if (port.side == 'WEST') {
        path
          ..moveTo(blockTouchX + markerW, portCenterY)
          ..lineTo(blockTouchX + markerW / 2, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX + markerW / 2, portY + horizYOffset2);
      } else if (port.side == 'EAST') {
        path
          ..moveTo(blockTouchX - markerW, portCenterY)
          ..lineTo(blockTouchX - markerW / 2, portY + horizYOffset)
          ..lineTo(blockTouchX, portCenterY)
          ..lineTo(blockTouchX - markerW / 2, portY + horizYOffset2);
      } else if (port.side == 'SOUTH') {
        final blockTouchY = portY;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX, blockTouchY - markerW)
          ..lineTo(portCenterX - vertHalfH, blockTouchY - markerW / 2)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY - markerW / 2);
      } else if (port.side == 'NORTH') {
        final blockTouchY = portY + port.height;
        final portCenterX = portX + port.width / 2;
        path
          ..moveTo(portCenterX, blockTouchY + markerW)
          ..lineTo(portCenterX - vertHalfH, blockTouchY + markerW / 2)
          ..lineTo(portCenterX, blockTouchY)
          ..lineTo(portCenterX + vertHalfH, blockTouchY + markerW / 2);
      }
    }

    path.close();
    if (paint != null) {
      // Custom paint (e.g. outline-only for unconnected markers).
      canvas.drawPath(path, paint);
    } else {
      // Draw fill + outline inside a saveLayer at the target alpha so the
      // stroke doesn't double-composite over the fill at the boundary.
      canvas
        ..saveLayer(
          null,
          Paint()..color = const Color.fromARGB(160, 255, 255, 255),
        )
        ..drawPath(path, _portStrokePaint) // full-opacity fill
        ..drawPath(path, _portOutlinePaint) // full-opacity outline
        ..restore();
    }
  }

  void _drawEdges(Canvas canvas, Rect viewportRect) {
    // First pass: build adjusted polylines for each edge (apply instance centering/ports)
    final adjustedEdges = <SchematicEdgeData, List<Offset>>{};
    final edgeBounds = <SchematicEdgeData, Rect>{};

    for (final edge in layout.edges) {
      if (edge.points.length < 2) {
        continue;
      }

      final adjustedPoints = List<Offset>.from(
        edge.points.map((p) => Offset(p.x, p.y)),
      );

      // Snap source endpoint to the port's block-touching edge.
      // Only adjust the exit-axis coordinate to avoid introducing diagonals.
      // EAST/WEST → change X only.  NORTH/SOUTH → change Y only.
      if (edge.sourcePort != null) {
        final sourcePort = _portMap[edge.sourcePort];
        if (sourcePort != null) {
          final instanceOffset = _getCenteringOffsetForNode(
            sourcePort.instanceId,
            _instanceMap,
          );
          final portX = sourcePort.x + instanceOffset.$1;
          final portY = sourcePort.y + instanceOffset.$2;
          final elkPt = adjustedPoints[0];

          if (sourcePort.side == 'WEST') {
            final blockTouchX = portX + sourcePort.width;
            adjustedPoints[0] = Offset(blockTouchX, elkPt.dy);
          } else if (sourcePort.side == 'EAST') {
            final blockTouchX = portX;
            adjustedPoints[0] = Offset(blockTouchX, elkPt.dy);
          } else if (sourcePort.side == 'NORTH') {
            final blockTouchY = portY + sourcePort.height;
            adjustedPoints[0] = Offset(elkPt.dx, blockTouchY);
          } else if (sourcePort.side == 'SOUTH') {
            final blockTouchY = portY;
            adjustedPoints[0] = Offset(elkPt.dx, blockTouchY);
          }
        }
      }

      // Snap target endpoint — same single-axis logic.
      if (edge.targetPort != null) {
        final targetPort = _portMap[edge.targetPort];
        if (targetPort != null) {
          final instanceOffset = _getCenteringOffsetForNode(
            targetPort.instanceId,
            _instanceMap,
          );
          final portX = targetPort.x + instanceOffset.$1;
          final portY = targetPort.y + instanceOffset.$2;
          final elkPt = adjustedPoints[adjustedPoints.length - 1];

          if (targetPort.side == 'WEST') {
            final blockTouchX = portX + targetPort.width;
            adjustedPoints[adjustedPoints.length - 1] = Offset(
              blockTouchX,
              elkPt.dy,
            );
          } else if (targetPort.side == 'EAST') {
            final blockTouchX = portX;
            adjustedPoints[adjustedPoints.length - 1] = Offset(
              blockTouchX,
              elkPt.dy,
            );
          } else if (targetPort.side == 'NORTH') {
            final blockTouchY = portY + targetPort.height;
            adjustedPoints[adjustedPoints.length - 1] = Offset(
              elkPt.dx,
              blockTouchY,
            );
          } else if (targetPort.side == 'SOUTH') {
            final blockTouchY = portY;
            adjustedPoints[adjustedPoints.length - 1] = Offset(
              elkPt.dx,
              blockTouchY,
            );
          }
        }
      }

      var minX = adjustedPoints[0].dx;
      var minY = adjustedPoints[0].dy;
      var maxX = minX;
      var maxY = minY;
      for (final p in adjustedPoints) {
        if (p.dx < minX) {
          minX = p.dx;
        }
        if (p.dy < minY) {
          minY = p.dy;
        }
        if (p.dx > maxX) {
          maxX = p.dx;
        }
        if (p.dy > maxY) {
          maxY = p.dy;
        }
      }
      final bounds = Rect.fromLTRB(minX, minY, maxX, maxY);

      adjustedEdges[edge] = adjustedPoints;
      edgeBounds[edge] = bounds;
    }

    // Group edges by wireId.
    final wires = <String, List<SchematicEdgeData>>{};
    adjustedEdges.forEach((edge, _) {
      wires.putIfAbsent(edge.wireId, () => <SchematicEdgeData>[]).add(edge);
    });

    // --- Fracture, dedup, and merge segments per wire --------------------
    //
    // Wires with ≤2 edges: draw original polylines as-is (no processing).
    // Wires with 3+ edges (fan-out): fracture at incident points, dedup
    // contained segments, then merge colinear segments only at points
    // with no other incident edges.  This can never introduce diagonals
    // because we never delete a point where an orthogonal wire connects.

    // wireSegments`wireId` = list of (p1, p2) segments.
    // Only populated for wires that need processing (3+ edges) or
    // for wires with ≤2 edges (straight extraction for downstream use).
    final wireSegments = <String, List<(Offset, Offset)>>{};
    // Track the first edge per wireId for metadata (signalWidth, etc.).
    final wireTemplateEdge = <String, SchematicEdgeData>{};

    for (final wireEntry in wires.entries) {
      final wireId = wireEntry.key;
      final wireEdges = wireEntry.value;
      wireTemplateEdge[wireId] = wireEdges.first;

      if (wireEdges.length <= 2) {
        // ≤2 edges: extract segments from original polylines unchanged.
        // No fracturing or merging needed — no junction dots possible.
        final segs = <(Offset, Offset)>[];
        for (final edge in wireEdges) {
          final pts = adjustedEdges[edge]!;
          for (var i = 0; i < pts.length - 1; i++) {
            segs.add((pts[i], pts[i + 1]));
          }
        }
        wireSegments[wireId] = segs;
        continue;
      }

      // --- 3+ edges: fracture, dedup, merge ---
      //
      // 1. Extract all raw segments from every polyline.
      // 2. Collect all unique points (rounded to avoid FP noise).
      // 3. Fracture: split any segment at interior incident points
      //    so every sub-segment boundary lands on a shared point.
      // 4. Dedup: remove duplicate (or reverse-duplicate) sub-segments.
      // 5. Identify junction points (points with 3+ incident sub-segs).
      // 6. Merge: colinear adjacent sub-segments at non-junction points.

      const eps = 0.5; // coordinate snap tolerance

      // Round to grid to avoid floating-point near-misses.
      Offset snap(Offset p) => Offset(
            (p.dx * 2).roundToDouble() / 2,
            (p.dy * 2).roundToDouble() / 2,
          );

      // Step 1: raw segments
      final rawSegs = <(Offset, Offset)>[];
      for (final edge in wireEdges) {
        final pts = adjustedEdges[edge]!;
        for (var i = 0; i < pts.length - 1; i++) {
          rawSegs.add((snap(pts[i]), snap(pts[i + 1])));
        }
      }

      // Step 2: collect all unique points
      final allPoints = <Offset>{};
      for (final (a, b) in rawSegs) {
        allPoints
          ..add(a)
          ..add(b);
      }

      // Step 3: fracture segments at interior incident points
      final fractured = <(Offset, Offset)>[];
      for (final (a, b) in rawSegs) {
        final isHoriz = (a.dy - b.dy).abs() < eps;
        final isVert = (a.dx - b.dx).abs() < eps;

        // Collect points that lie strictly inside this segment.
        final interior = <Offset>[];
        for (final p in allPoints) {
          if ((p - a).distance < eps || (p - b).distance < eps) {
            continue;
          }
          if (isHoriz && (p.dy - a.dy).abs() < eps) {
            final minX = math.min(a.dx, b.dx);
            final maxX = math.max(a.dx, b.dx);
            if (p.dx > minX + eps && p.dx < maxX - eps) {
              interior.add(p);
            }
          } else if (isVert && (p.dx - a.dx).abs() < eps) {
            final minY = math.min(a.dy, b.dy);
            final maxY = math.max(a.dy, b.dy);
            if (p.dy > minY + eps && p.dy < maxY - eps) {
              interior.add(p);
            }
          }
        }

        if (interior.isEmpty) {
          fractured.add((a, b));
        } else {
          // Sort interior points along the segment direction.
          if (isHoriz) {
            interior.sort((p, q) => p.dx.compareTo(q.dx));
          } else {
            interior.sort((p, q) => p.dy.compareTo(q.dy));
          }
          // Build sub-segments: a → i0 → i1 → ... → b
          // but in the direction from a to b.
          final chain = [a, ...interior, b];
          if (isHoriz && a.dx > b.dx || isVert && a.dy > b.dy) {
            // Reverse so chain goes min→max, then reverse sub-segs.
            // Actually easier: just iterate as-is — order doesn't matter
            // for dedup since we canonicalize below.
          }
          for (var k = 0; k < chain.length - 1; k++) {
            fractured.add((chain[k], chain[k + 1]));
          }
        }
      }

      // Step 4: dedup — canonicalize each segment and remove duplicates.
      // Canonical form: for horizontal segs, left point first;
      // for vertical segs, top point first.
      (Offset, Offset) canon(Offset p1, Offset p2) {
        if ((p1.dy - p2.dy).abs() < eps) {
          // horizontal
          return p1.dx <= p2.dx ? (p1, p2) : (p2, p1);
        } else {
          // vertical
          return p1.dy <= p2.dy ? (p1, p2) : (p2, p1);
        }
      }

      final seen = <(double, double, double, double)>{};
      final deduped = <(Offset, Offset)>[];
      for (final seg in fractured) {
        final (c1, c2) = canon(seg.$1, seg.$2);
        final key = (
          (c1.dx * 2).roundToDouble(),
          (c1.dy * 2).roundToDouble(),
          (c2.dx * 2).roundToDouble(),
          (c2.dy * 2).roundToDouble(),
        );
        if (seen.add(key)) {
          deduped.add((c1, c2));
        }
      }

      // Step 5: identify junction points (3+ incident sub-segments).
      final incidentCount = <(double, double), int>{};
      for (final (a, b) in deduped) {
        final ka = ((a.dx * 2).roundToDouble(), (a.dy * 2).roundToDouble());
        final kb = ((b.dx * 2).roundToDouble(), (b.dy * 2).roundToDouble());
        incidentCount[ka] = (incidentCount[ka] ?? 0) + 1;
        incidentCount[kb] = (incidentCount[kb] ?? 0) + 1;
      }
      final junctions = <(double, double)>{};
      for (final entry in incidentCount.entries) {
        if (entry.value >= 3) {
          junctions.add(entry.key);
        }
      }

      // Step 6: merge colinear adjacent sub-segments at non-junction points.
      // Group by axis-key (shared coordinate).
      final horizByY = <double, List<(Offset, Offset)>>{};
      final vertByX = <double, List<(Offset, Offset)>>{};
      for (final (a, b) in deduped) {
        if ((a.dy - b.dy).abs() < eps) {
          final y = (a.dy * 2).roundToDouble() / 2;
          horizByY.putIfAbsent(y, () => []).add((a, b));
        } else {
          final x = (a.dx * 2).roundToDouble() / 2;
          vertByX.putIfAbsent(x, () => []).add((a, b));
        }
      }

      final merged = <(Offset, Offset)>[];

      // Merge horizontal runs.
      for (final segsOnLine in horizByY.values) {
        // Sort by left X.
        segsOnLine.sort((a, b) => a.$1.dx.compareTo(b.$1.dx));
        var curA = segsOnLine.first.$1;
        var curB = segsOnLine.first.$2;
        for (var i = 1; i < segsOnLine.length; i++) {
          final nextA = segsOnLine[i].$1;
          final nextB = segsOnLine[i].$2;
          // Check if curB touches nextA and the shared point is NOT a junction.
          final shared = (
            (curB.dx * 2).roundToDouble(),
            (curB.dy * 2).roundToDouble(),
          );
          if ((curB - nextA).distance < eps && !junctions.contains(shared)) {
            // Extend current segment.
            curB = nextB;
          } else {
            merged.add((curA, curB));
            curA = nextA;
            curB = nextB;
          }
        }
        merged.add((curA, curB));
      }

      // Merge vertical runs.
      for (final segsOnLine in vertByX.values) {
        // Sort by top Y.
        segsOnLine.sort((a, b) => a.$1.dy.compareTo(b.$1.dy));
        var curA = segsOnLine.first.$1;
        var curB = segsOnLine.first.$2;
        for (var i = 1; i < segsOnLine.length; i++) {
          final nextA = segsOnLine[i].$1;
          final nextB = segsOnLine[i].$2;
          final shared = (
            (curB.dx * 2).roundToDouble(),
            (curB.dy * 2).roundToDouble(),
          );
          if ((curB - nextA).distance < eps && !junctions.contains(shared)) {
            curB = nextB;
          } else {
            merged.add((curA, curB));
            curA = nextA;
            curB = nextB;
          }
        }
        merged.add((curA, curB));
      }

      wireSegments[wireId] = merged;
    }
    // --- End fracture/dedup/merge ----------------------------------------

    // --- Intersection detection using merged segments --------------------
    final intersectionsByWire = <String, List<Offset>>{};

    Offset? segmentIntersection(Offset a1, Offset a2, Offset b1, Offset b2) {
      const eps = 1e-6;
      final denom =
          (a1.dx - a2.dx) * (b1.dy - b2.dy) - (a1.dy - a2.dy) * (b1.dx - b2.dx);
      if (denom.abs() < eps) {
        return null;
      }
      final detA = a1.dx * a2.dy - a1.dy * a2.dx;
      final detB = b1.dx * b2.dy - b1.dy * b2.dx;
      final x = (detA * (b1.dx - b2.dx) - (a1.dx - a2.dx) * detB) / denom;
      final y = (detA * (b1.dy - b2.dy) - (a1.dy - a2.dy) * detB) / denom;
      bool within(Offset p, Offset q1, Offset q2) =>
          p.dx >= math.min(q1.dx, q2.dx) - eps &&
          p.dx <= math.max(q1.dx, q2.dx) + eps &&
          p.dy >= math.min(q1.dy, q2.dy) - eps &&
          p.dy <= math.max(q1.dy, q2.dy) + eps;
      final p = Offset(x, y);
      return (within(p, a1, a2) && within(p, b1, b2)) ? p : null;
    }

    for (final wireEntry in wireSegments.entries) {
      final segs = wireEntry.value;
      if (segs.length < 2) {
        continue;
      }

      // Find all pairwise segment intersections, tracking which segment
      // indices contribute to each intersection point.
      final intersectionMap = <Offset, Set<int>>{};
      const dedupDistSq = 0.25;

      for (var i = 0; i < segs.length; i++) {
        final (a1, a2) = segs[i];
        for (var j = i + 1; j < segs.length; j++) {
          final (b1, b2) = segs[j];
          final hit = segmentIntersection(a1, a2, b1, b2);
          if (hit != null) {
            Offset? existing;
            for (final key in intersectionMap.keys) {
              if ((key - hit).distanceSquared < dedupDistSq) {
                existing = key;
                break;
              }
            }
            if (existing != null) {
              intersectionMap[existing]!.addAll({i, j});
            } else {
              intersectionMap[hit] = {i, j};
            }
          }
        }
      }

      // Direction-based junction filtering.
      // Endpoint touch → 1 direction.  Interior touch → 2 directions.
      // 3+ unique directions = real branch → draw dot.
      const dirEps = 2.0;

      int cardinalDir(Offset from, Offset to) {
        final dx = to.dx - from.dx;
        final dy = to.dy - from.dy;
        if (dx.abs() >= dy.abs()) {
          return dx >= 0 ? 0 : 2;
        } else {
          return dy >= 0 ? 1 : 3;
        }
      }

      final filtered = <Offset>[];
      for (final mapEntry in intersectionMap.entries) {
        final point = mapEntry.key;
        final segIndices = mapEntry.value;
        final directions = <int>{};

        for (final si in segIndices) {
          final (p1, p2) = segs[si];
          final d1 = (p1 - point).distance;
          final d2 = (p2 - point).distance;
          final isEnd1 = d1 < dirEps;
          final isEnd2 = d2 < dirEps;

          if (isEnd1 && isEnd2) {
            continue;
          } else if (isEnd1) {
            directions.add(cardinalDir(point, p2));
          } else if (isEnd2) {
            directions.add(cardinalDir(point, p1));
          } else if (d1 + d2 < (p2 - p1).distance + dirEps * 2) {
            directions
              ..add(cardinalDir(point, p1))
              ..add(cardinalDir(point, p2));
          }
        }

        if (directions.length >= 3) {
          filtered.add(point);
        }
      }

      if (filtered.isNotEmpty) {
        intersectionsByWire[wireEntry.key] = filtered;
      }
    }

    // --- Reconstruct chains from segments for rounded-corner drawing ----
    //
    // For each wire, build an adjacency map from the merged segments, then
    // walk chains (sequences of connected segments).  Corners at degree-2
    // non-junction points get a quadratic bezier arc; junctions and
    // endpoints stay sharp.
    final wireChains = <String, List<List<Offset>>>{};
    const cornerR = SchematicConstants.wireCornerRadius;

    for (final wireEntry in wireSegments.entries) {
      final wireId = wireEntry.key;
      final segs = wireEntry.value;

      if (segs.isEmpty) {
        wireChains[wireId] = [];
        continue;
      }

      // Build adjacency: point → list of connected points.
      const cEps = 0.5;
      (double, double) key(Offset p) =>
          ((p.dx * 2).roundToDouble(), (p.dy * 2).roundToDouble());

      final adj = <(double, double), List<Offset>>{};
      for (final (a, b) in segs) {
        final ka = key(a);
        final kb = key(b);
        adj.putIfAbsent(ka, () => []).add(b);
        adj.putIfAbsent(kb, () => []).add(a);
      }

      // Junction keys (3+ incident segments or from intersection analysis).
      final juncKeys = <(double, double)>{};
      for (final entry in adj.entries) {
        if (entry.value.length >= 3) {
          juncKeys.add(entry.key);
        }
      }
      final wireIntersections = intersectionsByWire[wireId];
      if (wireIntersections != null) {
        for (final p in wireIntersections) {
          juncKeys.add(key(p));
        }
      }

      // Walk chains: start from endpoints (degree 1) or junctions (degree 3+).
      // Each chain is a list of Offset points forming a polyline.
      final visited = <((double, double), (double, double))>{};
      final chains = <List<Offset>>[];

      void walkChain(Offset start, Offset next) {
        final edgeKey = (key(start), key(next));
        final edgeKeyRev = (key(next), key(start));
        if (visited.contains(edgeKey) || visited.contains(edgeKeyRev)) {
          return;
        }
        final chain = <Offset>[start];
        var prev = start;
        var cur = next;
        while (true) {
          final ek = (key(prev), key(cur));
          final ekr = (key(cur), key(prev));
          visited
            ..add(ek)
            ..add(ekr);
          chain.add(cur);

          final curKey = key(cur);
          // Stop at endpoints (degree 1) or junctions (degree 3+).
          final neighbors = adj[curKey];
          if (neighbors == null ||
              neighbors.length != 2 ||
              juncKeys.contains(curKey)) {
            break;
          }
          // Continue to the neighbor that isn't prev.
          Offset? nxt;
          for (final n in neighbors) {
            if ((n - prev).distance > cEps) {
              nxt = n;
              break;
            }
          }
          if (nxt == null) {
            break;
          }
          prev = cur;
          cur = nxt;
        }
        if (chain.length >= 2) {
          chains.add(chain);
        }
      }

      // Start from degree-1 and degree-3+ points.
      for (final entry in adj.entries) {
        final pk = entry.key;
        if (entry.value.length != 2 || juncKeys.contains(pk)) {
          final pOff = Offset(pk.$1 / 2, pk.$2 / 2); // un-scale from key space
          for (final neighbor in entry.value) {
            walkChain(pOff, neighbor);
          }
        }
      }

      // Fallback: if there are unvisited segments (cycles), walk them too.
      for (final (a, b) in segs) {
        final ek = (key(a), key(b));
        final ekr = (key(b), key(a));
        if (!visited.contains(ek) && !visited.contains(ekr)) {
          walkChain(a, b);
        }
      }

      wireChains[wireId] = chains;
    }

    // --- Build per-scope point lists for selected wires ------------------
    // For multi-instance wires, we need to know which chains belong to the
    // selected scope so we can highlight only those chains.  Collect the
    // adjusted-edge point coordinates for in-scope edges; during the draw
    // pass we use proximity matching (tolerance) to tag each chain.
    final scopedWireOffsets = <String, List<Offset>>{};
    for (final entry in selectedWireScopePaths.entries) {
      final wid = entry.key;
      final scopePath = entry.value;
      if (scopePath == null) {
        continue; // no scope restriction for this wire
      }
      final pts = <Offset>[];
      for (final edge in layout.edges) {
        if (edge.wireId != wid) {
          continue;
        }
        if (edge.scopeHierarchyPath != scopePath) {
          continue;
        }
        final adjustedPts = adjustedEdges[edge];
        if (adjustedPts != null) {
          pts.addAll(adjustedPts);
        }
      }
      if (pts.isNotEmpty) {
        scopedWireOffsets[wid] = pts;
      }
    }

    // --- Draw pass -------------------------------------------------------
    final drawnWires = <String>{};

    for (final edge in layout.edges) {
      final wireId = edge.wireId;
      final segs = wireSegments[wireId];
      if (segs == null) {
        continue;
      }

      final isHighlighted = (highlightedWireName != null &&
              wireId == highlightedWireName &&
              _edgeInScope(edge)) ||
          selectedWireIds.contains(wireId);
      final isBus = edge.signalWidth > 1;
      final highlightPaint = isBus ? _busHighlightPaint : _wireHighlightPaint;
      final normalPaint = isBus ? _busPaint : _wirePaint;
      // When scope-offset data exists for this wire, per-chain highlighting
      // is used instead of painting all chains with the same brush.
      final scopeOffsets = scopedWireOffsets[wireId];
      final paint =
          isHighlighted && scopeOffsets == null ? highlightPaint : normalPaint;

      if (!drawnWires.contains(wireId)) {
        drawnWires.add(wireId);

        // Draw chains with rounded corners.
        final chains = wireChains[wireId] ?? [];
        for (final chain in chains) {
          if (chain.length < 2) {
            continue;
          }

          // Per-chain scope highlight: when scopeOffsets exist for this
          // selected wire, highlight only chains that have at least one
          // point within 1 pixel of an in-scope adjusted-edge point.
          // Multi-instance blocks are at different spatial positions, so
          // this proximity check cleanly discriminates them.
          Paint chainPaint;
          if (isHighlighted && scopeOffsets != null) {
            const tolerance = 1.0; // pixels
            final inScope = chain.any(
              (cp) => scopeOffsets.any(
                (sp) =>
                    (cp.dx - sp.dx).abs() < tolerance &&
                    (cp.dy - sp.dy).abs() < tolerance,
              ),
            );
            chainPaint = inScope ? highlightPaint : normalPaint;
          } else {
            chainPaint = paint;
          }

          // Compute the bounding rect for viewport culling.
          var cMinX = chain[0].dx;
          var cMaxX = chain[0].dx;
          var cMinY = chain[0].dy;
          var cMaxY = chain[0].dy;
          for (final p in chain) {
            if (p.dx < cMinX) {
              cMinX = p.dx;
            }
            if (p.dx > cMaxX) {
              cMaxX = p.dx;
            }
            if (p.dy < cMinY) {
              cMinY = p.dy;
            }
            if (p.dy > cMaxY) {
              cMaxY = p.dy;
            }
          }
          if (!viewportRect.overlaps(
            Rect.fromLTRB(cMinX, cMinY, cMaxX, cMaxY),
          )) {
            continue;
          }

          if (chain.length == 2) {
            // Straight segment — no corner to round.
            canvas.drawLine(chain[0], chain[1], chainPaint);
          } else {
            // Build a Path with rounded corners at interior bend points.
            final path = Path()..moveTo(chain[0].dx, chain[0].dy);
            for (var i = 1; i < chain.length - 1; i++) {
              final prev = chain[i - 1];
              final cur = chain[i];
              final next = chain[i + 1];

              // Available lengths on each arm of the corner.
              final armA = (cur - prev).distance;
              final armB = (next - cur).distance;
              // Clamp radius so it doesn't exceed half of either arm.
              final r = cornerR.clamp(0.0, math.min(armA, armB) / 2);

              if (r < 0.5) {
                // Too short to round — draw straight.
                path.lineTo(cur.dx, cur.dy);
              } else {
                // Point on the incoming arm, r before the corner.
                final dA = Offset(
                  cur.dx + (prev.dx - cur.dx) * r / armA,
                  cur.dy + (prev.dy - cur.dy) * r / armA,
                );
                // Point on the outgoing arm, r after the corner.
                final dB = Offset(
                  cur.dx + (next.dx - cur.dx) * r / armB,
                  cur.dy + (next.dy - cur.dy) * r / armB,
                );
                path
                  ..lineTo(dA.dx, dA.dy)
                  ..quadraticBezierTo(cur.dx, cur.dy, dB.dx, dB.dy);
              }
            }
            // Final point.
            final last = chain.last;
            path.lineTo(last.dx, last.dy);
            canvas.drawPath(path, chainPaint);
          }
        }

        // Draw junction dots from merged-segment intersection analysis.
        final intersections = intersectionsByWire[wireId];
        if (intersections != null) {
          for (final hit in intersections) {
            canvas.drawCircle(
              hit,
              SchematicConstants.junctionRadius,
              isHighlighted ? _junctionHighlightPaint : _junctionPaint,
            );
          }
        }
      }

      // Draw pre-computed ELK junction points (per original edge).
      if (edge.junctionPoints != null && edge.junctionPoints!.isNotEmpty) {
        for (final jp in edge.junctionPoints!) {
          canvas.drawCircle(
            Offset(jp.x, jp.y),
            SchematicConstants.junctionRadius,
            isHighlighted ? _junctionHighlightPaint : _junctionPaint,
          );
        }
      }
    }

    // --- Bus width labels ------------------------------------------------
    // Label each wire's longest qualifying segment.
    final labeledWires = <String>{};

    for (final wireEntry in wireSegments.entries) {
      final wireId = wireEntry.key;
      if (labeledWires.contains(wireId)) {
        continue;
      }

      final templateEdge = wireTemplateEdge[wireId];
      if (templateEdge == null) {
        continue;
      }
      final sw = templateEdge.signalWidth;
      if (sw <= 1) {
        continue;
      }

      final segs = wireEntry.value;
      double bestLen = 0;
      var bestA = Offset.zero;
      var bestB = Offset.zero;

      for (final (p1, p2) in segs) {
        final len = (p2 - p1).distance;
        if (len > bestLen) {
          bestLen = len;
          bestA = p1;
          bestB = p2;
        }
      }

      if (bestLen < 20) {
        continue; // too short to label at all
      }

      labeledWires.add(wireId);

      // Label only the longest segment per wire.
      final segments = [(bestA, bestB)];

      for (final (segA, segB) in segments) {
        final mid = Offset((segA.dx + segB.dx) / 2, (segA.dy + segB.dy) / 2);

        // Skip if midpoint is off-screen
        if (!viewportRect.inflate(20).contains(mid)) {
          continue;
        }

        final isHorizontal =
            (segB.dy - segA.dy).abs() < (segB.dx - segA.dx).abs();
        const slashLen = 5.0;

        final annotColor = colorScheme.operatorFill.withAlpha(220);
        if (isHorizontal) {
          canvas.drawLine(
            Offset(mid.dx - slashLen, mid.dy + slashLen),
            Offset(mid.dx + slashLen, mid.dy - slashLen),
            _slashPaint,
          );
          _drawText(
            canvas,
            sw.toString(),
            Offset(mid.dx, mid.dy - slashLen - 4),
            annotColor,
            fontSize: 9,
            center: true,
            bold: true,
          );
        } else {
          canvas.drawLine(
            Offset(mid.dx - slashLen, mid.dy + slashLen),
            Offset(mid.dx + slashLen, mid.dy - slashLen),
            _slashPaint,
          );
          _drawText(
            canvas,
            sw.toString(),
            Offset(mid.dx + slashLen + 2, mid.dy - 5),
            annotColor,
            fontSize: 9,
            bold: true,
          );
        }
      }
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset position,
    Color color, {
    double fontSize = 12,
    bool center = false,
    bool rightAlign = false,
    bool bold = false,
  }) {
    // Text is always rendered regardless of zoom level so that PNG snapshots
    // include readable labels.  The viewport overlap check below still culls
    // off-screen text for performance.

    final estimatedWidth = text.length * fontSize * 0.6;
    final textRect = Rect.fromLTWH(
      position.dx -
          (center
              ? estimatedWidth / 2
              : rightAlign
                  ? estimatedWidth
                  : 0),
      position.dy - (center ? fontSize / 2 : 0),
      estimatedWidth,
      fontSize,
    );

    if (!_viewportRect.overlaps(textRect.inflate(fontSize))) {
      return;
    }

    // Cache paragraphs to avoid re-creating TextStyle/ParagraphBuilder every
    // frame.  The key is a hash of all rendering-relevant properties.
    final cacheKey = Object.hash(text, fontSize, color.toARGB32(), bold);
    var paragraph = _paragraphCache[cacheKey];

    if (paragraph == null) {
      final textStyle = ui.TextStyle(
        color: color,
        fontSize: fontSize,
        fontFamily: 'monospace',
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      );

      final paragraphStyle = ui.ParagraphStyle(
        // Always use left alignment — centering is handled by textOffset
        // calculation below, not by TextAlign.center (which would
        // double-offset within the layout constraint width).
        textAlign: TextAlign.left,
        maxLines: 1,
        fontFamily: 'monospace',
      );

      final paragraphBuilder = ui.ParagraphBuilder(paragraphStyle)
        ..pushStyle(textStyle)
        ..addText(text);

      paragraph = paragraphBuilder.build()
        ..layout(ui.ParagraphConstraints(width: text.length * fontSize));
      _paragraphCache[cacheKey] = paragraph;
    }

    final Offset textOffset;
    if (center) {
      textOffset = Offset(
        position.dx - paragraph.maxIntrinsicWidth / 2,
        position.dy - fontSize / 2,
      );
    } else if (rightAlign) {
      // position.dx is the desired RIGHT edge of the text;
      // offset leftward by the actual rendered width.
      textOffset = Offset(
        position.dx - paragraph.maxIntrinsicWidth,
        position.dy,
      );
    } else {
      textOffset = position;
    }

    canvas.drawParagraph(paragraph, textOffset);
  }

  @override
  bool shouldRepaint(covariant SchematicPainter oldDelegate) {
    // Scale/offset changes arrive via the repaint listenable (viewTransform
    // ValueNotifier) and do NOT need a shouldRepaint check.  This avoids a
    // full build() on every zoom/pan frame.
    if (_debugPaintFrequency) {
      final reasons = <String>[];
      if (layout != oldDelegate.layout) {
        reasons.add('layout');
      }
      if (colorScheme != oldDelegate.colorScheme) {
        reasons.add('colorScheme');
      }
      if (highlightedWireName != oldDelegate.highlightedWireName) {
        reasons.add('highlightedWireName');
      }
      if (selectedEdgeScope != oldDelegate.selectedEdgeScope) {
        reasons.add('selectedEdgeScope');
      }
      if (!_setEquals(selectedWireIds, oldDelegate.selectedWireIds)) {
        reasons.add('selectedWireIds');
      }
      if (!_setEquals(selectedNodeIds, oldDelegate.selectedNodeIds)) {
        reasons.add('selectedNodeIds');
      }
      if (highlightedNodeId != oldDelegate.highlightedNodeId) {
        reasons.add('highlightedNodeId');
      }
      if (pendingToggleNodeId != oldDelegate.pendingToggleNodeId) {
        reasons.add('pendingToggleNodeId');
      }

      if (reasons.isNotEmpty) {
        debugPrint('[SchematicPainter] shouldRepaint=true, reasons: $reasons');
      }
    }

    return layout != oldDelegate.layout ||
        colorScheme != oldDelegate.colorScheme ||
        highlightedWireName != oldDelegate.highlightedWireName ||
        selectedEdgeScope != oldDelegate.selectedEdgeScope ||
        !_setEquals(selectedWireIds, oldDelegate.selectedWireIds) ||
        !_setEquals(selectedNodeIds, oldDelegate.selectedNodeIds) ||
        highlightedNodeId != oldDelegate.highlightedNodeId ||
        pendingToggleNodeId != oldDelegate.pendingToggleNodeId;
  }

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) {
      return false;
    }
    return a.containsAll(b);
  }
}

/// Widget that wraps the schematic painter with interaction.
class SchematicCanvas extends StatefulWidget {
  /// Schematic layout data to render.
  final SchematicLayoutResult layout;

  /// Color scheme to use for rendering.
  final SchematicColorScheme colorScheme;

  /// Original netlist JSON for comprehensive wire search (optional)
  final String? netlistJson;

  /// External hierarchy service from parent application. When provided, used
  /// for signal search instead of building from netlistJson. This enables
  /// sharing hierarchy state across DevTools, Wave Viewer, etc.
  final HierarchyService? externalHierarchy;

  /// Callback when a node with children is tapped to expand/collapse.
  /// Returns a Future with the updated layout model.
  final Future<SchematicLayoutResult?> Function(String nodeId)? onNodeToggle;

  /// Node ID that is currently being toggled (for immediate +/- flip feedback).
  final String? pendingToggleNodeId;

  /// Node ID that was just toggled (used to fit view to this node after layout
  /// updates).
  final String? recentlyToggledNodeId;

  /// Whether the canvas should be dimmed (during layout computation).
  final bool isDimmed;

  /// Port ID to focus on after incremental expansion.
  /// When set, the canvas pans so this port is centred at the current zoom
  /// level (instead of fitting the whole toggled node).
  final String? focusPortId;

  /// Optional callback to look up a signal's current value by wire name.
  ///
  /// When provided (i.e. in embedded/DevTools mode), the hover tooltip will
  /// show the signal value on a second line beneath the wire name.
  /// The `computed` flag indicates whether the value was evaluated
  /// extension-side (gate DAG, alias, wire copy, constant) rather than
  /// fetched from the VM service — used to colour the tooltip text.
  /// When null (standalone mode), only the wire name is shown.
  final ({String value, bool computed, String signalId})? Function(
    String wireName,
  )? signalValueLookup;

  /// Callback when an interior port marker is clicked for incremental
  /// expansion. Receives the instance (node) ID and the port ID.
  /// Returns a Future with the updated layout model (or null on failure).
  final Future<SchematicLayoutResult?> Function(String nodeId, String portId)?
      onPortExpand;

  /// Callback for pass-through port expansion (Shift+click).
  ///
  /// Like `onPortExpand` but continues through trivial gates (buffers,
  /// inverters, slicers, concatenators) until non-trivial children or
  /// external ports are reached.
  final Future<SchematicLayoutResult?> Function(String nodeId, String portId)?
      onPortExpandThrough;

  /// Callback to collapse a single port's wire and connected trivial gates.
  /// Reverse of `onPortExpand`: removes the traced children/edges from
  /// partial expansion.
  final Future<SchematicLayoutResult?> Function(String nodeId, String portId)?
      onPortCollapse;

  /// Callback for recursive port collapse (Shift+click on a boundary port
  /// that already has a visible wire).  Reverse of `onPortExpandThrough`.
  final Future<SchematicLayoutResult?> Function(String nodeId, String portId)?
      onPortCollapseThrough;

  /// Callback when the collapse (−) icon is clicked on a partially expanded
  /// node. Clears partial expansion and returns the updated layout.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onCollapsePartial;

  /// Callback when the "expand non-primitives" button is clicked.
  /// Reveals all non-primitive (submodule) hidden children of a node
  /// via partial expansion.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onExpandNonPrimitives;

  /// Callback when the "convert to blocks-only" button is clicked on a
  /// fully expanded node.  Collapses the node then re-expands only
  /// non-primitive children without edges.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onConvertToBlocksOnly;

  /// Recursive variant of `onNodeToggle` (Shift+click).
  /// Expands/collapses the node and all descendant submodules.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onNodeToggleRecursive;

  /// Recursive variant of `onExpandNonPrimitives` (Shift+click).
  /// Expands non-primitives down the full hierarchy.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onExpandNonPrimitivesRecursive;

  /// Recursive variant of `onConvertToBlocksOnly` (Shift+click).
  /// Converts to blocks-only down the full hierarchy.
  final Future<SchematicLayoutResult?> Function(String nodeId)?
      onConvertToBlocksOnlyRecursive;

  /// Callback to partially expand a node to reveal a specific wire by name.
  /// Finds the hyperedge matching `wireName` and reveals its connected
  /// children plus the wire itself.
  final Future<SchematicLayoutResult?> Function(String nodeId, String wireName)?
      onExpandWire;

  /// Callback to partially expand a specific child of a node by name.
  /// Used by the search/navigate routine to reveal only the path to
  /// a target without fully expanding every level.
  final Future<SchematicLayoutResult?> Function(
    String nodeId,
    String childName,
  )? onExpandChild;

  /// Batch-expand an entire hierarchy path in a single layout cycle.
  ///
  /// `pathSegments` are instance names from top to bottom.
  /// If `targetWireName` is non-null the last segment is treated as the
  /// container of that wire; otherwise it is the target module.
  final Future<SchematicLayoutResult?> Function(
    List<String> pathSegments, {
    String? targetWireName,
  })? onExpandPath;

  /// Callback to look up the signal name connected to an exterior port.
  ///
  /// Given the owning instance ID and port ID, returns the hyperedge
  /// (signal) name from the parent scope, or null if unknown.
  final String? Function(String nodeId, String portId)? signalNameForPort;

  /// Callback when the user wants to send selected signals to other viewers.
  /// Receives a list of fully-qualified signal paths
  /// (e.g. ``"top/adder0/sum", "top/adder0/carry"``).
  final void Function(List<String> signalPaths)? onSendSignals;

  /// Resolves the directly connected port driver for a selected wire.
  ///
  /// Receives the wire name and its fully-qualified containing scope.
  final String? Function(String wireName, String scopePath)?
      directDriverSignalPath;

  /// Whether external widgets (e.g. waveform viewer, signal table) are
  /// listening for signals sent via `onSendSignals`.
  ///
  /// When `false`, the "Send Signals" context-menu item is hidden even if
  /// `onSendSignals` is non-null.  Defaults to `true` for backwards
  /// compatibility (the menu appears whenever `onSendSignals` is provided).
  final bool hasExternalSignalListeners;

  /// Callback to navigate to a signal's source for a chosen [RohdSourceFormat].
  final GoToSourceCallback? onGoToSource;

  /// Called before showing the right-click context menu to discover which
  /// source formats are navigable for the current module.  Uses cached module
  /// info — must be synchronous so showMenu works.
  final AvailableSourceFormats? availableSourceFormats;

  /// Notifier for incoming signal paths from other viewers (cross-probing).
  ///
  /// When the value changes, matching wires are added to the multi-selection.
  final ValueNotifier<List<String>?>? incomingSignalPaths;

  /// Creates a schematic canvas widget.
  const SchematicCanvas({
    required this.layout,
    super.key,
    this.netlistJson,
    this.externalHierarchy,
    this.colorScheme = SchematicColorScheme.dark,
    this.onNodeToggle,
    this.onPortExpand,
    this.onPortExpandThrough,
    this.onPortCollapse,
    this.onPortCollapseThrough,
    this.onCollapsePartial,
    this.onExpandNonPrimitives,
    this.onConvertToBlocksOnly,
    this.onNodeToggleRecursive,
    this.onExpandNonPrimitivesRecursive,
    this.onConvertToBlocksOnlyRecursive,
    this.onExpandWire,
    this.onExpandChild,
    this.onExpandPath,
    this.pendingToggleNodeId,
    this.recentlyToggledNodeId,
    this.isDimmed = false,
    this.signalValueLookup,
    this.signalNameForPort,
    this.focusPortId,
    this.onSendSignals,
    this.directDriverSignalPath,
    this.hasExternalSignalListeners = true,
    this.onGoToSource,
    this.availableSourceFormats,
    this.incomingSignalPaths,
  });

  @override
  State<SchematicCanvas> createState() => SchematicCanvasState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<SchematicLayoutResult>('layout', layout))
      ..add(
        DiagnosticsProperty<SchematicColorScheme>('colorScheme', colorScheme),
      )
      ..add(StringProperty('netlistJson', netlistJson))
      ..add(
        DiagnosticsProperty<HierarchyService?>(
          'externalHierarchy',
          externalHierarchy,
        ),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String)?>.has('onNodeToggle', onNodeToggle),
      )
      ..add(StringProperty('pendingToggleNodeId', pendingToggleNodeId))
      ..add(StringProperty('recentlyToggledNodeId', recentlyToggledNodeId))
      ..add(DiagnosticsProperty<bool>('isDimmed', isDimmed))
      ..add(StringProperty('focusPortId', focusPortId))
      ..add(
        ObjectFlagProperty<
            ({String value, bool computed, String signalId})? Function(
                String)?>.has('signalValueLookup', signalValueLookup),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String, String)?>.has('onPortExpand', onPortExpand),
      )
      ..add(
        ObjectFlagProperty<
                Future<SchematicLayoutResult?> Function(String, String)?>.has(
            'onPortExpandThrough', onPortExpandThrough),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String)?>.has('onCollapsePartial', onCollapsePartial),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String)?>.has('onExpandNonPrimitives', onExpandNonPrimitives),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String)?>.has('onConvertToBlocksOnly', onConvertToBlocksOnly),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
                String, String)?>.has('onExpandChild', onExpandChild),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
              List<String>, {
              String? targetWireName,
            })?>.has('onExpandPath', onExpandPath),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(String nodeId,
                String portId)?>.has('onPortCollapse', onPortCollapse),
      )
      ..add(
        ObjectFlagProperty<
                Future<SchematicLayoutResult?> Function(
                    String nodeId, String portId)?>.has(
            'onPortCollapseThrough', onPortCollapseThrough),
      )
      ..add(
        ObjectFlagProperty<
                Future<SchematicLayoutResult?> Function(String nodeId)?>.has(
            'onNodeToggleRecursive', onNodeToggleRecursive),
      )
      ..add(
        ObjectFlagProperty<
                Future<SchematicLayoutResult?> Function(String nodeId)?>.has(
            'onExpandNonPrimitivesRecursive', onExpandNonPrimitivesRecursive),
      )
      ..add(
        ObjectFlagProperty<
                Future<SchematicLayoutResult?> Function(String nodeId)?>.has(
            'onConvertToBlocksOnlyRecursive', onConvertToBlocksOnlyRecursive),
      )
      ..add(
        ObjectFlagProperty<
            Future<SchematicLayoutResult?> Function(
              String nodeId,
              String wireName,
            )?>.has('onExpandWire', onExpandWire),
      )
      ..add(
        ObjectFlagProperty<String? Function(String nodeId, String portId)?>.has(
          'signalNameForPort',
          signalNameForPort,
        ),
      )
      ..add(
        ObjectFlagProperty<void Function(List<String> signalPaths)?>.has(
          'onSendSignals',
          onSendSignals,
        ),
      )
      ..add(
        ObjectFlagProperty<
                String? Function(String wireName, String scopePath)?>.has(
            'directDriverSignalPath', directDriverSignalPath),
      )
      ..add(
        DiagnosticsProperty<bool>(
          'hasExternalSignalListeners',
          hasExternalSignalListeners,
        ),
      )
      ..add(
        ObjectFlagProperty<GoToSourceCallback?>.has(
          'onGoToSource',
          onGoToSource,
        ),
      )
      ..add(
        ObjectFlagProperty<AvailableSourceFormats?>.has(
          'availableSourceFormats',
          availableSourceFormats,
        ),
      )
      ..add(
        DiagnosticsProperty<ValueNotifier<List<String>?>?>(
          'incomingSignalPaths',
          incomingSignalPaths,
        ),
      );
  }
}

/// State for `SchematicCanvas`, made public so that the embedding viewer
/// can read/write the current pan offset and zoom scale via a `GlobalKey`.
class SchematicCanvasState extends State<SchematicCanvas> {
  final GlobalKey _exportBoundaryKey = GlobalKey();
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// When true, the painter suppresses interactive-only decorations
  /// (expand/collapse icons) so they don't appear in PNG snapshots.
  final ValueNotifier<bool> _snapshotModeNotifier = ValueNotifier(false);

  /// The view-transform notifier drives CustomPaint repaints without
  /// a full widget build() during zoom/pan.
  late final ValueNotifier<({double scale, Offset offset})>
      _viewTransformNotifier = ValueNotifier((scale: _scale, offset: _offset));

  /// Convenience: update _scale, _offset, and fire the notifier.
  void _setViewTransform(double scale, Offset offset) {
    _scale = scale;
    _offset = offset;
    _viewTransformNotifier.value = (scale: scale, offset: offset);
  }

  /// Current zoom scale (for external read by embedding viewer).
  double get currentScale => _scale;

  /// Current pan offset (for external read by embedding viewer).
  Offset get currentOffset => _offset;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('currentScale', currentScale))
      ..add(DiagnosticsProperty<Offset>('currentOffset', currentOffset));
  }

  /// Set the view position directly (offset + scale) without triggering
  /// auto-fit. Used to restore a cached view position.
  void setView({required Offset offset, required double scale}) {
    _pendingAutoFitSkips++;
    _setViewTransform(scale, offset);
  }

  Offset? _lastFocalPoint;
  double? _lastScale;
  String? _highlightedWireName;
  String? _selectedEdgeScope; // The nodeId scope of the currently selected wire
  String? _highlightedNodeId;

  /// Wire IDs currently selected via click/Ctrl+click.
  final Set<String> _selectedWireIds = {};

  /// Scope paths for each selected wire, keyed by wireId.
  final Map<String, String?> _selectedWireScopePaths = {};

  /// Node/instance IDs currently selected (support mixed wire+node selection).
  final Set<String> _selectedNodeIds = {};

  /// Notifier for the hovered boundary port.  Writing to this fires
  /// `paint()` directly via the merged repaint listenable — no `setState()`.
  late final ValueNotifier<({String? portId, bool isInterior})>
      _hoveredBoundaryPortNotifier = ValueNotifier((
    portId: null,
    isInterior: false,
  ));

  /// Convenience getter so existing code can still read the port ID.
  String? get _hoveredBoundaryPortId =>
      _hoveredBoundaryPortNotifier.value.portId;

  /// Convenience getter for the interior flag.
  bool get _hoveredBoundaryPortIsInterior =>
      _hoveredBoundaryPortNotifier.value.isInterior;

  /// The instance (node) ID that owns the hovered boundary port.
  /// Needed so the click handler knows which node to collapse on.
  String? _hoveredBoundaryNodeId;

  /// Update the boundary hover state without calling `setState()`.
  void _setHoveredBoundaryPort({
    required String? portId,
    required String? nodeId,
    required bool isInterior,
  }) {
    _hoveredBoundaryNodeId = nodeId;
    _hoveredBoundaryPortNotifier.value = (
      portId: portId,
      isInterior: isInterior,
    );
  }

  Offset? _scaleStartPosition;
  bool _hasMoved = false;
  static const double _tapTolerance = 10;
  static const double _wireSelectionRadius = 10;

  Offset? _pointerDownPosition;
  int? _pointerDownButton;

  final FocusNode _focusNode = FocusNode();

  late final ValueNotifier<bool> _showSearchOverlayNotifier =
      ValueNotifier<bool>(false);
  HierarchyService? _hierarchy;
  LayoutHierarchyBridge? _bridge;
  // Skip the next automatic fit-to-canvas calls when we intentionally zoom
  // (e.g., search-driven expands)
  int _pendingAutoFitSkips = 0;

  /// Deferred zoom action scheduled by search handlers.
  ///
  /// When a search-driven expansion produces a new layout, the zoom must
  /// wait until the widget has been rebuilt and painted with that layout.
  /// The action is executed in a post-frame callback once
  /// `_pendingAutoFitSkips` reaches zero inside `didUpdateWidget`.
  VoidCallback? _pendingZoomAction;

  // Zoom-to-region state (CONTROL-drag)
  Offset? _zoomRegionStartPoint;
  Offset? _zoomRegionEndPoint;
  bool _isSelectingZoomRegion = false;
  late final ValueNotifier<
          ({Offset? startPoint, Offset? endPoint, bool isSelecting})>
      _zoomRegionNotifier;

  // Hover tooltip state - use ValueNotifier to avoid rebuilding the canvas.
  // Supports both wire tooltips and module instance tooltips.
  late final ValueNotifier<
          ({String? tooltipKey, List<String> lines, Offset position})>
      _hoverTooltipNotifier;
  OverlayEntry? _tooltipOverlay;
  ScrollController? _tooltipScrollController;
  String? _currentTooltipKey;
  Timer? _tooltipDismissTimer;
  bool _mouseInTooltip = false;

  bool get _tooltipHasScrollableContent {
    final controller = _tooltipScrollController;
    if (_tooltipOverlay == null ||
        controller == null ||
        !controller.hasClients) {
      return false;
    }
    final position = controller.position;
    return position.maxScrollExtent > position.minScrollExtent;
  }

  /// The hierarchy-scope path of the currently hovered wire or port.
  /// Set **before** `_hoverTooltipNotifier` is updated so that
  /// `_updateTooltipOverlay` can construct a fully-qualified signal-ID
  /// for snapshot lookups (e.g. `"top/adder0/sum"` instead of just
  /// `"sum"`).
  String? _lastHoverScopePath;

  /// The hierarchy address of the currently hovered wire (from edge.addr).
  /// When non-null, enables O(1) address-based snapshot lookup, bypassing
  /// the slower string path matching cascade.
  List<int>? _lastHoverAddr;

  // Throttle hover detection to reduce CPU load
  DateTime? _lastHoverCheck;
  Offset? _lastHoverPosition;
  static const _hoverThrottleMs = 32; // Check at most every 32ms (~30 FPS)
  static const _hoverDistanceThreshold = 5.0; // Min pixels moved to recheck

  // Prevent simultaneous node toggles (debounce guard)

  // ── Cached lookup maps for hover hit-testing (rebuilt on layout change) ──
  Map<String, SchematicInstanceData> _instanceLookup = {};
  Map<String, SchematicInstanceData> _hierLookup = {};
  Map<String, SchematicPortData> _portLookup = {};
  Object? _cachedLayoutIdentity;

  /// Lazily rebuild hover lookup maps when the layout object changes.
  void _ensureHoverLookups() {
    final layout = widget.layout;
    if (identical(layout, _cachedLayoutIdentity)) {
      return;
    }
    _cachedLayoutIdentity = layout;
    _instanceLookup = {for (final inst in layout.instances) inst.id: inst};
    _hierLookup = {
      for (final inst in layout.instances)
        if (inst.hierarchyPath != null) inst.hierarchyPath!: inst,
    };
    _portLookup = {for (final port in layout.ports) port.id: port};
  }

  bool _isProcessingToggle = false;

  // Always-updated mouse position (no throttle), used for anchoring
  // the search overlay at the cursor.
  Offset? _currentMousePosition;

  // Position where the search overlay should appear (captured when
  // CTRL-F is pressed).
  Offset? _searchOverlayPosition;

  @override
  void initState() {
    super.initState();
    _zoomRegionNotifier = ValueNotifier((
      startPoint: null,
      endPoint: null,
      isSelecting: false,
    ));
    _hoverTooltipNotifier = ValueNotifier((
      tooltipKey: null,
      lines: <String>[],
      position: Offset.zero,
    ));
    _hoverTooltipNotifier.addListener(_updateTooltipOverlay);
    SignalValueFormatRegistry.changes.addListener(
      _refreshTooltipForFormatChange,
    );
    // Listen to search overlay notifier to rebuild only when visibility changes
    _showSearchOverlayNotifier.addListener(_onSearchOverlayChanged);
    _buildNetlistIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitToCanvas();
    });

    // Cross-probing: listen for incoming signal paths from other viewers.
    widget.incomingSignalPaths?.addListener(_onIncomingSignals);
    // Process the current value in case it was set before we mounted.
    if (widget.incomingSignalPaths?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_onIncomingSignals());
        }
      });
    }
  }

  /// Handle incoming cross-probed signal paths by expanding the hierarchy
  /// and highlighting the wires, reusing the same expand-and-zoom logic
  /// that the search overlay uses.
  ///
  /// For the first signal path, delegates to `_handleWireSearchSelection`
  /// which traverses the block hierarchy, expanding blocks as needed and
  /// finally expanding connectivity at the leaf.  For additional signals
  /// in the same scope, their wires are also expanded so edges become
  /// visible, and all wire names are added to the multi-selection set.
  Future<void> _onIncomingSignals() async {
    final paths = widget.incomingSignalPaths?.value;
    debugPrint(
      '[CrossProbe:Canvas] _onIncomingSignals fired, '
      'paths=$paths, mounted=$mounted',
    );
    if (paths == null || paths.isEmpty) {
      return;
    }

    final currentScopeId = _findCurrentScopeNodeId(widget.layout);
    final currentScopePath = currentScopeId == null
        ? null
        : widget.layout.instances
            .where((instance) => instance.id == currentScopeId)
            .firstOrNull
            ?.hierarchyPath;

    // Parse each path "Root/mod1/mod2/signal" into intermediate instance
    // names and a wire name. Paths from another viewer are rooted at the
    // design top, while this canvas may already display a lower-level scope.
    final parsed = <({String wireName, List<String> intermediates})>[];
    for (final fullPath in paths) {
      final segments = fullPath.split('/');
      if (segments.length < 2) {
        continue; // need at least root + signal
      }
      // Strip any bit-slice / sub-field suffix (e.g. "sig#b[7:4]") so the
      // schematic resolves to the underlying wire ("sig"). Cross-probe IDs
      // for struct sub-fields and bit ranges encode the slice after '#',
      // which the schematic operates below (it highlights whole wires).
      final wireName = segments.last.split('#').first;
      final currentScopeSegments = currentScopePath?.split('/');
      final relativeStart = currentScopeSegments != null &&
              currentScopeSegments.length < segments.length &&
              _isPathPrefix(currentScopeSegments, segments)
          ? currentScopeSegments.length
          : 1;
      final intermediates =
          segments.sublist(relativeStart, segments.length - 1);
      parsed.add((wireName: wireName, intermediates: intermediates));
    }

    if (parsed.isEmpty) {
      return;
    }

    // Use the search expansion flow for the first signal to expand the
    // hierarchy and zoom to it.
    final first = parsed.first;
    debugPrint(
      '[CrossProbe:Canvas] expanding via search handler: '
      'wireName=${first.wireName}, '
      'intermediates=${first.intermediates}',
    );
    await _handleWireSearchSelection(first.wireName, first.intermediates);

    // Expand additional same-scope wires so their edges become visible.
    // After the first expansion, _selectedEdgeScope holds the scope node.
    if (parsed.length > 1) {
      final scopeId =
          _selectedEdgeScope ?? _findCurrentScopeNodeId(widget.layout);

      for (final p in parsed.skip(1)) {
        // Only expand wires that share the same scope (same intermediates).
        if (_listEquals(p.intermediates, first.intermediates)) {
          if (scopeId != null && widget.onExpandWire != null) {
            debugPrint(
              '[CrossProbe:Canvas] expanding additional wire: '
              '${p.wireName} in scope $scopeId',
            );
            final newLayout = await widget.onExpandWire!(scopeId, p.wireName);
            if (newLayout != null) {
              _pendingAutoFitSkips++;
            }
          }
        }
      }

      // Add all wire names to the multi-selection highlight set.
      setState(() {
        for (final p in parsed) {
          _selectedWireIds.add(p.wireName);
          _selectedWireScopePaths[p.wireName] = _selectedEdgeScope;
        }
      });
    }

    // Override the pending zoom (which targets only the first wire) so
    // that once all layout rebuilds finish the view fits ALL received wires.
    final allWireIds = parsed.map((p) => p.wireName).toSet();
    _pendingZoomAction = () {
      _zoomToWires(allWireIds);
    };
  }

  /// Compare two string lists for equality.
  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _isPathPrefix(List<String> prefix, List<String> path) {
    if (prefix.length > path.length) {
      return false;
    }
    for (var index = 0; index < prefix.length; index++) {
      if (prefix[index] != path[index]) {
        return false;
      }
    }
    return true;
  }

  void _buildNetlistIndex() {
    // Use external hierarchy if provided (shared from DevTools)
    if (widget.externalHierarchy != null) {
      _hierarchy = widget.externalHierarchy;
      _bridge = LayoutHierarchyBridge.build(
        hierarchy: _hierarchy!,
        layout: widget.layout,
      );
    } else if (widget.netlistJson != null) {
      // Build generic hierarchy via netlist adapter
      _hierarchy = NetlistHierarchyAdapter.fromJson(widget.netlistJson!);
      _bridge = LayoutHierarchyBridge.build(
        hierarchy: _hierarchy!,
        layout: widget.layout,
      );
    } else {
      _hierarchy = null;
      _bridge = null;
    }
  }

  @override
  void dispose() {
    widget.incomingSignalPaths?.removeListener(_onIncomingSignals);
    SignalValueFormatRegistry.changes.removeListener(
      _refreshTooltipForFormatChange,
    );
    _focusNode.dispose();
    _zoomRegionNotifier.dispose();
    _viewTransformNotifier.dispose();
    _hoveredBoundaryPortNotifier.dispose();
    _showSearchOverlayNotifier
      ..removeListener(_onSearchOverlayChanged)
      ..dispose();
    _hoverTooltipNotifier.removeListener(_updateTooltipOverlay);
    _tooltipDismissTimer?.cancel();
    _tooltipDismissTimer = null;
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
    _tooltipScrollController?.dispose();
    _tooltipScrollController = null;
    _hoverTooltipNotifier.dispose();
    super.dispose();
  }

  void _onSearchOverlayChanged() {
    setState(() {});
  }

  // ── Port marker hover hit-testing ──────────────────────────────────────

  /// Hit-test the bowtie port markers at `schematicPos` (in schematic coords).
  ///
  /// Returns a tuple of (tooltipText, tooltipKey) when the cursor is over a
  /// port marker, or null otherwise.
  ///
  /// * **Interior half** → port name (e.g. "data_in").
  /// * **Exterior half** → connected wire name (e.g. "sig_out (8)").
  /// Given a hierarchy path like `"top/adder0"`, return the parent scope
  /// `"top"`.  Returns `null` for root-level paths without a `/`.
  static String? _parentScopeOf(String? hierarchyPath) {
    if (hierarchyPath == null) {
      return null;
    }
    final i = hierarchyPath.lastIndexOf('/');
    return i >= 0 ? hierarchyPath.substring(0, i) : null;
  }

  /// Hit-test all port pins on child instances (not just bowtie markers).
  /// Returns `(displayName, scopePath)` where `scopePath` is the hierarchy
  /// prefix for signal-value lookup, or `null` when no port is hit.
  ///
  /// This complements `_hitTestPortMarker` which only detects bowties on
  /// ports with hidden connections.  Here we detect the port pin area itself
  /// on any non-external-port instance, enabling value lookup when hovering
  /// on a child-instance port that has visible wires (no bowtie).
  (String, String?)? _hitTestPortPin(Offset schematicPos) {
    final layout = widget.layout;
    final instanceLookup = <String, SchematicInstanceData>{};
    for (final inst in layout.instances) {
      instanceLookup[inst.id] = inst;
    }

    for (final port in layout.ports) {
      final parentInstance = instanceLookup[port.instanceId];
      if (parentInstance == null || parentInstance.isExternalPort) {
        continue;
      }

      // Skip CONCAT/SLICE ports – their hit areas block edge hover detection.
      if (parentInstance.cls == 'Operator' &&
          OperatorShapes.isConcatSlice(parentInstance.name)) {
        continue;
      }

      // Use the port's layout rect with padding for comfortable hovering.
      const pad = 4.0;
      final hitRect = Rect.fromLTWH(
        port.x - pad,
        port.y - pad,
        port.width + pad * 2,
        port.height + pad * 2,
      );
      if (!hitRect.contains(schematicPos)) {
        continue;
      }

      // Try to resolve the connected signal name at the parent scope so
      // the tooltip shows the wire name (e.g. "sum`7:0`") instead of the
      // raw port name ("A").
      final signalName = widget.signalNameForPort?.call(
        port.instanceId,
        port.id,
      );
      if (signalName != null && signalName.isNotEmpty) {
        // Use the parent module scope for value lookup.
        final exteriorScope = _parentScopeOf(parentInstance.hierarchyPath);
        return (signalName, exteriorScope);
      }

      // Fallback: check if a visible edge is connected to this port and
      // use its wire name.
      for (final edge in layout.edges) {
        if (edge.sourcePort == port.id || edge.targetPort == port.id) {
          var wireName = edge.wireId;
          if (edge.signalWidth > 1) {
            wireName = '${edge.wireId} (${edge.signalWidth})';
          }
          final exteriorScope = _parentScopeOf(parentInstance.hierarchyPath);
          return (wireName, exteriorScope);
        }
      }

      // Last resort: show the port's own name with the instance scope.
      final scope = parentInstance.hierarchyPath;
      return (port.name.isNotEmpty ? port.name : port.id, scope);
    }
    return null;
  }

  /// Compute the marker hit rect for a port, optionally inflated by `pad`.
  static Rect _portMarkerRect(SchematicPortData port, {double pad = 0.0}) {
    const markerW = 5.0;
    const markerH = 8.0;
    const h = SchematicConstants.portPinHeight;

    final double markerLeft;
    final double markerRight;
    final double markerTop;
    final double markerBottom;
    if (port.side == 'NORTH' || port.side == 'SOUTH') {
      final blockTouchY = port.side == 'NORTH' ? port.y + port.height : port.y;
      final portCenterX = port.x + port.width / 2;
      markerLeft = portCenterX - markerH / 2;
      markerRight = portCenterX + markerH / 2;
      markerTop = blockTouchY - markerW;
      markerBottom = blockTouchY + markerW;
    } else {
      final blockTouchX = port.side == 'WEST' ? port.x + port.width : port.x;
      markerLeft = blockTouchX - markerW;
      markerRight = blockTouchX + markerW;
      markerTop = port.y + (h - markerH) / 2;
      markerBottom = port.y + (h + markerH) / 2;
    }

    return Rect.fromLTRB(
      markerLeft - pad,
      markerTop - pad,
      markerRight + pad,
      markerBottom + pad,
    );
  }

  /// Whether `schematicPos` falls inside the hit zone of the currently
  /// hovered boundary port marker.  Used to keep the marker visible
  /// while the cursor moves from the wire onto the marker triangle.
  bool _isInsideHoveredBoundaryPortMarker(Offset schematicPos) {
    if (_hoveredBoundaryPortId == null) {
      return false;
    }
    for (final port in widget.layout.ports) {
      if (port.id != _hoveredBoundaryPortId) {
        continue;
      }
      return _portMarkerRect(port, pad: 4).contains(schematicPos);
    }
    return false;
  }

  /// Update `_hoveredBoundaryPortId` when the cursor is near a wire.
  ///
  /// Given a hovered `edge`, finds the closest endpoint port that sits on
  /// the boundary of an expanded/partially-expanded instance.  Also
  /// determines whether the marker should be drawn on the interior or
  /// exterior face of the boundary:
  ///
  ///  • **Interior** – the edge lives inside the module (its scope path
  ///    matches the instance's hierarchy path).  The marker appears on
  ///    the inner face of the module boundary.
  ///  • **Exterior** – the edge lives in the parent scope.  The marker
  ///    appears on the outer face of the module boundary.
  void _updateHoveredBoundaryPort(SchematicEdgeData edge, Offset schematicPos) {
    final layout = widget.layout;
    _ensureHoverLookups();

    // Candidate port IDs from this edge.
    final candidates = <(String portId, String instanceId)>[];
    if (edge.sourcePort != null && edge.source != null) {
      candidates.add((edge.sourcePort!, edge.source!));
    }
    if (edge.targetPort != null && edge.target != null) {
      candidates.add((edge.targetPort!, edge.target!));
    }

    // Find candidate ports that sit on a module boundary.
    String? bestPortId;
    String? bestNodeId;
    var bestDist = double.infinity;
    var bestIsInterior = false;

    for (final (portId, instId) in candidates) {
      final inst = _instanceLookup[instId];
      if (inst == null) {
        continue;
      }

      // Determine interior vs exterior.  If the edge scope matches
      // this instance's hierarchy path the wire is inside the module
      // (interior); otherwise it's in the parent scope (exterior).
      final isInterior = edge.scopeHierarchyPath != null &&
          inst.hierarchyPath != null &&
          edge.scopeHierarchyPath == inst.hierarchyPath;

      // For interior ports: the instance itself must be
      // expanded/partially-expanded (it owns the visible interior).
      // For exterior ports: the *scope* (parent) node must be
      // expanded/partially-expanded — the child is just a visible
      // block within it.
      if (isInterior) {
        if (!inst.isExpanded && !inst.isPartiallyExpanded) {
          continue;
        }
      } else {
        // Exterior: look up the scope (parent) instance.
        final scopeInst = edge.scopeHierarchyPath != null
            ? _hierLookup[edge.scopeHierarchyPath!]
            : null;
        if (scopeInst == null ||
            (!scopeInst.isExpanded && !scopeInst.isPartiallyExpanded)) {
          continue;
        }
      }

      // For collapse callbacks, we need the *scope* node ID (the one
      // whose partialChildIds/partialHyperedgeIds are being mutated).
      // Interior: scope = this instance.  Exterior: scope = parent.
      final collapseNodeId = isInterior
          ? instId
          : (edge.scopeHierarchyPath != null
              ? _hierLookup[edge.scopeHierarchyPath!]?.id
              : null);
      if (collapseNodeId == null) {
        continue;
      }

      // Find the port data to compute distance.
      final port = _portLookup[portId];
      if (port != null) {
        final px = port.x + port.width / 2;
        final py = port.y + port.height / 2;
        final dist = (schematicPos - Offset(px, py)).distance;
        if (dist < bestDist) {
          bestDist = dist;
          bestPortId = portId;
          bestNodeId = collapseNodeId;
          bestIsInterior = isInterior;
        }
      }
    }

    // When the best candidate wire hover is on the opposite side from
    // where the cursor actually is, and the cursor's side has its own
    // hidden connections, suppress this boundary hover so the bowtie
    // expansion handler can route the click to the correct side.
    if (bestPortId != null) {
      for (final port in layout.ports) {
        if (port.id == bestPortId) {
          if (_portMarkerRect(port, pad: 2).contains(schematicPos)) {
            final cursorOnInterior = _isCursorOnInteriorHalf(
              port,
              schematicPos,
            );
            if (!bestIsInterior &&
                cursorOnInterior &&
                layout.interiorHiddenPortIds.contains(bestPortId)) {
              // Exterior wire hover but cursor is on interior half
              // which has its own hidden connections → suppress.
              bestPortId = null;
              bestNodeId = null;
            } else if (bestIsInterior &&
                !cursorOnInterior &&
                layout.exteriorHiddenPortIds.contains(bestPortId)) {
              // Interior wire hover but cursor is on exterior half
              // which has its own hidden connections → suppress.
              bestPortId = null;
              bestNodeId = null;
            }
          }
          break;
        }
      }
    }

    if (bestPortId != _hoveredBoundaryPortId ||
        bestIsInterior != _hoveredBoundaryPortIsInterior) {
      _setHoveredBoundaryPort(
        portId: bestPortId,
        nodeId: bestNodeId,
        isInterior: bestIsInterior,
      );
    }
  }

  /// Returns `true` when `schematicPos` is on the interior half of the
  /// port marker area (the half facing into the submodule rather than
  /// outward toward the parent scope).
  static bool _isCursorOnInteriorHalf(
    SchematicPortData port,
    Offset schematicPos,
  ) {
    if (port.side == 'WEST') {
      return schematicPos.dx >= (port.x + port.width);
    } else if (port.side == 'EAST') {
      return schematicPos.dx <= port.x;
    } else if (port.side == 'NORTH') {
      return schematicPos.dy >= (port.y + port.height);
    } else {
      // SOUTH
      return schematicPos.dy <= port.y;
    }
  }

  /// Try to activate a boundary port hover based on proximity to the
  /// port's marker area rather than the wire itself.
  ///
  /// This allows the user to hover directly on the port pin (where the
  /// marker triangle appears) without needing to find the wire first.
  /// Returns `true` if a boundary port was activated.
  bool _tryActivateBoundaryPortFromPortProximity(Offset schematicPos) {
    final layout = widget.layout;
    _ensureHoverLookups();

    // Reduce padding to prevent hover boxes from overlapping on densely
    // spaced ports (e.g., flip-flop D/clk/reset). This makes it easier to
    // select the correct port without accidentally hovering a neighbor.
    const pad = 2.0;

    for (final edge in layout.edges) {
      // Check both endpoints of this edge.
      final endpoints = <(String portId, String instanceId)>[];
      if (edge.sourcePort != null && edge.source != null) {
        endpoints.add((edge.sourcePort!, edge.source!));
      }
      if (edge.targetPort != null && edge.target != null) {
        endpoints.add((edge.targetPort!, edge.target!));
      }

      for (final (portId, instId) in endpoints) {
        final port = _portLookup[portId];
        if (port == null) {
          continue;
        }

        // Quick spatial check: is cursor near this port's marker?
        if (!_portMarkerRect(port, pad: pad).contains(schematicPos)) {
          continue;
        }

        // Check if this port sits on a boundary (same logic as
        // _updateHoveredBoundaryPort).
        final inst = _instanceLookup[instId];
        if (inst == null) {
          continue;
        }

        final isInterior = edge.scopeHierarchyPath != null &&
            inst.hierarchyPath != null &&
            edge.scopeHierarchyPath == inst.hierarchyPath;

        if (isInterior) {
          if (!inst.isExpanded && !inst.isPartiallyExpanded) {
            continue;
          }
        } else {
          final scopeInst = edge.scopeHierarchyPath != null
              ? _hierLookup[edge.scopeHierarchyPath!]
              : null;
          if (scopeInst == null ||
              (!scopeInst.isExpanded && !scopeInst.isPartiallyExpanded)) {
            continue;
          }
        }

        final collapseNodeId = isInterior
            ? instId
            : (edge.scopeHierarchyPath != null
                ? _hierLookup[edge.scopeHierarchyPath!]?.id
                : null);
        if (collapseNodeId == null) {
          continue;
        }

        // When the cursor is on the opposite half from this edge's
        // side and that half has its own hidden connections, skip
        // this edge so the bowtie expansion handler can route the
        // click to the correct side.
        final cursorOnInterior = _isCursorOnInteriorHalf(port, schematicPos);
        if (!isInterior &&
            cursorOnInterior &&
            layout.interiorHiddenPortIds.contains(portId)) {
          continue;
        }
        if (isInterior &&
            !cursorOnInterior &&
            layout.exteriorHiddenPortIds.contains(portId)) {
          continue;
        }

        // Found a valid boundary port under cursor — activate it.
        if (portId != _hoveredBoundaryPortId ||
            isInterior != _hoveredBoundaryPortIsInterior) {
          _setHoveredBoundaryPort(
            portId: portId,
            nodeId: collapseNodeId,
            isInterior: isInterior,
          );
        }
        return true;
      }
    }
    return false;
  }

  /// Hit-test port bowtie markers.  Returns `(displayName, scopePath)` where
  /// `scopePath` is the hierarchy prefix for signal-value lookup, or `null`
  /// when the port has no hierarchy metadata.
  (String, String?)? _hitTestPortMarker(Offset schematicPos) {
    final layout = widget.layout;

    // Lazily build lookup structures each hover cycle.  The layout
    // reference doesn't change during a single hovered frame, and the
    // cost is trivial compared to iterating ports.
    final instanceLookup = <String, SchematicInstanceData>{};
    for (final inst in layout.instances) {
      instanceLookup[inst.id] = inst;
    }
    final portToEdge = <String, SchematicEdgeData>{};
    for (final edge in layout.edges) {
      if (edge.sourcePort != null) {
        portToEdge[edge.sourcePort!] = edge;
      }
      if (edge.targetPort != null) {
        portToEdge[edge.targetPort!] = edge;
      }
    }

    for (final port in layout.ports) {
      final parentInstance = instanceLookup[port.instanceId];
      if (parentInstance == null || parentInstance.isExternalPort) {
        continue;
      }

      // Hierarchy scope paths for signal-value lookup.
      //  • interior: the instance's own path (e.g. "top/adder0")
      //  • exterior: the parent module scope (e.g. "top")
      final interiorScope = parentInstance.hierarchyPath;
      final exteriorScope = _parentScopeOf(parentInstance.hierarchyPath);

      // Exterior marker: shown only when port has a hidden parent-scope wire.
      final hasExteriorMarker = layout.exteriorHiddenPortIds.contains(port.id);
      // Interior marker: shown only when port has a hidden internal wire.
      final hasInteriorMarker = layout.interiorHiddenPortIds.contains(port.id);
      if (!hasExteriorMarker && !hasInteriorMarker) {
        continue;
      }

      final portX = port.x;
      final portY = port.y;
      const h = SchematicConstants.portPinHeight;
      const markerW = 5.0;
      const markerH = 8.0;

      final double markerLeft;
      final double markerRight;
      final double markerTop;
      final double markerBottom;
      if (port.side == 'NORTH' || port.side == 'SOUTH') {
        final blockTouchY = port.side == 'NORTH' ? portY + port.height : portY;
        final portCenterX = portX + port.width / 2;
        markerLeft = portCenterX - markerH / 2;
        markerRight = portCenterX + markerH / 2;
        markerTop = blockTouchY - markerW;
        markerBottom = blockTouchY + markerW;
      } else {
        final blockTouchX = port.side == 'WEST' ? portX + port.width : portX;
        markerLeft = blockTouchX - markerW;
        markerRight = blockTouchX + markerW;
        markerTop = portY + (h - markerH) / 2;
        markerBottom = portY + (h + markerH) / 2;
      }

      final hitRect = Rect.fromLTRB(
        markerLeft - 2,
        markerTop - 2,
        markerRight + 2,
        markerBottom + 2,
      );

      if (!hitRect.contains(schematicPos)) {
        continue;
      }

      // Determine exterior vs interior half.
      bool isExteriorHalf;
      if (port.side == 'WEST') {
        isExteriorHalf = schematicPos.dx < (portX + port.width);
      } else if (port.side == 'EAST') {
        isExteriorHalf = schematicPos.dx > portX;
      } else if (port.side == 'NORTH') {
        isExteriorHalf = schematicPos.dy < (portY + port.height);
      } else {
        isExteriorHalf = schematicPos.dy > portY;
      }

      if (isExteriorHalf && hasExteriorMarker) {
        // Exterior → look up connected signal name from parent hyperedges.
        final signalName = widget.signalNameForPort?.call(
          port.instanceId,
          port.id,
        );
        if (signalName != null && signalName.isNotEmpty) {
          return (signalName, exteriorScope);
        }
        // Fallback: check visible edge, then port name.
        final edge = portToEdge[port.id];
        if (edge != null) {
          var wireName = edge.wireId;
          if (edge.signalWidth > 1) {
            wireName = '${edge.wireId} (${edge.signalWidth})';
          }
          return (wireName, exteriorScope);
        }
        return (port.name.isNotEmpty ? port.name : port.id, exteriorScope);
      } else if (!isExteriorHalf && hasInteriorMarker) {
        // Interior → port name.
        return (port.name.isNotEmpty ? port.name : port.id, interiorScope);
      } else if (hasExteriorMarker && !hasInteriorMarker) {
        // Only exterior marker drawn — anywhere in hit zone.
        final signalName = widget.signalNameForPort?.call(
          port.instanceId,
          port.id,
        );
        if (signalName != null && signalName.isNotEmpty) {
          return (signalName, exteriorScope);
        }
        final edge = portToEdge[port.id];
        if (edge != null) {
          var wireName = edge.wireId;
          if (edge.signalWidth > 1) {
            wireName = '${edge.wireId} (${edge.signalWidth})';
          }
          return (wireName, exteriorScope);
        }
        return (port.name.isNotEmpty ? port.name : port.id, exteriorScope);
      } else if (hasInteriorMarker && !hasExteriorMarker) {
        // Only interior marker drawn.
        return (port.name.isNotEmpty ? port.name : port.id, interiorScope);
      }
    }
    return null;
  }

  // ── Search overlay positioning helpers ──────────────────────────────────

  static const _overlayWidth = 400.0;
  static const _overlayMaxHeight = 400.0;

  /// Compute the `top` value for the search overlay `Positioned`.
  double _searchOverlayTop(BuildContext context) {
    final anchor = _searchOverlayPosition;
    if (anchor != null) {
      final renderBox = context.findRenderObject() as RenderBox?;
      final maxH = renderBox?.size.height ?? MediaQuery.sizeOf(context).height;
      return anchor.dy.clamp(
        0.0,
        (maxH - _overlayMaxHeight).clamp(0.0, double.infinity),
      );
    }
    return 60;
  }

  /// Compute the `left` value for the search overlay `Positioned`.
  double _searchOverlayLeft(BuildContext context) {
    final anchor = _searchOverlayPosition;
    final renderBox = context.findRenderObject() as RenderBox?;
    final maxW = renderBox?.size.width ?? MediaQuery.sizeOf(context).width;
    if (anchor != null) {
      return anchor.dx.clamp(
        0.0,
        (maxW - _overlayWidth).clamp(0.0, double.infinity),
      );
    }
    // Fallback: top-right position.
    return (maxW - _overlayWidth - 20).clamp(0.0, double.infinity);
  }

  void _dismissTooltip({bool immediate = false}) {
    _tooltipDismissTimer?.cancel();
    _tooltipDismissTimer = null;
    if (!immediate && _mouseInTooltip) {
      return;
    }
    if (_tooltipOverlay != null) {
      _tooltipOverlay!.remove();
      _tooltipOverlay = null;
      _tooltipScrollController?.dispose();
      _tooltipScrollController = null;
      _currentTooltipKey = null;
      _mouseInTooltip = false;
    }
  }

  void _scheduleDismissTooltip() {
    if (_mouseInTooltip) {
      return;
    }
    _tooltipDismissTimer?.cancel();
    _tooltipDismissTimer = Timer(const Duration(milliseconds: 300), () {
      _tooltipDismissTimer = null;
      if (!_mouseInTooltip) {
        _dismissTooltip(immediate: true);
      }
    });
  }

  void _refreshTooltipForFormatChange() {
    _currentTooltipKey = null;
    _updateTooltipOverlay();
  }

  void _updateTooltipOverlay() {
    final hover = _hoverTooltipNotifier.value;

    if (hover.tooltipKey == null) {
      _scheduleDismissTooltip();
      return;
    }
    // A new tooltip is being shown — cancel any pending dismiss.
    _tooltipDismissTimer?.cancel();
    _tooltipDismissTimer = null;

    // Only create/update if key changed or overlay doesn't exist
    if (_tooltipOverlay == null || _currentTooltipKey != hover.tooltipKey) {
      _tooltipOverlay?.remove();
      _currentTooltipKey = hover.tooltipKey;

      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox == null) {
        return;
      }
      final globalPos = renderBox.localToGlobal(hover.position);

      // Build tooltip lines: the first line is the primary label,
      // additional lines are secondary info (signal value, port counts).
      final primaryLine = hover.lines.isNotEmpty ? hover.lines.first : '';
      final secondaryLines =
          hover.lines.length > 1 ? hover.lines.sublist(1) : <String>[];

      // For wire and port tooltips, look up signal value if available
      final isWireOrPort = hover.tooltipKey!.startsWith('wire:') ||
          hover.tooltipKey!.startsWith('port:');
      String? signalValue;
      String? resolvedSignalId;
      var isComputedValue = false;
      if (isWireOrPort) {
        var lookupName = primaryLine;
        final busLabel = _parseTrailingBusWidth(lookupName);
        int? busWidth;
        if (busLabel.matched) {
          busWidth = busLabel.width;
          lookupName = busLabel.name;
        }

        // Try address-based O(1) lookup first when available.
        final hoverAddr = _lastHoverAddr;
        if (hoverAddr != null && widget.signalValueLookup != null) {
          final addrKey = '@addr:${hoverAddr.join('.')}';
          final addrResult = widget.signalValueLookup!.call(addrKey);
          if (addrResult != null) {
            signalValue = addrResult.value;
            isComputedValue = addrResult.computed;
            resolvedSignalId = addrResult.signalId;
          }
        }

        // Fall back to string path lookup.
        if (signalValue == null) {
          final scopePath = _lastHoverScopePath;
          if (scopePath != null && scopePath.isNotEmpty) {
            lookupName = '$scopePath/$lookupName';
          }

          final lookupResult = widget.signalValueLookup?.call(lookupName);
          if (lookupResult != null) {
            signalValue = lookupResult.value;
            isComputedValue = lookupResult.computed;
            resolvedSignalId = lookupResult.signalId;
          }
        }

        // Apply the waveform-selected occurrence format when available.
        if (signalValue != null) {
          final hierarchy = _hierarchy;
          final hoverAddr = _lastHoverAddr;
          OccurrenceAddress? occurrenceAddress;
          if (hierarchy != null && hoverAddr != null) {
            final signal = hierarchy.signalByAddress(
              OccurrenceAddress(hoverAddr),
            );
            if (signal != null) {
              occurrenceAddress = signal.address;
              lookupName = signal.path();
              busWidth ??= signal.width;
            }
          }
          final selectedFormat = SignalValueFormatRegistry.formatForAny([
            occurrenceAddress,
            hierarchy?.pathnameToAddress(resolvedSignalId ?? ''),
            hierarchy?.pathnameToAddress(lookupName),
            hierarchy?.pathnameToAddress(primaryLine),
          ]);
          signalValue = SignalValueFormatRegistry.formatValue(
            signalValue,
            selectedFormat,
            busWidth ?? 1,
          );
        }
      }

      // Look up type metadata for structured tooltip display.
      List<String>? structLines;
      if (signalValue != null && _hierarchy != null) {
        // Look up signal from hierarchy by name/scope path.
        SignalOccurrence? sig;
        if (_lastHoverAddr != null) {
          sig = _hierarchy!.signalByAddress(OccurrenceAddress(_lastHoverAddr!));
        }
        if (sig == null) {
          // Fall back to pathname lookup using scope + signal name.
          final sigName = _parseTrailingBusWidth(primaryLine).name;
          final scopePath = _lastHoverScopePath;
          final fullPath = (scopePath != null && scopePath.isNotEmpty)
              ? '$scopePath/$sigName'
              : sigName;
          final sigAddr = _hierarchy!.pathnameToAddress(fullPath);
          if (sigAddr != null) {
            sig = _hierarchy!.signalByAddress(sigAddr);
          }
        }
        if (sig != null && (sig.isStruct || sig.isArray)) {
          // Extract raw hex from the formatted Verilog literal (e.g. "9'h1a").
          final rawHex = _extractRawHex(signalValue);
          final binary = hexToBinary(rawHex, sig.width);
          debugPrint(
            '[STRUCT-DBG] signalValue=$signalValue rawHex=$rawHex '
            'sig.width=${sig.width} binary=$binary '
            'logicType=${sig.logicType}',
          );
          if (binary != null) {
            final tooltip = formatTypeTooltip(
              sig.logicType,
              parentBinaryValue: binary,
              signalName: sig.name,
            );
            if (tooltip.isNotEmpty) {
              structLines = tooltip.split('\n');
            }
          }
        }
      }

      _tooltipScrollController?.dispose();
      _tooltipScrollController = ScrollController();

      _tooltipOverlay = OverlayEntry(
        builder: (context) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final isDark = theme.brightness == Brightness.dark;
          final bgColor = isDark
              ? const Color(0xFF3C3C3C).withValues(alpha: 0.85)
              : colors.surfaceContainer.withValues(alpha: 0.95);
          final borderColor = isDark
              ? Colors.white.withValues(alpha: 0.1)
              : colors.outlineVariant.withValues(alpha: 0.3);
          final primaryTextColor = colors.onSurface;
          final secondaryTextColor =
              isDark ? const Color(0xFF90CAF9) : colors.primary;
          final computedValueColor = isDark
              ? const Color(0xFFFFD54F)
              : const Color(0xFFF57C00); // orange for light mode

          return Positioned(
            left: globalPos.dx + 10,
            top: globalPos.dy + 10,
            child: MouseRegion(
              onEnter: (_) {
                _mouseInTooltip = true;
                _tooltipDismissTimer?.cancel();
                _tooltipDismissTimer = null;
              },
              onExit: (_) {
                _mouseInTooltip = false;
                _dismissTooltip(immediate: true);
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: _handleTooltipPointerSignal,
                child: Material(
                  color: Colors.transparent,
                  elevation: 8,
                  shadowColor: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          primaryLine,
                          style: TextStyle(
                            color: primaryTextColor,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        for (final line in secondaryLines)
                          Text(
                            line,
                            style: TextStyle(
                              color: secondaryTextColor,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        if (signalValue != null && structLines != null)
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              // ~10 lines at 11pt + leading ≈ 150px
                              maxHeight: 150,
                            ),
                            child: SingleChildScrollView(
                              controller: _tooltipScrollController,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final line in structLines)
                                    Text(
                                      line,
                                      style: TextStyle(
                                        color: isComputedValue
                                            ? computedValueColor
                                            : secondaryTextColor,
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          )
                        else if (signalValue != null)
                          Text(
                            signalValue,
                            style: TextStyle(
                              // Yellow/orange for computed/const values (evaluated
                              // extension-side), blue/primary for VM-fetched values.
                              color: isComputedValue
                                  ? computedValueColor
                                  : secondaryTextColor,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );

      Overlay.of(context).insert(_tooltipOverlay!);
    }
  }

  @override
  void didUpdateWidget(covariant SchematicCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Swap incoming signal listener if the notifier reference changed.
    if (widget.incomingSignalPaths != oldWidget.incomingSignalPaths) {
      oldWidget.incomingSignalPaths?.removeListener(_onIncomingSignals);
      widget.incomingSignalPaths?.addListener(_onIncomingSignals);
    }
    // Clear stale hover tooltip when layout or data changes
    if (widget.layout != oldWidget.layout ||
        widget.externalHierarchy != oldWidget.externalHierarchy ||
        widget.netlistJson != oldWidget.netlistJson) {
      _dismissTooltip(immediate: true);
      _hoverTooltipNotifier.value = (
        tooltipKey: null,
        lines: <String>[],
        position: Offset.zero,
      );
    }
    // Rebuild hierarchy if external hierarchy or netlistJson changed
    if (widget.externalHierarchy != oldWidget.externalHierarchy ||
        widget.netlistJson != oldWidget.netlistJson) {
      _buildNetlistIndex();
    }
    // Rebuild bridge if layout changed and hierarchy present
    if (widget.layout != oldWidget.layout && _hierarchy != null) {
      _bridge = LayoutHierarchyBridge.build(
        hierarchy: _hierarchy!,
        layout: widget.layout,
      );
    }
    if (widget.layout != oldWidget.layout) {
      if (_pendingAutoFitSkips > 0) {
        _pendingAutoFitSkips--;
        // When the last suppressed rebuild arrives and a search-driven
        // zoom is pending, schedule it for after this frame so the new
        // layout has been fully laid-out and painted.
        if (_pendingAutoFitSkips == 0 && _pendingZoomAction != null) {
          final zoomAction = _pendingZoomAction!;
          _pendingZoomAction = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              zoomAction();
            }
          });
        }
      } else {
        // Capture the port's viewport position BEFORE the post-frame
        // callback so we can keep it in the same spot after re-layout.
        Offset? portViewportAnchor;
        final portId = widget.focusPortId;
        if (portId != null && portId.isNotEmpty) {
          for (final oldPort in oldWidget.layout.ports) {
            if (oldPort.id == portId) {
              final cx = oldPort.x + oldPort.width / 2;
              final cy = oldPort.y + oldPort.height / 2;
              portViewportAnchor = Offset(
                cx * _scale + _offset.dx,
                cy * _scale + _offset.dy,
              );
              break;
            }
          }
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Port-level focus takes priority: pan so the port stays
          // in its original viewport position (or centred if unknown).
          if (portId != null && portId.isNotEmpty) {
            _focusOnPort(portId, viewportAnchor: portViewportAnchor);
            return;
          }
          // If a node was just toggled, zoom to fit that node; otherwise
          // fit entire layout.
          final targetNodeId = widget.recentlyToggledNodeId;
          if (targetNodeId != null && targetNodeId.isNotEmpty) {
            _fitToNode(targetNodeId);
          } else {
            _fitToCanvas();
          }
        });
      }
    }
  }

  /// Check if a node is a descendant of (or equal to) the scope node
  bool _isNodeInScope(String? nodeId, String scopeId) {
    if (nodeId == null) {
      return false;
    }
    if (nodeId == scopeId) {
      return true;
    }

    if (_bridge != null) {
      return _bridge!.isInstanceInScope(nodeId, scopeId);
    }

    // Fallback: walk the layout's parent map directly
    String? current = nodeId;
    var maxIterations = 100; // Safety limit
    while (current != null && maxIterations-- > 0) {
      if (current == scopeId) {
        return true;
      }
      current = widget.layout.parentMap[current];
    }

    return false;
  }

  /// Returns true if either Control key is currently pressed.
  bool _isControlPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
  }

  /// Returns true if either Shift key is currently pressed.
  bool _isShiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  /// Check if a port has any visible edges in the current layout.
  /// Returns true if any edge connects to this port.
  bool _portHasVisibleEdges(String portId) {
    for (final edge in widget.layout.edges) {
      if (edge.sourcePort == portId || edge.targetPort == portId) {
        return true;
      }
    }
    return false;
  }

  /// Compute the true bounds of the layout (nodes/ports/edges) so we can
  /// normalize away any non-zero origin emitted by ELK/d3.
  Rect _computeLayoutBounds() {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    var touched = false;

    for (final node in widget.layout.instances) {
      minX = math.min(minX, node.x);
      minY = math.min(minY, node.y);
      maxX = math.max(maxX, node.x + node.width);
      maxY = math.max(maxY, node.y + node.height);
      touched = true;
    }

    for (final port in widget.layout.ports) {
      minX = math.min(minX, port.x);
      minY = math.min(minY, port.y);
      maxX = math.max(maxX, port.x + port.width);
      maxY = math.max(maxY, port.y + port.height);
      touched = true;
    }

    for (final edge in widget.layout.edges) {
      for (final point in edge.points) {
        minX = math.min(minX, point.x);
        minY = math.min(minY, point.y);
        maxX = math.max(maxX, point.x);
        maxY = math.max(maxY, point.y);
        touched = true;
      }
    }

    if (!touched) {
      return Rect.fromLTWH(0, 0, widget.layout.width, widget.layout.height);
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  void _fitToCanvas() {
    if (!mounted) {
      return;
    }

    final size = context.size;
    if (size == null || size.isEmpty) {
      return;
    }

    final bounds = _computeLayoutBounds();
    final layoutWidth = bounds.width;
    final layoutHeight = bounds.height;

    if (layoutWidth <= 0 || layoutHeight <= 0) {
      return;
    }

    // Increased padding to ensure content isn't cut off by AppBar or edges
    const padding = 60.0;
    final scaleX = (size.width - padding) / layoutWidth;
    final scaleY = (size.height - padding) / layoutHeight;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);

    final scaledWidth = layoutWidth * scale;
    final scaledHeight = layoutHeight * scale;
    final offsetX = (size.width - scaledWidth) / 2 - bounds.left * scale;
    final offsetY = (size.height - scaledHeight) / 2 - bounds.top * scale;

    // DEBUG: Log _fitToCanvas calls
    if (SchematicPainter._debugPaintFrequency) {
      debugPrint(
        '[SchematicCanvas] _fitToCanvas called, '
        'new offset: ($offsetX, $offsetY), scale: $scale',
      );
    }

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Export the visible schematic as a PNG image.
  ///
  /// When running inside a VS Code webview, routes through the extension host
  /// which shows a native Save dialog.  Otherwise falls back to the default
  /// platform download/save.
  Future<void> _exportToPng() async {
    _snapshotModeNotifier.value = true;
    // Wait for the frame to rebuild so the export button is hidden
    // before capturing the RepaintBoundary.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    try {
      await captureBoundaryToPng(
        context,
        boundaryKey: _exportBoundaryKey,
        filePrefix: 'schematic',
        pixelRatio: 6,
        saveFn: vscode_interop.isVscodeWebview() ? _vscodeSavePng : null,
      );
    } finally {
      _snapshotModeNotifier.value = false;
    }
  }

  /// Save PNG bytes through the VS Code extension host (native Save dialog).
  Future<String?> _vscodeSavePng(Uint8List pngBytes, String fileName) async {
    vscode_interop.postSavePng(
      pngBase64: base64Encode(pngBytes),
      suggestedName: fileName,
    );
    return null;
  }

  /// Zoom to fit a specific node (for focused view after expansion)
  void _fitToNode(String nodeId) {
    if (!mounted) {
      return;
    }

    final size = context.size;
    if (size == null || size.isEmpty) {
      return;
    }

    // Find the target node and all its descendants
    final bounds = _computeNodeBounds(nodeId);
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) {
      // Node not found or empty, fall back to fitting entire canvas
      _fitToCanvas();
      return;
    }

    const padding = 40.0;
    final scaleX = (size.width - padding) / bounds.width;
    final scaleY = (size.height - padding) / bounds.height;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);

    final scaledWidth = bounds.width * scale;
    final scaledHeight = bounds.height * scale;
    final offsetX = (size.width - scaledWidth) / 2 - bounds.left * scale;
    final offsetY = (size.height - scaledHeight) / 2 - bounds.top * scale;

    // DEBUG: Log _fitToNode calls
    if (SchematicPainter._debugPaintFrequency) {
      debugPrint(
        '[SchematicCanvas] _fitToNode($nodeId) called, '
        'new offset: ($offsetX, $offsetY), scale: $scale',
      );
    }

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Pan so that `portId` stays at its previous viewport position.
  ///
  /// After incremental port expansion the layout may shift significantly.
  /// If `viewportAnchor` is provided (the port's pre-expansion viewport
  /// position), the transform is adjusted so the port remains exactly
  /// there.  If the anchor is `null` (e.g. the port was not visible before),
  /// the port is centred in the viewport instead.
  void _focusOnPort(String portId, {Offset? viewportAnchor}) {
    if (!mounted) {
      return;
    }

    final size = context.size;
    if (size == null || size.isEmpty) {
      return;
    }

    // Find the port in the new layout.
    SchematicPortData? target;
    for (final port in widget.layout.ports) {
      if (port.id == portId) {
        target = port;
        break;
      }
    }

    if (target == null) {
      // Port not found (e.g. child block removed by collapse) — fall back
      // to fitting the toggled node if available, otherwise the canvas.
      final fallbackNodeId = widget.recentlyToggledNodeId;
      if (fallbackNodeId != null && fallbackNodeId.isNotEmpty) {
        _fitToNode(fallbackNodeId);
      } else {
        _fitToCanvas();
      }
      return;
    }

    // Centre of the port in schematic-space.
    final portCX = target.x + target.width / 2;
    final portCY = target.y + target.height / 2;

    // Keep the current zoom level.
    final scale = _scale;

    // Use the pre-expansion viewport position if available; otherwise
    // fall back to viewport centre.
    final anchorX = viewportAnchor?.dx ?? size.width / 2;
    final anchorY = viewportAnchor?.dy ?? size.height / 2;

    // Compute offset so (portCX, portCY) maps to the anchor position.
    final offsetX = anchorX - portCX * scale;
    final offsetY = anchorY - portCY * scale;

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Compute bounds for a specific node and all its children/descendants
  Rect? _computeNodeBounds(String targetNodeId) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    final idToInstance = <String, SchematicInstanceData>{
      for (final n in widget.layout.instances) n.id: n,
    };

    if (!idToInstance.containsKey(targetNodeId)) {
      return null;
    }

    final toVisit = <String>[targetNodeId];
    final visited = <String>{};

    while (toVisit.isNotEmpty) {
      final currentId = toVisit.removeLast();
      if (visited.contains(currentId)) {
        continue;
      }
      visited.add(currentId);

      final instance = idToInstance[currentId];
      if (instance == null) {
        continue;
      }

      minX = math.min(minX, instance.x);
      minY = math.min(minY, instance.y);
      maxX = math.max(maxX, instance.x + instance.width);
      maxY = math.max(maxY, instance.y + instance.height);

      for (final childId in instance.children) {
        if (!visited.contains(childId)) {
          toVisit.add(childId);
        }
      }

      for (final port in widget.layout.ports) {
        if (port.instanceId == currentId) {
          minX = math.min(minX, port.x);
          minY = math.min(minY, port.y);
          maxX = math.max(maxX, port.x + port.width);
          maxY = math.max(maxY, port.y + port.height);
        }
      }
    }

    if (visited.isEmpty) {
      return null;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Handle mouse down for zoom-to-region: record the start point.
  /// Only active when Control is pressed.
  void _onZoomRegionMouseDown(Offset localPosition) {
    if (!_isControlPressed()) {
      return;
    }

    _zoomRegionStartPoint = localPosition;
    _zoomRegionEndPoint = localPosition;
    _isSelectingZoomRegion = true;

    _zoomRegionNotifier.value = (
      startPoint: localPosition,
      endPoint: localPosition,
      isSelecting: true,
    );
  }

  /// Handle mouse drag for zoom-to-region: update the end point to show the
  /// selection overlay. Only active when Control is pressed.
  void _onZoomRegionMouseDrag(Offset localPosition) {
    if (!_isControlPressed()) {
      return;
    }
    if (!_isSelectingZoomRegion || _zoomRegionStartPoint == null) {
      return;
    }

    _zoomRegionEndPoint = localPosition;

    _zoomRegionNotifier.value = (
      startPoint: _zoomRegionStartPoint,
      endPoint: localPosition,
      isSelecting: _isSelectingZoomRegion,
    );
  }

  /// Handle mouse up for zoom-to-region: finalize the region and zoom.
  /// Called when the pan gesture ends.
  void _onZoomRegionMouseUp() {
    // Don't check _isControlPressed() here - use _isSelectingZoomRegion
    // to determine if a zoom selection was in progress
    if (!_isSelectingZoomRegion ||
        _zoomRegionStartPoint == null ||
        _zoomRegionEndPoint == null) {
      _isSelectingZoomRegion = false;
      _zoomRegionStartPoint = null;
      _zoomRegionEndPoint = null;

      _zoomRegionNotifier.value = (
        startPoint: null,
        endPoint: null,
        isSelecting: false,
      );
      return;
    }

    final start = _zoomRegionStartPoint!;
    final end = _zoomRegionEndPoint!;

    // Calculate the normalized rectangle
    final minX = start.dx < end.dx ? start.dx : end.dx;
    final maxX = start.dx < end.dx ? end.dx : start.dx;
    final minY = start.dy < end.dy ? start.dy : end.dy;
    final maxY = start.dy < end.dy ? end.dy : start.dy;

    final width = maxX - minX;
    final height = maxY - minY;

    // Require a minimum drag distance to avoid accidental tiny zooms
    if (width < 10 || height < 10) {
      _isSelectingZoomRegion = false;
      _zoomRegionStartPoint = null;
      _zoomRegionEndPoint = null;

      _zoomRegionNotifier.value = (
        startPoint: null,
        endPoint: null,
        isSelecting: false,
      );
      return;
    }

    // Determine drag direction for zoom in/out
    // Forward (upper-left to lower-right): zoom in
    // Backward (lower-right to upper-left): zoom out
    final isForwardDrag = start.dx < end.dx && start.dy < end.dy;

    if (!mounted) {
      return;
    }

    final size = context.size;
    if (size == null || size.isEmpty) {
      _isSelectingZoomRegion = false;
      _zoomRegionStartPoint = null;
      _zoomRegionEndPoint = null;
      return;
    }

    // Calculate new scale and offset
    if (isForwardDrag) {
      // Zoom in: fit the selected rectangle to the viewport
      // First convert the viewport rectangle corners to schematic coordinates
      final schematicMinX = (minX - _offset.dx) / _scale;
      final schematicMaxX = (maxX - _offset.dx) / _scale;
      final schematicMinY = (minY - _offset.dy) / _scale;
      final schematicMaxY = (maxY - _offset.dy) / _scale;

      final schematicWidth = schematicMaxX - schematicMinX;
      final schematicHeight = schematicMaxY - schematicMinY;

      // Calculate new scale to fit the schematic region to the viewport
      final scaleX = size.width / schematicWidth;
      final scaleY = size.height / schematicHeight;
      final newScale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 10.0);

      // Position the schematic region at the top-left of the viewport
      final newOffsetX = -schematicMinX * newScale;
      final newOffsetY = -schematicMinY * newScale;

      _setViewTransform(newScale, Offset(newOffsetX, newOffsetY));
    } else {
      // Zoom out: expand view to show more context
      // Calculate the zoom factor (inverse of zoom in)
      final scaleX = size.width / width;
      final scaleY = size.height / height;
      const outZoomFactor = 1.5; // Zoom out by 1.5x

      final newScale =
          (_scale / (scaleX < scaleY ? scaleX : scaleY) * outZoomFactor).clamp(
        0.05,
        10.0,
      );

      // Keep approximately the center of the selection in view
      final centerX = (minX + maxX) / 2;
      final centerY = (minY + maxY) / 2;

      final schematicCenterX = (centerX - _offset.dx) / _scale;
      final schematicCenterY = (centerY - _offset.dy) / _scale;

      final newOffsetX = size.width / 2 - schematicCenterX * newScale;
      final newOffsetY = size.height / 2 - schematicCenterY * newScale;

      _setViewTransform(newScale, Offset(newOffsetX, newOffsetY));
    }

    // Clear the zoom region selection
    _isSelectingZoomRegion = false;
    _zoomRegionStartPoint = null;
    _zoomRegionEndPoint = null;

    _zoomRegionNotifier.value = (
      startPoint: null,
      endPoint: null,
      isSelecting: false,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    // Don't zoom the canvas while the search overlay is open;
    // scroll events should go to the overlay's result list instead.
    if (_showSearchOverlayNotifier.value) {
      return;
    }
    // Only suppress canvas zoom when the hover tooltip has scrollable
    // content. Plain signal hovers should still allow wheel zoom.
    if (_tooltipHasScrollableContent) {
      if (event is PointerScrollEvent) {
        final pos = _tooltipScrollController!.position;
        final newOffset = (pos.pixels + event.scrollDelta.dy).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        _tooltipScrollController!.jumpTo(newOffset);
      }
      return;
    }
    _zoomForPointerScroll(event, event.localPosition);
  }

  /// Forwards tooltip wheel input to the canvas unless the tooltip can scroll.
  void _handleTooltipPointerSignal(PointerSignalEvent event) {
    if (_tooltipHasScrollableContent || event is! PointerScrollEvent) {
      return;
    }

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }
    _zoomForPointerScroll(event, renderBox.globalToLocal(event.position));
  }

  void _zoomForPointerScroll(PointerSignalEvent event, Offset focalPoint) {
    if (event is PointerScrollEvent) {
      final zoomDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
      final newScale = (_scale * zoomDelta).clamp(0.05, 10.0);

      final oldOffset = _offset;

      final schematicX = (focalPoint.dx - oldOffset.dx) / _scale;
      final schematicY = (focalPoint.dy - oldOffset.dy) / _scale;

      final newOffsetX = focalPoint.dx - schematicX * newScale;
      final newOffsetY = focalPoint.dy - schematicY * newScale;

      _setViewTransform(newScale, Offset(newOffsetX, newOffsetY));
    }
  }

  /// Build the list of fully-qualified signal paths from the current
  /// selection (multi-selected wires + optional single highlighted wire).
  ///
  /// Paths use the hierarchy-node-id convention from the netlist
  /// (definition-name-based), e.g. `"TopModule/signalName"`.
  List<String> _collectSelectedSignalPaths() {
    final paths = <String>[];

    // Collect from multi-selection
    for (final wireId in _selectedWireIds) {
      final scopePath = _lookupScopeHierarchyPath(wireId);
      if (scopePath != null) {
        paths.add('$scopePath/$wireId');
      } else {
        paths.add(wireId);
      }
    }

    // If no multi-selection, use the single highlighted wire
    if (paths.isEmpty && _highlightedWireName != null) {
      final scopePath = _lookupScopeHierarchyPath(_highlightedWireName!);
      if (scopePath != null) {
        paths.add('$scopePath/$_highlightedWireName');
      } else {
        paths.add(_highlightedWireName!);
      }
    }

    return paths;
  }

  /// Adds a direct port driver for each selected internal wire when known.
  List<String> _collectSendSignalPaths(List<String> signalPaths) {
    final sendPaths = <String>{...signalPaths};
    for (final signalPath in signalPaths) {
      final separator = signalPath.lastIndexOf('/');
      if (separator <= 0 || separator == signalPath.length - 1) {
        continue;
      }
      final driverPath = widget.directDriverSignalPath?.call(
        signalPath.substring(separator + 1),
        signalPath.substring(0, separator),
      );
      if (driverPath != null) {
        sendPaths.add(driverPath);
      }
    }
    // TODO(desmonddak): Send explicit fallback-driver metadata instead of
    // appending drivers to this legacy list-only cross-probe protocol.
    return sendPaths.toList(growable: false);
  }

  /// Find the `scopeHierarchyPath` for the first layout edge matching
  /// `wireId`.  Returns `null` if no edge or no hierarchy path is set.
  String? _lookupScopeHierarchyPath(String wireId) {
    for (final edge in widget.layout.edges) {
      if (edge.wireId == wireId && edge.scopeHierarchyPath != null) {
        return edge.scopeHierarchyPath;
      }
    }
    return null;
  }

  /// Build the wire paths passed to `onGoToSource`.
  ///
  /// FLC/embedded-trace source lookups are keyed by module *type* (e.g.
  /// "FilterChannel_T3_W16_0"), not by the enclosing cell's *instance* name
  /// (e.g. "ch0"), which is what [_lookupScopeHierarchyPath] returns. This
  /// resolves the enclosing scope's recorded `definitionName` — when known —
  /// so cross-probing works for any instance whose cell name differs from
  /// its module type, not just the (coincidentally matching) design root.
  /// Falls back to the raw instance-based hierarchy path otherwise.
  List<String> _collectGoToSourceWirePaths() {
    // `_hierLookup` is normally refreshed lazily during hover detection;
    // force it up to date here since a context-menu selection can happen
    // without a preceding hover (e.g. programmatic taps, or a fresh
    // selection made via search).
    _ensureHoverLookups();
    final ids = _selectedWireIds.isNotEmpty
        ? _selectedWireIds
        : (_highlightedWireName != null
            ? {_highlightedWireName!}
            : const <String>{});
    final paths = <String>[];
    for (final wireId in ids) {
      final scopePath = _lookupScopeHierarchyPath(wireId);
      final moduleType =
          scopePath != null ? _hierLookup[scopePath]?.definitionName : null;
      if (moduleType != null && moduleType.isNotEmpty) {
        paths.add('$moduleType/$wireId');
      } else if (scopePath != null) {
        paths.add('$scopePath/$wireId');
      } else {
        paths.add(wireId);
      }
    }
    return paths;
  }

  /// Show a right-click context menu at `position` for selected items
  /// (wires, modules, or a mix).
  void _showWireContextMenu(BuildContext context, Offset position) {
    final wirePaths = _collectSelectedSignalPaths();
    final wireLeafNames = _collectSelectedWireLeafNames();
    final nodeNames = _collectSelectedNodeNames();
    final nodeFullPaths = _collectSelectedNodeFullPaths();
    final hasWires = wirePaths.isNotEmpty;
    final hasNodes = nodeNames.isNotEmpty;
    if (!hasWires && !hasNodes) {
      return;
    }

    final totalCount = wirePaths.length + nodeNames.length;
    final renderBox = this.context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }
    final globalPosition = renderBox.localToGlobal(position);

    // Check if collapse is available (any selected wire has a collapsible
    // port on the scope boundary).
    final canCollapse = hasWires &&
        widget.onPortCollapse != null &&
        _collectCollapseTargets().isNotEmpty;

    // Leaf names (wires + nodes).
    final leafNames = <String>[...wireLeafNames, ...nodeNames];
    // Full hierarchy paths (wires + nodes).
    final fullPaths = <String>[...wirePaths, ...nodeFullPaths];

    // Discover which source formats are navigable for the current module so
    // we only show "Go to …" items for source that actually exists.
    final navigableFormats = widget.onGoToSource != null
        ? (widget.availableSourceFormats?.call() ?? const [])
        : const <RohdSourceFormat>[];
    final showGoToSource = (hasWires || hasNodes) &&
        navigableFormats.isNotEmpty &&
        totalCount <= 2;

    debugPrint(
      '[ContextMenu] hasWires=$hasWires, hasNodes=$hasNodes, '
      'totalCount=$totalCount, navigableFormats=$navigableFormats, '
      'onGoToSource=${widget.onGoToSource != null}, '
      'availableSourceFormats=${widget.availableSourceFormats != null}',
    );

    unawaited(
      showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          globalPosition.dx,
          globalPosition.dy,
          globalPosition.dx,
          globalPosition.dy,
        ),
        items: [
          if (hasWires &&
              widget.onSendSignals != null &&
              widget.hasExternalSignalListeners)
            PopupMenuItem<String>(
              height: 32,
              value: 'send',
              child: Text(
                wirePaths.length == 1
                    ? 'Send Signal'
                    : 'Send ${wirePaths.length} Signals',
              ),
            ),
          if (showGoToSource)
            for (final format in navigableFormats)
              PopupMenuItem<String>(
                height: 32,
                value: gotoSourceMenuValue(format),
                child: Row(
                  children: [
                    sourceFormatMenuIcon(format),
                    const SizedBox(width: 8),
                    Text(gotoSourceMenuLabel(format)),
                  ],
                ),
              ),
          PopupMenuItem<String>(
            height: 32,
            value: 'copy_name',
            child: Text(
              'Copy '
              '${leafNames.length} Name${leafNames.length > 1 ? 's' : ''}',
            ),
          ),
          PopupMenuItem<String>(
            height: 32,
            value: 'copy_path',
            child: Text(
              'Copy '
              '${fullPaths.length} Full Path${fullPaths.length > 1 ? 's' : ''}',
            ),
          ),
          if (canCollapse)
            PopupMenuItem<String>(
              height: 32,
              value: 'collapse',
              child: Text(
                'Collapse ${wirePaths.length} '
                'Signal${wirePaths.length > 1 ? 's' : ''}',
              ),
            ),
          if (totalCount > 0)
            const PopupMenuItem<String>(
              height: 32,
              value: 'fit',
              child: Text('Fit to Selection'),
            ),
        ],
      ).then((value) async {
        final gotoFormat = gotoSourceFormatFromValue(value);
        if (value == 'send' && widget.onSendSignals != null) {
          widget.onSendSignals!(_collectSendSignalPaths(wirePaths));
        } else if (gotoFormat != null && widget.onGoToSource != null) {
          widget.onGoToSource!(gotoFormat, [
            ..._collectGoToSourceWirePaths(),
            ...nodeFullPaths,
          ]);
        } else if (value == 'copy_name') {
          await Clipboard.setData(ClipboardData(text: leafNames.join('\n')));
        } else if (value == 'copy_path') {
          await Clipboard.setData(ClipboardData(text: fullPaths.join('\n')));
        } else if (value == 'collapse') {
          await _collapseSelectedWires();
        } else if (value == 'fit') {
          _fitToSelection();
        }
      }),
    );
  }

  /// Collect display names for all selected nodes.
  List<String> _collectSelectedNodeNames() {
    if (_selectedNodeIds.isEmpty && _highlightedNodeId == null) {
      return [];
    }
    final nodeIds = _selectedNodeIds.isNotEmpty
        ? _selectedNodeIds
        : (_highlightedNodeId != null ? {_highlightedNodeId!} : <String>{});
    final names = <String>[];
    for (final inst in widget.layout.instances) {
      if (nodeIds.contains(inst.id)) {
        names.add(inst.instanceName ?? inst.name);
      }
    }
    return names;
  }

  /// Collect leaf wire names (wireId only, no scope prefix).
  List<String> _collectSelectedWireLeafNames() {
    final ids = _selectedWireIds.isNotEmpty
        ? _selectedWireIds
        : (_highlightedWireName != null ? {_highlightedWireName!} : <String>{});
    return ids.toList();
  }

  /// Collect full hierarchy paths for all selected nodes.
  List<String> _collectSelectedNodeFullPaths() {
    if (_selectedNodeIds.isEmpty && _highlightedNodeId == null) {
      return [];
    }
    final nodeIds = _selectedNodeIds.isNotEmpty
        ? _selectedNodeIds
        : (_highlightedNodeId != null ? {_highlightedNodeId!} : <String>{});
    final paths = <String>[];
    for (final inst in widget.layout.instances) {
      if (nodeIds.contains(inst.id)) {
        paths.add(inst.hierarchyPath ?? inst.instanceName ?? inst.name);
      }
    }
    return paths;
  }

  /// Fit the view to the entire selection (wires + nodes).
  void _fitToSelection() {
    final canvasSize = context.size;
    if (canvasSize == null || canvasSize.isEmpty) {
      return;
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    // Wire edges bounding box
    final wireIds = _selectedWireIds.isNotEmpty
        ? _selectedWireIds
        : (_highlightedWireName != null ? {_highlightedWireName!} : <String>{});
    for (final edge in widget.layout.edges) {
      if (!wireIds.contains(edge.wireId)) {
        continue;
      }
      for (final point in edge.points) {
        if (point.x < minX) {
          minX = point.x;
        }
        if (point.y < minY) {
          minY = point.y;
        }
        if (point.x > maxX) {
          maxX = point.x;
        }
        if (point.y > maxY) {
          maxY = point.y;
        }
      }
    }

    // Node bounding boxes
    final nodeIds = _selectedNodeIds.isNotEmpty
        ? _selectedNodeIds
        : (_highlightedNodeId != null &&
                _selectedWireIds.isEmpty &&
                _highlightedWireName == null
            ? {_highlightedNodeId!}
            : <String>{});
    for (final inst in widget.layout.instances) {
      if (!nodeIds.contains(inst.id)) {
        continue;
      }
      if (inst.x < minX) {
        minX = inst.x;
      }
      if (inst.y < minY) {
        minY = inst.y;
      }
      if (inst.x + inst.width > maxX) {
        maxX = inst.x + inst.width;
      }
      if (inst.y + inst.height > maxY) {
        maxY = inst.y + inst.height;
      }
    }

    if (minX == double.infinity) {
      return;
    }

    const edgePad = 20.0;
    final bounds = Rect.fromLTRB(
      minX - edgePad,
      minY - edgePad,
      maxX + edgePad,
      maxY + edgePad,
    );
    if (bounds.isEmpty) {
      return;
    }

    const viewPad = 40.0;
    final scaleX = (canvasSize.width - viewPad) / bounds.width;
    final scaleY = (canvasSize.height - viewPad) / bounds.height;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);

    final offsetX =
        (canvasSize.width - bounds.width * scale) / 2 - bounds.left * scale;
    final offsetY =
        (canvasSize.height - bounds.height * scale) / 2 - bounds.top * scale;

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Collect the (scopeNodeId, boundaryPortId) pairs needed to collapse
  /// each selected wire.  Returns a deduplicated list.
  List<({String nodeId, String portId})> _collectCollapseTargets() {
    // Use the same scope-resolution approach as _updateHoveredBoundaryPort:
    //   1. hierLookup`edge.scopeHierarchyPath` → scope instance
    //   2. Fallback: _findCurrentScopeNodeId (root of current view)
    // The portId is any edge endpoint — resolvePortId() in schematic_graph
    // can trace it even if it belongs to a child instance.

    final hierLookup = <String, SchematicInstanceData>{};
    for (final inst in widget.layout.instances) {
      if (inst.hierarchyPath != null) {
        hierLookup[inst.hierarchyPath!] = inst;
      }
    }

    final wireIds = _selectedWireIds.isNotEmpty
        ? _selectedWireIds
        : (_highlightedWireName != null ? {_highlightedWireName!} : <String>{});

    final seen = <String>{};
    final targets = <({String nodeId, String portId})>[];

    for (final wireId in wireIds) {
      String? scopeId;
      String? portId;

      for (final edge in widget.layout.edges) {
        if (edge.wireId != wireId) {
          continue;
        }

        // Resolve scope: prefer hierLookup, fallback to root scope.
        if (scopeId == null) {
          if (edge.scopeHierarchyPath != null) {
            scopeId = hierLookup[edge.scopeHierarchyPath!]?.id;
          }
          scopeId ??= _findCurrentScopeNodeId(widget.layout);
        }

        // Use the first available port from any edge of this wire.
        portId ??= edge.sourcePort ?? edge.targetPort;

        if (scopeId != null && portId != null) {
          break;
        }
      }

      if (scopeId == null || portId == null) {
        continue;
      }

      final key = '$scopeId:$portId';
      if (seen.add(key)) {
        targets.add((nodeId: scopeId, portId: portId));
      }
    }
    return targets;
  }

  /// Collapse all selected wires by calling `onPortCollapse` for each.
  Future<void> _collapseSelectedWires() async {
    if (widget.onPortCollapse == null || _isProcessingToggle) {
      return;
    }

    final targets = _collectCollapseTargets();
    if (targets.isEmpty) {
      return;
    }

    _isProcessingToggle = true;
    try {
      for (final t in targets) {
        final result = await widget.onPortCollapse!(t.nodeId, t.portId);
        if (result != null) {
          // Small delay between successive collapses for layout stability.
          if (targets.length > 1) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    } finally {
      _isProcessingToggle = false;
    }

    // Clear selection since the wires are gone.
    setState(() {
      _selectedWireIds.clear();
      _selectedWireScopePaths.clear();
      _highlightedWireName = null;
      _selectedEdgeScope = null;
    });
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _lastFocalPoint = details.focalPoint;
    _lastScale = _scale;
    _scaleStartPosition = details.localFocalPoint;
    _hasMoved = false;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_scaleStartPosition != null && !_hasMoved) {
      final distance =
          (details.localFocalPoint - _scaleStartPosition!).distance;
      if (distance > _tapTolerance || details.scale != 1.0) {
        _hasMoved = true;
      }
    }

    if (_lastScale != null) {
      _scale = (_lastScale! * details.scale).clamp(0.1, 5.0);
    }

    // Disable panning when CONTROL is held (for zoom region selection)
    if (_lastFocalPoint != null && !_isControlPressed()) {
      final delta = details.focalPoint - _lastFocalPoint!;
      _offset = _offset + delta;
      _lastFocalPoint = details.focalPoint;
    }

    _viewTransformNotifier.value = (scale: _scale, offset: _offset);
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _lastFocalPoint = null;
    _lastScale = null;
    _scaleStartPosition = null;
    _hasMoved = false;
  }

  Future<void> _handleTapAtPosition(Offset localPos) async {
    final schematicPos = Offset(
      (localPos.dx - _offset.dx) / _scale,
      (localPos.dy - _offset.dy) / _scale,
    );

    for (final node in widget.layout.instances) {
      if (node.hasChildren && !node.isExternalPort) {
        // Skip if node is too small on screen for visible icons.
        final nodeScreenW = node.width * _scale;
        final nodeScreenH = node.height * _scale;
        if (nodeScreenW < 4 || nodeScreenH < 4) {
          continue;
        }

        // Icon size: fixed 20 screen-px diameter, converted to schematic
        // coords.  Hit-test only fires when the tap is inside the node rect
        // (matching the clipRect used during painting).
        const targetScreenDiameter = 20.0;
        final iconSize = targetScreenDiameter / _scale;

        // Skip when node is too small — icons are hidden below 100 screen-px.
        final minNodeScreen =
            nodeScreenW < nodeScreenH ? nodeScreenW : nodeScreenH;
        if (minNodeScreen < 5 * targetScreenDiameter) {
          continue; // < 100 px
        }

        // Hit-rect padding in schematic coords (≈ 6 screen-px).
        final hitPad = 6.0 / _scale;

        final iconPadding = iconSize * 0.4;
        // Anchor: upper-right corner of the block (matches painting).
        final rightX = node.x + node.width - iconPadding - iconSize / 2;
        final iconCenterY = node.y + iconPadding + iconSize / 2;

        if (node.isPartiallyExpanded) {
          // Partially expanded: (+) at rightX, maybe (⊞), then (−)
          // stacking leftward — must match _drawExpandIndicator layout.
          final showNonPrim = node.hasHiddenNonPrimitiveChildren;
          final gap = iconSize * 0.15;

          final double collapseX;
          final double expandX;
          final double? nonPrimX;

          expandX = rightX;
          if (showNonPrim) {
            nonPrimX = rightX - iconSize - gap;
            collapseX = rightX - 2 * (iconSize + gap);
          } else {
            nonPrimX = null;
            collapseX = rightX - iconSize - gap;
          }

          final collapseRect = Rect.fromCenter(
            center: Offset(collapseX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );
          final expandRect = Rect.fromCenter(
            center: Offset(expandX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );

          if (collapseRect.contains(schematicPos)) {
            // Collapse: clear partial expansion state.
            // Shift+click: recursive collapse.
            if (_isProcessingToggle) {
              return;
            }
            if (_isShiftPressed() && widget.onNodeToggleRecursive != null) {
              _isProcessingToggle = true;
              try {
                await widget.onNodeToggleRecursive!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            } else if (widget.onCollapsePartial != null) {
              _isProcessingToggle = true;
              try {
                await widget.onCollapsePartial!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            }
            return;
          }

          if (nonPrimX != null) {
            final nonPrimRect = Rect.fromCenter(
              center: Offset(nonPrimX, iconCenterY),
              width: iconSize + hitPad,
              height: iconSize + hitPad,
            );
            if (nonPrimRect.contains(schematicPos)) {
              if (_isProcessingToggle) {
                return;
              }
              // Shift+click: recursive expand non-primitives.
              if (_isShiftPressed() &&
                  widget.onExpandNonPrimitivesRecursive != null) {
                _isProcessingToggle = true;
                try {
                  await widget.onExpandNonPrimitivesRecursive!(node.id);
                } finally {
                  _isProcessingToggle = false;
                }
              } else if (widget.onExpandNonPrimitives != null) {
                _isProcessingToggle = true;
                try {
                  await widget.onExpandNonPrimitives!(node.id);
                } finally {
                  _isProcessingToggle = false;
                }
              }
              return;
            }
          }

          if (expandRect.contains(schematicPos)) {
            // Fully expand via toggle.
            // Shift+click: recursive expand.
            if (_isProcessingToggle || widget.onNodeToggle == null) {
              return;
            }
            _isProcessingToggle = true;
            try {
              if (_isShiftPressed() && widget.onNodeToggleRecursive != null) {
                await widget.onNodeToggleRecursive!(node.id);
              } else {
                await widget.onNodeToggle!(node.id);
              }
            } finally {
              _isProcessingToggle = false;
            }
            return;
          }
        } else if (!node.isExpanded && node.hasHiddenNonPrimitiveChildren) {
          // Collapsed with non-primitive hidden children:
          // Two buttons: (+) at rightX, (⊞) to its left.
          final gap = iconSize * 0.15;
          final expandX = rightX;
          final nonPrimX = rightX - iconSize - gap;

          final nonPrimRect = Rect.fromCenter(
            center: Offset(nonPrimX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );
          final expandRect = Rect.fromCenter(
            center: Offset(expandX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );

          if (nonPrimRect.contains(schematicPos)) {
            if (_isProcessingToggle) {
              return;
            }
            // Shift+click: recursive expand non-primitives.
            if (_isShiftPressed() &&
                widget.onExpandNonPrimitivesRecursive != null) {
              _isProcessingToggle = true;
              try {
                await widget.onExpandNonPrimitivesRecursive!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            } else if (widget.onExpandNonPrimitives != null) {
              _isProcessingToggle = true;
              try {
                await widget.onExpandNonPrimitives!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            }
            return;
          }

          if (expandRect.contains(schematicPos)) {
            // Shift+click: recursive expand.
            if (_isProcessingToggle || widget.onNodeToggle == null) {
              return;
            }
            _isProcessingToggle = true;
            try {
              if (_isShiftPressed() && widget.onNodeToggleRecursive != null) {
                await widget.onNodeToggleRecursive!(node.id);
              } else {
                await widget.onNodeToggle!(node.id);
              }
            } finally {
              _isProcessingToggle = false;
            }
            return;
          }
        } else if (node.isExpanded && node.hasNonPrimitiveChildren) {
          // Fully expanded with non-primitive children:
          // Two buttons: (−) collapse left, (⊞) blocks-only right.
          final gap = iconSize * 0.15;
          final blocksX = rightX;
          final collapseX = rightX - iconSize - gap;

          final collapseRect = Rect.fromCenter(
            center: Offset(collapseX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );
          final blocksRect = Rect.fromCenter(
            center: Offset(blocksX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );

          if (collapseRect.contains(schematicPos)) {
            // Shift+click: recursive collapse.
            if (_isProcessingToggle || widget.onNodeToggle == null) {
              return;
            }
            _isProcessingToggle = true;
            try {
              if (_isShiftPressed() && widget.onNodeToggleRecursive != null) {
                await widget.onNodeToggleRecursive!(node.id);
              } else {
                await widget.onNodeToggle!(node.id);
              }
            } finally {
              _isProcessingToggle = false;
            }
            return;
          }

          if (blocksRect.contains(schematicPos)) {
            if (_isProcessingToggle) {
              return;
            }
            // Shift+click: recursive blocks-only.
            if (_isShiftPressed() &&
                widget.onConvertToBlocksOnlyRecursive != null) {
              _isProcessingToggle = true;
              try {
                await widget.onConvertToBlocksOnlyRecursive!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            } else if (widget.onConvertToBlocksOnly != null) {
              _isProcessingToggle = true;
              try {
                await widget.onConvertToBlocksOnly!(node.id);
              } finally {
                _isProcessingToggle = false;
              }
            }
            return;
          }
        } else {
          // Normal two-state: single icon at rightX.
          final iconRect = Rect.fromCenter(
            center: Offset(rightX, iconCenterY),
            width: iconSize + hitPad,
            height: iconSize + hitPad,
          );
          if (iconRect.contains(schematicPos)) {
            // Guard against simultaneous toggles
            if (_isProcessingToggle || widget.onNodeToggle == null) {
              return;
            }

            _isProcessingToggle = true;
            try {
              // Shift+click: recursive toggle.
              if (_isShiftPressed() && widget.onNodeToggleRecursive != null) {
                await widget.onNodeToggleRecursive!(node.id);
              } else {
                await widget.onNodeToggle!(node.id);
              }
            } finally {
              _isProcessingToggle = false;
            }
            return;
          }
        }
      }
    }

    // --- Check hovered boundary port marker for collapse ---
    // When a boundary edge is hovered, a temporary marker is shown on the
    // correct side (interior for internal wires, exterior for parent wires).
    // Clicking it collapses the wire; Shift+clicking collapses recursively.
    //
    // If the collapse is a no-op (nothing changed, e.g. the port was already
    // collapsed), we clear the stale hover and fall through to the bowtie
    // expansion check so the user can re-expand the same port.
    if (_hoveredBoundaryPortId != null &&
        _hoveredBoundaryNodeId != null &&
        !_isProcessingToggle) {
      for (final port in widget.layout.ports) {
        if (port.id != _hoveredBoundaryPortId) {
          continue;
        }

        final hitRect = _portMarkerRect(port, pad: 2);

        if (hitRect.contains(schematicPos)) {
          // If the click lands on the opposite half of the bowtie
          // from the hovered boundary and that half has its own
          // hidden connections, skip the collapse and fall through
          // to the bowtie expansion handler which discriminates
          // exterior vs interior correctly.
          final clickedInterior = _isCursorOnInteriorHalf(port, schematicPos);
          if (clickedInterior != _hoveredBoundaryPortIsInterior) {
            final otherHalfHasAction = clickedInterior
                ? widget.layout.interiorHiddenPortIds.contains(port.id)
                : widget.layout.exteriorHiddenPortIds.contains(port.id);
            if (otherHalfHasAction) {
              _setHoveredBoundaryPort(
                portId: null,
                nodeId: null,
                isInterior: false,
              );
              break;
            }
          }

          _isProcessingToggle = true;
          SchematicLayoutResult? collapseResult;
          try {
            if (_isShiftPressed() && widget.onPortCollapseThrough != null) {
              collapseResult = await widget.onPortCollapseThrough!(
                _hoveredBoundaryNodeId!,
                port.id,
              );
            } else if (widget.onPortCollapse != null) {
              collapseResult = await widget.onPortCollapse!(
                _hoveredBoundaryNodeId!,
                port.id,
              );
            }
          } finally {
            _isProcessingToggle = false;
          }
          if (collapseResult != null) {
            // Collapse succeeded — clear the boundary hover (the wire is
            // gone so the hover is stale) and return.
            _setHoveredBoundaryPort(
              portId: null,
              nodeId: null,
              isInterior: false,
            );
            return;
          }
          // Collapse was a no-op (port already collapsed or nothing to
          // collapse).  Clear stale hover and fall through to the bowtie
          // expansion check below.
          _setHoveredBoundaryPort(
            portId: null,
            nodeId: null,
            isInterior: false,
          );
        }
        break;
      }
    }

    // --- Check interior port markers for incremental expansion ---
    if (widget.onPortExpand != null && !_isProcessingToggle) {
      // Build a quick lookup: instanceId → instance data.
      final instanceLookup = <String, SchematicInstanceData>{};
      for (final inst in widget.layout.instances) {
        instanceLookup[inst.id] = inst;
      }

      for (final port in widget.layout.ports) {
        final parentInstance = instanceLookup[port.instanceId];
        if (parentInstance == null) {
          continue;
        }

        // Must match the painter's guard: skip external-port nodes.
        if (parentInstance.isExternalPort) {
          continue;
        }

        // Must match the painter's marker conditions exactly:
        //  canExpandParent – port has a hidden parent-scope wire
        //                    (exterior marker drawn).
        //  canDrillInto    – port has a hidden module-internal wire
        //                    (interior marker drawn).
        final canExpandParent = widget.layout.exteriorHiddenPortIds.contains(
          port.id,
        );
        final canDrillInto = widget.layout.interiorHiddenPortIds.contains(
          port.id,
        );
        if (!canDrillInto && !canExpandParent) {
          continue;
        }

        // Port coordinates are already in absolute schematic space.
        // The centering offset is 0 for non-operator nodes.
        final portX = port.x;
        final portY = port.y;
        const h = SchematicConstants.portPinHeight;
        const markerW = 5.0;
        const markerH = 8.0;

        // Compute the bounding rect covering BOTH the exterior and
        // interior markers (the bowtie area centred on the block
        // boundary). Handles all four sides.
        final double markerLeft;
        final double markerRight;
        final double markerTop;
        final double markerBottom;

        if (port.side == 'NORTH' || port.side == 'SOUTH') {
          final blockTouchY =
              port.side == 'NORTH' ? portY + port.height : portY;
          final portCenterX = portX + port.width / 2;
          markerLeft = portCenterX - markerH / 2;
          markerRight = portCenterX + markerH / 2;
          markerTop = blockTouchY - markerW;
          markerBottom = blockTouchY + markerW;
        } else {
          // EAST / WEST: paired rectangles centred on blockTouchX.
          final blockTouchX = port.side == 'WEST' ? portX + port.width : portX;
          markerLeft = blockTouchX - markerW;
          markerRight = blockTouchX + markerW;
          markerTop = portY + (h - markerH) / 2;
          markerBottom = portY + (h + markerH) / 2;
        }

        // Inflate slightly for easier clicking.
        final hitRect = Rect.fromLTRB(
          markerLeft - 2,
          markerTop - 2,
          markerRight + 2,
          markerBottom + 2,
        );

        if (hitRect.contains(schematicPos)) {
          // Determine action based on which HALF of the marker pair
          // was clicked (exterior vs interior).  The exterior half
          // faces outward from the block boundary; the interior half
          // faces inward.
          bool clickedExterior;
          if (port.side == 'WEST') {
            final blockTouchX = portX + port.width;
            clickedExterior = schematicPos.dx < blockTouchX;
          } else if (port.side == 'EAST') {
            final blockTouchX = portX;
            clickedExterior = schematicPos.dx > blockTouchX;
          } else if (port.side == 'NORTH') {
            final blockTouchY = portY + port.height;
            clickedExterior = schematicPos.dy < blockTouchY;
          } else {
            // SOUTH
            final blockTouchY = portY;
            clickedExterior = schematicPos.dy > blockTouchY;
          }

          String? expandNodeId;
          if (clickedExterior && canExpandParent) {
            // Exterior click → expand parent to show outside signal.
            for (final inst in widget.layout.instances) {
              if (inst.children.contains(parentInstance.id)) {
                expandNodeId = inst.id;
                break;
              }
            }
          } else if (!clickedExterior && canDrillInto) {
            // Interior click → drill into the submodule.
            expandNodeId = parentInstance.id;
          } else if (canDrillInto) {
            // Fallback: if only interior action available, use it.
            expandNodeId = parentInstance.id;
          } else if (canExpandParent) {
            // Fallback: if only exterior action available, use it.
            for (final inst in widget.layout.instances) {
              if (inst.children.contains(parentInstance.id)) {
                expandNodeId = inst.id;
                break;
              }
            }
          }

          if (expandNodeId != null) {
            _isProcessingToggle = true;
            try {
              // Shift+click → pass-through traversal or collapse (toggle).
              if (_isShiftPressed()) {
                // Recursive traversal always starts at the port owner. Its
                // interior connectivity may not be loaded yet, in which case
                // the current layout cannot advertise canDrillInto. Starting
                // at the owner lets the callback fetch that connectivity
                // before traversing both inward and outward.
                final traversalNodeId = parentInstance.id;
                // Check if port already has visible edges
                final hasVisibleEdges = _portHasVisibleEdges(port.id);
                if (hasVisibleEdges && widget.onPortCollapseThrough != null) {
                  // Port has visible expanded edges → collapse them
                  await widget.onPortCollapseThrough!(traversalNodeId, port.id);
                } else if (!hasVisibleEdges &&
                    widget.onPortExpandThrough != null) {
                  // Port has no visible edges → expand them
                  await widget.onPortExpandThrough!(traversalNodeId, port.id);
                }
              } else {
                await widget.onPortExpand!(expandNodeId, port.id);
              }
            } finally {
              _isProcessingToggle = false;
            }
          }
          return;
        }
      }
    }

    // ── Pre-compute: instance under cursor ──
    // For leaf (non-expanded) nodes: any click inside the body selects.
    // For expanded containers: only clicks on the boundary stroke select
    // (interior clicks fall through to deselect / background).
    // Done early so Phase B (wire hit-test) can skip when the click is
    // squarely on a primitive node body.
    SchematicInstanceData? leafHit;
    {
      var bestArea = double.infinity;
      // Boundary stroke tolerance in schematic coords (matches paint stroke).
      final boundaryTol = 4.0 / _scale;
      for (final instance in widget.layout.instances) {
        if (instance.isExternalPort) {
          continue;
        }
        final rect = Rect.fromLTWH(
          instance.x,
          instance.y,
          instance.width,
          instance.height,
        );

        final isExpandedContainer =
            (instance.isExpanded || instance.isPartiallyExpanded) &&
                instance.hasChildren;

        if (isExpandedContainer) {
          // Only select if click is near the boundary (within boundaryTol
          // of any edge of the rect) but still inside the rect.
          if (!rect.contains(schematicPos)) {
            continue;
          }
          final inner = rect.deflate(boundaryTol);
          if (inner.contains(schematicPos)) {
            continue; // interior click
          }
          // On the boundary — treat as a hit with the block's area.
          final area = instance.width * instance.height;
          if (area < bestArea) {
            leafHit = instance;
            bestArea = area;
          }
        } else {
          // Leaf / collapsed node: full body click selects.
          if (!rect.contains(schematicPos)) {
            continue;
          }
          final area = instance.width * instance.height;
          if (area < bestArea) {
            leafHit = instance;
            bestArea = area;
          }
        }
      }
    }

    // ── Phase B: Wire hit-test ──
    // Skip when a non-Ctrl click lands inside a leaf primitive — the user
    // intends to select the node, not the wire.
    if (leafHit == null || _isControlPressed()) {
      SchematicEdgeData? closestEdge;
      var closestDistance = double.infinity;
      final wireThreshold = _wireSelectionRadius / _scale;
      for (final edge in widget.layout.edges) {
        final distance = _distanceToEdge(schematicPos, edge);
        if (distance < wireThreshold && distance < closestDistance) {
          closestEdge = edge;
          closestDistance = distance;
        }
      }

      if (closestEdge != null) {
        final edge = closestEdge;
        final wireId = edge.wireId;
        final isCtrl = _isControlPressed();

        if (isCtrl) {
          // Ctrl+click: toggle wire in multi-selection
          setState(() {
            if (_selectedWireIds.contains(wireId)) {
              _selectedWireIds.remove(wireId);
              _selectedWireScopePaths.remove(wireId);
              // If we removed the highlighted wire, clear highlight
              if (_highlightedWireName == wireId) {
                _highlightedWireName =
                    _selectedWireIds.isNotEmpty ? _selectedWireIds.last : null;
              }
            } else {
              _selectedWireIds.add(wireId);
              _selectedWireScopePaths[wireId] = edge.scopeHierarchyPath;
              _highlightedWireName = wireId;
              _selectedEdgeScope = _getEdgeScope(edge);
            }
          });
          return;
        }

        // Check if this is already the highlighted wire
        if (wireId == _highlightedWireName) {
          // Wire is already selected - zoom to it
          _zoomToWire(wireId);
          return;
        }

        // Normal click: highlight this wire, set as sole selection
        setState(() {
          _highlightedWireName = wireId;
          _highlightedNodeId = null;
          _selectedWireIds
            ..clear()
            ..add(wireId);
          _selectedWireScopePaths
            ..clear()
            ..[wireId] = edge.scopeHierarchyPath;
          _selectedEdgeScope = _getEdgeScope(edge);
          _selectedNodeIds.clear();
        });
        return;
      }
    } // end wire hit-test guard

    // ── Phase C: Instance (node) body hit-test ──
    // Reuse the pre-computed _leafHit from above.
    final hitInstance = leafHit;

    if (hitInstance != null) {
      final hitId = hitInstance.id;
      final isCtrl = _isControlPressed();
      if (isCtrl) {
        // Ctrl+click: toggle node in multi-selection (can mix with wires)
        setState(() {
          if (_selectedNodeIds.contains(hitId)) {
            _selectedNodeIds.remove(hitId);
            if (_highlightedNodeId == hitId) {
              _highlightedNodeId =
                  _selectedNodeIds.isNotEmpty ? _selectedNodeIds.last : null;
            }
          } else {
            _selectedNodeIds.add(hitId);
            _highlightedNodeId = hitId;
          }
        });
        return;
      }

      // Check if this is already the highlighted instance
      if (hitId == _highlightedNodeId && _selectedNodeIds.length <= 1) {
        // Instance is already selected - zoom to it
        _zoomToInstance(hitInstance);
        return;
      }

      // Normal click: select this instance (sole node selection),
      // clear wire selection.
      setState(() {
        _highlightedNodeId = hitId;
        _highlightedWireName = null;
        _selectedEdgeScope = null;
        _selectedWireIds.clear();
        _selectedWireScopePaths.clear();
        _selectedNodeIds
          ..clear()
          ..add(hitId);
      });
      return;
    }

    // Background click: deselect all
    setState(() {
      _highlightedNodeId = null;
      _highlightedWireName = null;
      _selectedEdgeScope = null;
      _selectedWireIds.clear();
      _selectedWireScopePaths.clear();
      _selectedNodeIds.clear();
    });
  }

  bool _isPointNearEdge(
    Offset point,
    SchematicEdgeData edge, {
    double threshold = 5.0,
  }) =>
      _distanceToEdge(point, edge) < threshold;

  double _distanceToEdge(Offset point, SchematicEdgeData edge) {
    if (edge.points.isEmpty) {
      return double.infinity;
    }

    var closestDistance = double.infinity;
    for (var i = 0; i < edge.points.length - 1; i++) {
      final p1 = Offset(edge.points[i].x, edge.points[i].y);
      final p2 = Offset(edge.points[i + 1].x, edge.points[i + 1].y);

      final distance = _pointToLineDistance(point, p1, p2);
      if (distance < closestDistance) {
        closestDistance = distance;
      }
    }
    return closestDistance;
  }

  /// Get the nodeId "scope" of an edge based on its ports Returns the nodeId
  /// that owns both ports, or null if they're in different nodes
  String? _getEdgeScope(SchematicEdgeData edge) {
    final portMap = <String, SchematicPortData>{};
    for (final port in widget.layout.ports) {
      portMap[port.id] = port;
    }

    String? sourceNodeId;
    String? targetNodeId;

    if (edge.sourcePort != null) {
      final sourcePort = portMap[edge.sourcePort];
      if (sourcePort != null) {
        sourceNodeId = sourcePort.instanceId;
      }
    }

    if (edge.targetPort != null) {
      final targetPort = portMap[edge.targetPort];
      if (targetPort != null) {
        targetNodeId = targetPort.instanceId;
      }
    }

    // Return the common scope (node that owns both ports)
    if (sourceNodeId == targetNodeId) {
      return sourceNodeId;
    }

    // If ports are in different nodes, use the source node
    // (edge is from source node to target)
    return sourceNodeId;
  }

  double _pointToLineDistance(Offset point, Offset lineStart, Offset lineEnd) {
    final dx = lineEnd.dx - lineStart.dx;
    final dy = lineEnd.dy - lineStart.dy;
    final lengthSq = dx * dx + dy * dy;

    if (lengthSq == 0) {
      return (point - lineStart).distance;
    }

    var t = ((point.dx - lineStart.dx) * dx + (point.dy - lineStart.dy) * dy) /
        lengthSq;
    t = t.clamp(0.0, 1.0);

    final projection = Offset(lineStart.dx + t * dx, lineStart.dy + t * dy);

    return (point - projection).distance;
  }

  /// Zoom to focus on a wire when it's selected
  void _zoomToWire(
    String wireId, {
    SchematicLayoutResult? customLayout,
    String? scopeNodeId,
  }) {
    final canvasSize = context.size;
    if (canvasSize == null || canvasSize.isEmpty) {
      return;
    }

    // Use custom layout if provided, otherwise use widget.layout
    final layoutToUse = customLayout ?? widget.layout;

    // Use provided scope if available, otherwise fall back to the stored scope
    final scopeToUse = scopeNodeId ?? _selectedEdgeScope;

    final wireViewState = SchematicWireZoom.computeWireZoom(
      layout: layoutToUse,
      wireId: wireId,
      viewportSize: canvasSize,
      scopeNodeId: scopeToUse,
    );

    if (wireViewState == null) {
      return;
    }

    _setViewTransform(wireViewState.scale, wireViewState.offset);
  }

  /// Zoom/pan to fit a set of wires in the viewport.
  ///
  /// Collects all layout edges whose `wireId` is in `wireIds`, computes
  /// a combined bounding box, and applies a fit-zoom + centre offset.
  void _zoomToWires(Set<String> wireIds) {
    final canvasSize = context.size;
    if (canvasSize == null || canvasSize.isEmpty || wireIds.isEmpty) {
      return;
    }

    final matchingEdges =
        widget.layout.edges.where((e) => wireIds.contains(e.wireId)).toList();
    if (matchingEdges.isEmpty) {
      return;
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    for (final edge in matchingEdges) {
      for (final point in edge.points) {
        if (point.x < minX) {
          minX = point.x;
        }
        if (point.y < minY) {
          minY = point.y;
        }
        if (point.x > maxX) {
          maxX = point.x;
        }
        if (point.y > maxY) {
          maxY = point.y;
        }
      }
    }
    if (minX == double.infinity) {
      return;
    }

    const edgePad = 20.0;
    final bounds = Rect.fromLTRB(
      minX - edgePad,
      minY - edgePad,
      maxX + edgePad,
      maxY + edgePad,
    );
    if (bounds.isEmpty) {
      return;
    }

    const viewPad = 40.0;
    final scaleX = (canvasSize.width - viewPad) / bounds.width;
    final scaleY = (canvasSize.height - viewPad) / bounds.height;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);

    final offsetX =
        (canvasSize.width - bounds.width * scale) / 2 - bounds.left * scale;
    final offsetY =
        (canvasSize.height - bounds.height * scale) / 2 - bounds.top * scale;

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Zoom to focus on an instance/module when double-clicked.
  ///
  /// For expanded (has-children) blocks, only zoom in — never zoom out,
  /// so a missed click on an internal wire doesn't yank the view out.
  ///
  /// When `customLayout` is provided (e.g. from search-driven expansion),
  /// it is used for the block-area ratio calculation instead of
  /// `widget.layout`, which may not have been rebuilt yet.
  void _zoomToInstance(
    SchematicInstanceData instance, {
    SchematicLayoutResult? customLayout,
  }) {
    final canvasSize = context.size;
    if (canvasSize == null || canvasSize.isEmpty) {
      return;
    }

    final layoutToUse = customLayout ?? widget.layout;

    // Create bounding box from instance dimensions
    final instanceBounds = Rect.fromLTWH(
      instance.x,
      instance.y,
      instance.width,
      instance.height,
    );

    // Compute zoom and offset to fit instance in viewport with padding
    const padding = 40.0;
    const focusedZoomRatio = 1.5;

    final scaleX = (canvasSize.width - padding) / instanceBounds.width;
    final scaleY = (canvasSize.height - padding) / instanceBounds.height;
    final fitZoom = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);

    // Determine if this should use focused or fit zoom
    final blockArea = layoutToUse.width * layoutToUse.height;
    final instanceArea = instance.width * instance.height;
    final isFitZoom = instanceArea > 0 && (instanceArea / blockArea) > 0.4;

    double scale;
    if (isFitZoom) {
      // Large instance: use fit zoom
      scale = fitZoom;
    } else {
      // Small instance: zoom to 150% of smallest dimension
      final smallestDimension =
          instance.width < instance.height ? instance.width : instance.height;
      final viewportSmallest = canvasSize.width < canvasSize.height
          ? canvasSize.width
          : canvasSize.height;
      scale = (viewportSmallest * focusedZoomRatio / (smallestDimension * 2))
          .clamp(0.05, 3.0);
      // Cap at fit zoom
      scale = scale < fitZoom ? scale : fitZoom;
    }

    // For expanded blocks, never zoom out — only zoom in or stay.
    if (instance.hasChildren && scale < _scale) {
      return;
    }

    // Compute offset to center the instance
    final scaledWidth = instanceBounds.width * scale;
    final scaledHeight = instanceBounds.height * scale;
    final offsetX =
        (canvasSize.width - scaledWidth) / 2 - instanceBounds.left * scale;
    final offsetY =
        (canvasSize.height - scaledHeight) / 2 - instanceBounds.top * scale;

    _setViewTransform(scale, Offset(offsetX, offsetY));
  }

  /// Handle wire selection from search with incremental expand.
  ///
  /// `wireId` is the full wire path (e.g., "TopModule/block/signal")
  /// `pathInstanceNames` are the instance names to expand (e.g., `"block"`)
  ///
  /// Instead of fully expanding every level, intermediate parent modules
  /// are revealed via partial child expansion so only the necessary
  /// submodule hierarchy is shown.  The final containing block is fully
  /// expanded so the signal (edge) itself becomes visible.
  /// Find an instance by `name` in `layout`, optionally scoped to children
  /// of `parentId`.  When `parentId` is non-null only instances whose ID
  /// appears in the parent's `children` list are considered, so identically-
  /// named instances under different parents are not confused.
  static SchematicInstanceData? _findInstanceByName(
    SchematicLayoutResult layout,
    String name, {
    String? parentId,
  }) {
    Set<String>? scope;
    if (parentId != null) {
      for (final inst in layout.instances) {
        if (inst.id == parentId) {
          scope = inst.children.toSet();
          break;
        }
      }
    }
    for (final inst in layout.instances) {
      if (inst.name == name || inst.instanceName == name) {
        if (scope != null && !scope.contains(inst.id)) {
          continue;
        }
        return inst;
      }
    }
    return null;
  }

  /// Best-effort resolution of the current schematic scope root node.
  ///
  /// In submodule views, signal search can produce an empty
  /// `pathInstanceNames` list because the signal belongs to the currently
  /// selected scope. In that case we still need a container node ID for
  /// `onExpandWire`.
  static String? _findCurrentScopeNodeId(SchematicLayoutResult layout) {
    SchematicInstanceData? fallback;
    for (final inst in layout.instances) {
      if (inst.isExternalPort) {
        continue;
      }
      if (layout.parentMap[inst.id] == null) {
        if (inst.hierarchyPath != null && inst.hierarchyPath!.isNotEmpty) {
          return inst.id;
        }
        fallback ??= inst;
      }
    }
    return fallback?.id;
  }

  Future<void> _handleWireSearchSelection(
    String wireId,
    List<String> pathInstanceNames,
  ) async {
    SchematicLayoutResult? latestLayout = widget.layout;
    final wireName = wireId.split('/').last;

    // SignalOccurrence is in the currently selected scope (no intermediate
    // instances). Expand the wire directly in the current root scope.
    if (pathInstanceNames.isEmpty) {
      final scopeId = _findCurrentScopeNodeId(latestLayout);
      SchematicLayoutResult? newLayout;
      if (scopeId != null && widget.onExpandWire != null) {
        newLayout = await widget.onExpandWire!(scopeId, wireName);
        if (newLayout != null) {
          latestLayout = newLayout;
          _pendingAutoFitSkips = 1;
        }
      }

      setState(() {
        _highlightedWireName = wireName;
        _highlightedNodeId = null;
        _selectedEdgeScope = scopeId;
      });

      if (newLayout != null) {
        final capturedScopeId = scopeId;
        _pendingZoomAction = () {
          _zoomToWire(
            wireName,
            customLayout: latestLayout,
            scopeNodeId: capturedScopeId,
          );
        };
      } else {
        _zoomToWire(wireName, customLayout: latestLayout, scopeNodeId: scopeId);
      }
      return;
    }

    // ── Fast path: batch expansion ────────────────────────────────────
    if (widget.onExpandPath != null) {
      final newLayout = await widget.onExpandPath!(
        pathInstanceNames,
        targetWireName: wireName,
      );
      if (newLayout != null) {
        latestLayout = newLayout;
        // The parent setState already updated widget.layout; suppress the
        // didUpdateWidget auto-fit so our _zoomToWire is not overridden.
        _pendingAutoFitSkips = 1;
      }

      // Walk path to find the scope (last instance on the path).
      String? parentId;
      String? scopeId;
      for (var i = 0; i < pathInstanceNames.length; i++) {
        final inst = _findInstanceByName(
          latestLayout,
          pathInstanceNames[i],
          parentId: parentId,
        );
        if (inst == null) {
          break;
        }
        scopeId = inst.id;
        parentId = inst.id;
      }

      setState(() {
        _highlightedWireName = wireName;
        _highlightedNodeId = null;
        _selectedEdgeScope = scopeId;
      });

      if (newLayout != null) {
        // Defer zoom until the new layout has been rendered.
        final capturedScopeId = scopeId;
        _pendingZoomAction = () {
          _zoomToWire(
            wireName,
            customLayout: latestLayout,
            scopeNodeId: capturedScopeId,
          );
        };
      } else {
        _zoomToWire(wireName, customLayout: latestLayout, scopeNodeId: scopeId);
      }
      return;
    }

    // ── Fallback: per-level expansion ─────────────────────────────────
    var potentialExpansions = 0;
    String? lastExpandedInstanceId;

    for (var i = 0; i < pathInstanceNames.length; i++) {
      final instanceName = pathInstanceNames[i];
      final isLast = i == pathInstanceNames.length - 1;

      var instance = _findInstanceByName(
        latestLayout!,
        instanceName,
        parentId: lastExpandedInstanceId,
      );

      if (instance == null) {
        if (lastExpandedInstanceId != null && widget.onExpandChild != null) {
          potentialExpansions++;
          final newLayout = await widget.onExpandChild!(
            lastExpandedInstanceId,
            instanceName,
          );
          if (newLayout != null) {
            latestLayout = newLayout;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          instance = _findInstanceByName(
            latestLayout,
            instanceName,
            parentId: lastExpandedInstanceId,
          );
        }
        if (instance == null) {
          break;
        }
      }

      lastExpandedInstanceId = instance.id;

      if (!instance.isExpanded) {
        if (isLast) {
          if (widget.onExpandWire != null) {
            potentialExpansions++;
            final newLayout = await widget.onExpandWire!(instance.id, wireName);
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          } else if (widget.onNodeToggle != null) {
            potentialExpansions++;
            final newLayout = await widget.onNodeToggle!(instance.id);
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        } else {
          final nextName = pathInstanceNames[i + 1];
          if (widget.onExpandChild != null) {
            potentialExpansions++;
            final newLayout = await widget.onExpandChild!(
              instance.id,
              nextName,
            );
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          } else if (widget.onNodeToggle != null) {
            potentialExpansions++;
            final newLayout = await widget.onNodeToggle!(instance.id);
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      } else if (isLast && widget.onExpandWire != null) {
        potentialExpansions++;
        final newLayout = await widget.onExpandWire!(instance.id, wireName);
        if (newLayout != null) {
          latestLayout = newLayout;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }

    if (potentialExpansions > 0) {
      _pendingAutoFitSkips = potentialExpansions;
    }

    final scope = lastExpandedInstanceId;

    setState(() {
      _highlightedWireName = wireName;
      _highlightedNodeId = null;
      _selectedEdgeScope = scope;
    });

    if (potentialExpansions > 0) {
      // Defer zoom until all pending layout rebuilds have been processed.
      _pendingZoomAction = () {
        _zoomToWire(wireName, customLayout: latestLayout, scopeNodeId: scope);
      };
    } else {
      _zoomToWire(wireName, customLayout: latestLayout, scopeNodeId: scope);
    }
  }

  /// Handle module/block selection from search with incremental expand.
  ///
  /// `moduleId` is the full path (e.g. "Top/CPU/ALU").
  /// `pathInstanceNames` are the display segments to expand (e.g.
  /// `"CPU", "ALU"`).
  ///
  /// Instead of fully expanding every level, each parent along the path
  /// is revealed via partial child expansion.  The target block itself
  /// is left collapsed — only made visible, not opened.
  ///
  /// When `onExpandPath` is available the entire path is expanded in a
  /// single layout cycle (batch mode).  Otherwise falls back to
  /// per-level expansion via `onExpandChild`.
  Future<void> _handleModuleSearchSelection(
    String moduleId,
    List<String> pathInstanceNames,
  ) async {
    if (pathInstanceNames.isEmpty) {
      return;
    }

    SchematicLayoutResult? latestLayout = widget.layout;

    // ── Fast path: batch expansion ────────────────────────────────────
    if (widget.onExpandPath != null) {
      final newLayout = await widget.onExpandPath!(pathInstanceNames);
      if (newLayout != null) {
        latestLayout = newLayout;
        // The parent setState already updated widget.layout; suppress the
        // didUpdateWidget auto-fit so our _zoomToInstance is not overridden.
        _pendingAutoFitSkips = 1;
      }

      // Locate the target in the (possibly updated) layout.
      // Walk from the root to find the correct parent scope so we pick
      // the right instance when names collide across subtrees.
      String? parentId;
      SchematicInstanceData? targetInstance;
      for (var i = 0; i < pathInstanceNames.length; i++) {
        final inst = _findInstanceByName(
          latestLayout,
          pathInstanceNames[i],
          parentId: parentId,
        );
        if (inst == null) {
          break;
        }
        if (i == pathInstanceNames.length - 1) {
          targetInstance = inst;
        } else {
          parentId = inst.id;
        }
      }

      if (targetInstance != null) {
        setState(() {
          _highlightedNodeId = targetInstance!.id;
          _highlightedWireName = null;
          _selectedEdgeScope = null;
        });
        if (newLayout != null) {
          // Defer zoom until the new layout has been rendered.
          final capturedTarget = targetInstance;
          _pendingZoomAction = () {
            _zoomToInstance(capturedTarget, customLayout: latestLayout);
          };
        } else {
          _zoomToInstance(targetInstance, customLayout: latestLayout);
        }
      }
      return;
    }

    // ── Fallback: per-level expansion ─────────────────────────────────
    var potentialExpansions = 0;
    SchematicInstanceData? targetInstance;
    String? currentParentId;

    for (var i = 0; i < pathInstanceNames.length; i++) {
      final instanceName = pathInstanceNames[i];
      final isTarget = i == pathInstanceNames.length - 1;

      var instance = _findInstanceByName(
        latestLayout!,
        instanceName,
        parentId: currentParentId,
      );

      if (instance == null) {
        if (currentParentId != null && widget.onExpandChild != null) {
          potentialExpansions++;
          final newLayout = await widget.onExpandChild!(
            currentParentId,
            instanceName,
          );
          if (newLayout != null) {
            latestLayout = newLayout;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          instance = _findInstanceByName(
            latestLayout,
            instanceName,
            parentId: currentParentId,
          );
        }
        if (instance == null) {
          break;
        }
      }

      if (isTarget) {
        if (currentParentId != null && widget.onExpandChild != null) {
          potentialExpansions++;
          final newLayout = await widget.onExpandChild!(
            currentParentId,
            instanceName,
          );
          if (newLayout != null) {
            latestLayout = newLayout;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            instance = _findInstanceByName(
              latestLayout,
              instanceName,
              parentId: currentParentId,
            );
          }
        }
        targetInstance = instance;
      } else {
        currentParentId = instance.id;

        if (!instance.isExpanded) {
          final nextName = pathInstanceNames[i + 1];
          if (widget.onExpandChild != null) {
            potentialExpansions++;
            final newLayout = await widget.onExpandChild!(
              instance.id,
              nextName,
            );
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          } else if (widget.onNodeToggle != null) {
            potentialExpansions++;
            final newLayout = await widget.onNodeToggle!(instance.id);
            if (newLayout != null) {
              latestLayout = newLayout;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      }
    }

    if (potentialExpansions > 0) {
      _pendingAutoFitSkips = potentialExpansions;

      final targetName = pathInstanceNames.last;
      targetInstance = _findInstanceByName(
        latestLayout!,
        targetName,
        parentId: currentParentId,
      );
    }

    if (targetInstance != null) {
      setState(() {
        _highlightedNodeId = targetInstance!.id;
        _highlightedWireName = null;
        _selectedEdgeScope = null;
      });
      if (potentialExpansions > 0) {
        // Defer zoom until all pending layout rebuilds have been processed.
        final capturedTarget = targetInstance;
        _pendingZoomAction = () {
          _zoomToInstance(capturedTarget, customLayout: latestLayout);
        };
      } else {
        _zoomToInstance(targetInstance, customLayout: latestLayout);
      }
    }
  }

  static DateTime? _lastBuildTime;

  @override
  Widget build(BuildContext context) {
    // DEBUG: Track build frequency
    if (SchematicPainter._debugPaintFrequency) {
      final now = DateTime.now();
      if (_lastBuildTime != null) {
        // final delta = now.difference(_lastBuildTime!).inMilliseconds; Debug
        // build logging disabled - print statements and stack trace capture are
        // expensive and impact zoom/pan performance. Re-enable only for
        // debugging. if (delta < 1000) { debugPrint('`SchematicCanvas` build
        // #$_buildCounter, delta: ${delta}ms since last build'); if
        // (_buildCounter % 10 == 0) { debugPrint('`SchematicCanvas` Stack trace
        // for build #$_buildCounter:');
        // debugPrint(StackTrace.current.toString().split('\n').take(15).join('\n'));
        //   }
        // }
      }
      _lastBuildTime = now;
    }

    // Wrap the CustomPaint in RepaintBoundary to prevent flickering on Linux.
    // This isolates the schematic rendering from other widget tree updates.
    Widget canvas = RepaintBoundary(
      child: CustomPaint(
        painter: SchematicPainter(
          layout: widget.layout,
          viewTransform: _viewTransformNotifier,
          snapshotMode: _snapshotModeNotifier,
          colorScheme: widget.colorScheme,
          highlightedWireName: _highlightedWireName,
          selectedEdgeScope: _selectedEdgeScope,
          selectedWireIds: Set.unmodifiable(_selectedWireIds),
          selectedWireScopePaths: Map.unmodifiable(_selectedWireScopePaths),
          selectedNodeIds: Set.unmodifiable(_selectedNodeIds),
          highlightedNodeId: _highlightedNodeId,
          pendingToggleNodeId: widget.pendingToggleNodeId,
          isNodeInScope: _isNodeInScope,
          hoveredBoundaryPortNotifier: _hoveredBoundaryPortNotifier,
        ),
        size: Size.infinite,
      ),
    );

    if (widget.isDimmed) {
      canvas = ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.black54, BlendMode.srcATop),
        child: canvas,
      );
    }

    return Stack(
      children: [
        RepaintBoundary(
          key: _exportBoundaryKey,
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                // CTRL-F or CMD-F to toggle search
                if (event.logicalKey == LogicalKeyboardKey.keyF &&
                    (HardwareKeyboard.instance.isControlPressed ||
                        HardwareKeyboard.instance.isMetaPressed)) {
                  final opening = !_showSearchOverlayNotifier.value;
                  if (opening) {
                    _searchOverlayPosition = _currentMousePosition;
                  }
                  _showSearchOverlayNotifier.value = opening;
                  return KeyEventResult.handled;
                }
                // When the search overlay is open, let all other keys pass
                // through to the search TextField instead of handling them
                // here (e.g. 'f' should type in the box, not fit-to-canvas).
                if (_showSearchOverlayNotifier.value) {
                  return KeyEventResult.ignored;
                }
                // F key alone to fit to canvas
                if (event.logicalKey == LogicalKeyboardKey.keyF) {
                  _fitToCanvas();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              onEnter: (_) {
                // Don't steal focus from the search overlay's text field.
                if (_showSearchOverlayNotifier.value) {
                  return;
                }
                if (!_focusNode.hasFocus) {
                  _focusNode.requestFocus();
                }
              },
              onExit: (_) {
                // Clear tooltip when mouse leaves the schematic area
                _scheduleDismissTooltip();
                _hoverTooltipNotifier.value = (
                  tooltipKey: null,
                  lines: <String>[],
                  position: Offset.zero,
                );
                _lastHoverCheck = null;
                _lastHoverPosition = null;
                if (_hoveredBoundaryPortId != null) {
                  _setHoveredBoundaryPort(
                    portId: null,
                    nodeId: null,
                    isInterior: false,
                  );
                }
              },
              onHover: (event) {
                // Always track the raw mouse position (used for search-overlay
                // anchor — must be set BEFORE the throttle early-returns).
                _currentMousePosition = event.localPosition;

                // Throttle by time AND distance to minimize edge hit-testing
                final now = DateTime.now();
                final mousePosition = event.localPosition;

                // Skip if not enough time has passed
                if (_lastHoverCheck != null) {
                  final elapsed =
                      now.difference(_lastHoverCheck!).inMilliseconds;
                  if (elapsed < _hoverThrottleMs) {
                    return;
                  }
                }

                // Skip if mouse hasn't moved enough
                if (_lastHoverPosition != null) {
                  final distance =
                      (mousePosition - _lastHoverPosition!).distance;
                  if (distance < _hoverDistanceThreshold) {
                    return;
                  }
                }

                _lastHoverCheck = now;
                _lastHoverPosition = mousePosition;

                final schematicPos = (mousePosition - _offset) / _scale;

                // --- 1. Check wires (edges) first ---
                // Scale-aware threshold: use a tighter distance in schematic
                // coordinates so parallel signals are distinguishable.
                final wireThreshold = 5.0 / _scale;
                for (final edge in widget.layout.edges) {
                  if (_isPointNearEdge(
                    schematicPos,
                    edge,
                    threshold: wireThreshold.clamp(2.0, 15.0),
                  )) {
                    var wireName = edge.wireId;
                    if (edge.signalWidth > 1) {
                      wireName = '${edge.wireId} (${edge.signalWidth})';
                    }

                    // Detect boundary port: find the closest endpoint port
                    // that belongs to an expanded/partially-expanded parent.
                    _updateHoveredBoundaryPort(edge, schematicPos);

                    final key = 'wire:$wireName';
                    final current = _hoverTooltipNotifier.value;
                    if (key != current.tooltipKey) {
                      _lastHoverScopePath = edge.scopeHierarchyPath;
                      _lastHoverAddr = edge.addr;
                      _hoverTooltipNotifier.value = (
                        tooltipKey: key,
                        lines: [wireName],
                        position: mousePosition,
                      );
                    }
                    return;
                  }
                }

                // --- 1a. Port-marker proximity ---
                // The cursor isn't on a wire, but it may be hovering directly
                // over the port pin area where the boundary marker triangle
                // appears.  Activate the hover so the triangle shows up and
                // the user can click it without needing to land on the wire.
                if (_tryActivateBoundaryPortFromPortProximity(schematicPos)) {
                  return;
                }

                // Clear boundary port hover when not on a wire and not near a
                // port marker.  Keep it alive if the cursor is still within the
                // marker's hit zone so the user can move from the wire to the
                // triangle to click it.
                if (_hoveredBoundaryPortId != null) {
                  if (_isInsideHoveredBoundaryPortMarker(schematicPos)) {
                    // Still on the marker — keep hover state and skip further
                    // hit-testing so the tooltip doesn't flicker.
                    return;
                  }
                  _setHoveredBoundaryPort(
                    portId: null,
                    nodeId: null,
                    isInterior: false,
                  );
                }

                // --- 1b. Check port markers (bowtie hit zones) --- Interior
                // marker → port name; exterior marker → connected wire.
                {
                  final portHit = _hitTestPortMarker(schematicPos);
                  if (portHit != null) {
                    final key = 'port:${portHit.$1}';
                    final current = _hoverTooltipNotifier.value;
                    if (key != current.tooltipKey) {
                      _lastHoverScopePath = portHit.$2;
                      _hoverTooltipNotifier.value = (
                        tooltipKey: key,
                        lines: [portHit.$1],
                        position: mousePosition,
                      );
                    }
                    return;
                  }
                }

                // --- 1c. Check port pins on child instances (general hover)
                // --- Catches ports without bowtie markers (visible wire
                // connections).
                {
                  final portPinHit = _hitTestPortPin(schematicPos);
                  if (portPinHit != null) {
                    final key = 'port:${portPinHit.$1}';
                    final current = _hoverTooltipNotifier.value;
                    if (key != current.tooltipKey) {
                      _lastHoverScopePath = portPinHit.$2;
                      _hoverTooltipNotifier.value = (
                        tooltipKey: key,
                        lines: [portPinHit.$1],
                        position: mousePosition,
                      );
                    }
                    return;
                  }
                }

                // --- 1d. Check external port instances (triangle stubs) ---
                // External port stubs represent the module's own I/O at the
                // boundary.  Treat them as port hovers so we get signal lookup.
                //
                // Strategy: use the hierarchy API to find the signal's full
                // instance-path.  The external port's parent in the layout is
                // the module instance; the bridge maps that to a hierarchy
                // node whose signals carry `fullPath`.  We set
                // `_lastHoverScopePath` to the directory part of that fullPath
                // so the generic tooltip code builds the correct lookup key.
                {
                  SchematicInstanceData? extHit;
                  var extArea = double.infinity;
                  for (final inst in widget.layout.instances) {
                    if (!inst.isExternalPort) {
                      continue;
                    }
                    final rect = Rect.fromLTWH(
                      inst.x,
                      inst.y,
                      inst.width,
                      inst.height,
                    );
                    if (rect.contains(schematicPos)) {
                      final area = inst.width * inst.height;
                      if (area < extArea) {
                        extHit = inst;
                        extArea = area;
                      }
                    }
                  }
                  if (extHit != null) {
                    final portName = extHit.name;

                    // Find the parent module's instance path via the hierarchy
                    // bridge, then look up the signal's full path.
                    String? scope;
                    if (_bridge != null && _hierarchy != null) {
                      final parentLayoutId = widget.layout.parentMap[extHit.id];
                      if (parentLayoutId != null) {
                        final hierNodeId =
                            _bridge!.instanceIdToOccurrenceId[parentLayoutId];
                        if (hierNodeId != null) {
                          final hierAddr = OccurrenceAddress.tryFromPathname(
                            hierNodeId,
                            _hierarchy!.root,
                          );
                          final hierNode = hierAddr != null
                              ? _hierarchy!.occurrenceByAddress(hierAddr)
                              : null;
                          if (hierNode != null) {
                            // Search the module's signals for a matching port.
                            for (final sig in hierNode.signals) {
                              if (sig.name == portName) {
                                // fullPath is e.g. "top/adder0/a" — scope is
                                // the directory part "top/adder0".
                                final i = sig.path().lastIndexOf('/');
                                if (i >= 0) {
                                  scope = sig.path().substring(0, i);
                                }
                                break;
                              }
                            }
                          }
                        }
                      }
                    }

                    // Fallback to old path-based scope when hierarchy lookup
                    // doesn't work (standalone path).
                    scope ??= _parentScopeOf(extHit.hierarchyPath) ??
                        extHit.hierarchyPath;

                    final key = 'port:$portName';
                    final current = _hoverTooltipNotifier.value;
                    if (key != current.tooltipKey) {
                      _lastHoverScopePath = scope;
                      _hoverTooltipNotifier.value = (
                        tooltipKey: key,
                        lines: [portName],
                        position: mousePosition,
                      );
                    }
                    return;
                  }
                }

                // --- 2. Check module instances ---
                // Find the smallest (most specific) instance under cursor,
                // skipping root (parent) blocks and const blocks.
                SchematicInstanceData? hitInstance;
                var hitArea = double.infinity;
                for (final inst in widget.layout.instances) {
                  final rect = Rect.fromLTWH(
                    inst.x,
                    inst.y,
                    inst.width,
                    inst.height,
                  );
                  if (rect.contains(schematicPos)) {
                    final area = inst.width * inst.height;
                    if (area < hitArea) {
                      hitInstance = inst;
                      hitArea = area;
                    }
                  }
                }

                // For expanded/partially-expanded blocks, only show the
                // tooltip when the cursor is near the boundary rectangle —
                // not when hovering over empty space inside. Use a
                // screen-resolution-aware margin so the hit zone feels
                // consistent regardless of zoom level.
                if (hitInstance != null &&
                    (hitInstance.isExpanded ||
                        hitInstance.isPartiallyExpanded)) {
                  final margin = 8.0 / _scale; // ~8 screen pixels
                  final rect = Rect.fromLTWH(
                    hitInstance.x,
                    hitInstance.y,
                    hitInstance.width,
                    hitInstance.height,
                  );
                  final inner = rect.deflate(margin);
                  // If the cursor is inside the inner rect it's not near any
                  // edge, so skip the tooltip for this expanded block.
                  if (inner.contains(schematicPos)) {
                    hitInstance = null;
                  }
                }

                // Filter out const blocks
                if (hitInstance != null) {
                  final lowerCls = hitInstance.cls.toLowerCase();
                  final lowerCss = hitInstance.cssClass.toLowerCase();
                  final isConst = (hitInstance.cls.isEmpty ||
                          lowerCls == 'const' ||
                          lowerCss.contains('const')) &&
                      hitInstance.name.startsWith('0x');
                  if (isConst) {
                    hitInstance = null;
                  }
                }

                if (hitInstance != null &&
                    !hitInstance.isExternalPort &&
                    !hitInstance.cssClass.contains('node-0')) {
                  final key = 'inst:${hitInstance.id}';
                  final current = _hoverTooltipNotifier.value;
                  if (key != current.tooltipKey) {
                    // Count input / output ports for this instance
                    var inputs = 0;
                    var outputs = 0;
                    var inouts = 0;
                    for (final port in widget.layout.ports) {
                      if (port.instanceId == hitInstance.id) {
                        if (port.isInput) {
                          inputs++;
                        } else if (port.isOutput) {
                          outputs++;
                        } else if (port.isInout) {
                          inouts++;
                        }
                      }
                    }
                    // Prefer the original instance name for primitives
                    // (e.g. "mux_0") over the operator display name ("MUX").
                    final displayName =
                        hitInstance.instanceName ?? hitInstance.name;
                    final parentPath = _parentScopeOf(
                      hitInstance.hierarchyPath,
                    );
                    final ioSummary = 'inputs: $inputs  outputs: $outputs'
                        '${inouts > 0 ? '  inouts: $inouts' : ''}';
                    final lines = <String>[
                      displayName,
                      if (parentPath != null) 'inside $parentPath',
                      ioSummary,
                    ];
                    _hoverTooltipNotifier.value = (
                      tooltipKey: key,
                      lines: lines,
                      position: mousePosition,
                    );
                  }
                  return;
                }

                // --- 3. Nothing under cursor — clear tooltip ---
                final current = _hoverTooltipNotifier.value;
                if (current.tooltipKey != null) {
                  _hoverTooltipNotifier.value = (
                    tooltipKey: null,
                    lines: <String>[],
                    position: Offset.zero,
                  );
                }
              },
              child: Listener(
                onPointerSignal: _handlePointerSignal,
                onPointerDown: (event) {
                  _pointerDownPosition = event.localPosition;
                  _pointerDownButton = event.buttons;
                  if (!_focusNode.hasFocus) {
                    _focusNode.requestFocus();
                  }
                  // Start zoom region selection if CONTROL is held
                  if (_isControlPressed()) {
                    _onZoomRegionMouseDown(event.localPosition);
                  }
                },
                onPointerUp: (event) async {
                  if (_isSelectingZoomRegion) {
                    // Only complete zoom-to-region if the user actually
                    // dragged. A Ctrl+click (no drag) should fall through to
                    // the normal tap handler so it can do wire multi-select.
                    final distance = _pointerDownPosition != null
                        ? (event.localPosition - _pointerDownPosition!).distance
                        : double.infinity;
                    if (distance > _tapTolerance) {
                      _onZoomRegionMouseUp();
                    } else {
                      // Cancel the zoom region and handle as a normal tap.
                      _isSelectingZoomRegion = false;
                      _zoomRegionStartPoint = null;
                      _zoomRegionEndPoint = null;
                      _zoomRegionNotifier.value = (
                        startPoint: Offset.zero,
                        endPoint: Offset.zero,
                        isSelecting: false,
                      );
                      await _handleTapAtPosition(event.localPosition);
                    }
                  } else if (_pointerDownPosition != null) {
                    final distance =
                        (event.localPosition - _pointerDownPosition!).distance;
                    if (distance < _tapTolerance) {
                      if (_pointerDownButton == kSecondaryMouseButton) {
                        // Right-click: show context menu
                        // if signals are selected
                        _showWireContextMenu(context, event.localPosition);
                      } else if (_pointerDownButton == 1 ||
                          _pointerDownButton == null) {
                        await _handleTapAtPosition(event.localPosition);
                      }
                    }
                  }
                  _pointerDownPosition = null;
                  _pointerDownButton = null;
                },
                onPointerMove: (event) {
                  // Update zoom region selection if in progress
                  if (_isSelectingZoomRegion) {
                    _onZoomRegionMouseDrag(event.localPosition);
                  } else if (_pointerDownPosition != null) {
                    final distance =
                        (event.localPosition - _pointerDownPosition!).distance;
                    if (distance > _tapTolerance) {
                      _pointerDownPosition = null;
                    }
                  }
                },
                child: Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _handleScaleStart,
                      onScaleUpdate: _handleScaleUpdate,
                      onScaleEnd: _handleScaleEnd,
                      child: ClipRect(child: canvas),
                    ),
                    // Zoom-to-region overlay (drawn on top).
                    ValueListenableBuilder<
                        ({
                          Offset? startPoint,
                          Offset? endPoint,
                          bool isSelecting
                        })>(
                      valueListenable: _zoomRegionNotifier,
                      builder: (context, zoomRegion, child) {
                        if (!zoomRegion.isSelecting ||
                            zoomRegion.startPoint == null ||
                            zoomRegion.endPoint == null) {
                          return const SizedBox.shrink();
                        }

                        return Positioned.fill(
                          child: IgnorePointer(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: SchematicZoomRegionPainter(
                                  startPoint: zoomRegion.startPoint!,
                                  endPoint: zoomRegion.endPoint!,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    // Search overlay - visible when
                    // _showSearchOverlayNotifier.value is true
                    if (_showSearchOverlayNotifier.value)
                      Positioned(
                        top: _searchOverlayTop(context),
                        left: _searchOverlayLeft(context),
                        child: Listener(
                          // Absorb pointer scroll events so they don't
                          // reach the canvas Listener and trigger zoom.
                          onPointerSignal: (event) {},
                          child: WireSearchOverlay(
                            layout: widget.layout,
                            onClose: () {
                              _showSearchOverlayNotifier.value = false;
                              _focusNode.requestFocus();
                            },
                            onWireSelected: _handleWireSearchSelection,
                            onModuleSelected: _handleModuleSearchSelection,
                            hierarchy: _hierarchy,
                          ),
                        ),
                      ),
                    // Export-to-PNG button (bottom-right corner). Hidden during
                    // snapshot capture so it doesn't appear in the PNG.
                    ValueListenableBuilder<bool>(
                      valueListenable: _snapshotModeNotifier,
                      builder: (_, isSnapshot, child) =>
                          isSnapshot ? const SizedBox.shrink() : child!,
                      child: Positioned(
                        right: 8,
                        bottom: 8,
                        child: ExportPngButton(
                          onPressed: _exportToPng,
                          tooltip: 'Export schematic as PNG',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Progress spinner shown outside the RepaintBoundary during capture.
        ValueListenableBuilder<bool>(
          valueListenable: _snapshotModeNotifier,
          builder: (_, isSnapshot, __) => isSnapshot
              ? Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black26,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(
                            'Exporting PNG\u2026',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Painter for drawing the zoom-to-region overlay rectangle during
/// CONTROL-drag.
class SchematicZoomRegionPainter extends CustomPainter {
  /// Start point of the zoom region selection.
  final Offset startPoint;

  /// End point of the zoom region selection.
  final Offset endPoint;

  /// Fill color for the selection rectangle.
  final Color fillColor;

  /// Border color for the selection rectangle.
  final Color borderColor;

  /// Creates a `SchematicZoomRegionPainter`.
  SchematicZoomRegionPainter({
    required this.startPoint,
    required this.endPoint,
    this.fillColor = const Color(0x3300AAFF),
    this.borderColor = const Color(0xFF0088FF),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = borderColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // Calculate normalized rectangle bounds
    final minX = startPoint.dx < endPoint.dx ? startPoint.dx : endPoint.dx;
    final maxX = startPoint.dx < endPoint.dx ? endPoint.dx : startPoint.dx;
    final minY = startPoint.dy < endPoint.dy ? startPoint.dy : endPoint.dy;
    final maxY = startPoint.dy < endPoint.dy ? endPoint.dy : startPoint.dy;

    // Draw filled rectangle
    final rect = Rect.fromLTRB(minX, minY, maxX, maxY);
    canvas
      ..drawRect(rect, paint)
      // Draw border rectangle
      ..drawRect(rect, linePaint);

    // Draw corner indicators to show direction
    const cornerSize = 8.0;
    final cornerPaint = Paint()
      ..color = borderColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Top-left corner
    canvas
      ..drawLine(
        Offset(minX, minY),
        Offset(minX + cornerSize, minY),
        cornerPaint,
      )
      ..drawLine(
        Offset(minX, minY),
        Offset(minX, minY + cornerSize),
        cornerPaint,
      )
      // Bottom-right corner
      ..drawLine(
        Offset(maxX, maxY),
        Offset(maxX - cornerSize, maxY),
        cornerPaint,
      )
      ..drawLine(
        Offset(maxX, maxY),
        Offset(maxX, maxY - cornerSize),
        cornerPaint,
      );
  }

  @override
  bool shouldRepaint(covariant SchematicZoomRegionPainter oldDelegate) =>
      oldDelegate.startPoint != startPoint ||
      oldDelegate.endPoint != endPoint ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.borderColor != borderColor;
}
