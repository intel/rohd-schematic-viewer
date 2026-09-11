// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_schematic_synthesizer.dart
// Synthesizes schematic layout data from a HierarchyService.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

/// Synthesizes schematic layout data from a [HierarchyService].
///
/// This generates a basic schematic visualization from the hierarchy structure,
/// showing modules as boxes with their ports. The layout is a simple grid-based
/// arrangement. Real schematic data can be loaded later to replace or augment
/// this synthesized view.
///
/// Usage:
/// ```dart
/// final synthesizer = HierarchySchematicSynthesizer(hierarchyService);
/// final layout = synthesizer.synthesize();
/// ```
class HierarchySchematicSynthesizer {
  final HierarchyService _hierarchy;

  // Layout constants
  static const double _minModuleWidth = 120;
  static const double _portHeight = 20;
  static const double _portWidth = 10;
  static const double _horizontalSpacing = 80;
  static const double _verticalSpacing = 60;
  static const double _padding = 40;
  static const double _charWidth = 8; // Approximate character width
  static const double _portLabelPadding = 15; // Padding around port labels

  /// Creates a synthesizer for the given hierarchy.
  HierarchySchematicSynthesizer(this._hierarchy);

  /// Resolve a pathname to a [HierarchyOccurrence] via address lookup.
  HierarchyOccurrence? _resolveNode(String pathname) {
    final addr = OccurrenceAddress.tryFromPathname(pathname, _hierarchy.root);
    if (addr == null) {
      return null;
    }
    return _hierarchy.occurrenceByAddress(addr);
  }

  /// Estimate the width needed to display text.
  double _estimateTextWidth(String text) => text.length * _charWidth;

  /// Compute left/right padding needed for an expanded node so that children
  /// placed inside don't overlap with port labels on the WEST/EAST sides.
  (double left, double right) _portSidePaddings(HierarchyOccurrence node) {
    final nodePorts = node.ports;
    var maxWestLabel = 0.0;
    var maxEastLabel = 0.0;
    for (final port in nodePorts) {
      final labelW = _estimateTextWidth(port.name) + _portLabelPadding;
      if (port.direction == 'input' || port.direction == 'inout') {
        if (labelW > maxWestLabel) {
          maxWestLabel = labelW;
        }
      } else if (port.direction == 'output') {
        if (labelW > maxEastLabel) {
          maxEastLabel = labelW;
        }
      }
    }
    // Padding must clear port pin + port label + small gap.
    final leftPad =
        maxWestLabel > 0 ? (maxWestLabel + _portWidth + 6) : _padding;
    final rightPad =
        maxEastLabel > 0 ? (maxEastLabel + _portWidth + 6) : _padding;
    return (
      leftPad > _padding ? leftPad : _padding,
      rightPad > _padding ? rightPad : _padding,
    );
  }

  /// Calculate minimum width for a node based on its name and port names.
  double _calculateMinWidth(HierarchyOccurrence node) {
    // Start with module name width + padding
    var minWidth = _estimateTextWidth(node.name) + 40;

    // Get the longest port name on each side
    final nodePorts = node.ports;
    final inputs = nodePorts.where(
      (p) => p.direction == 'input' || p.direction == 'inout',
    );
    final outputs = nodePorts.where((p) => p.direction == 'output');

    double maxInputWidth = 0;
    for (final port in inputs) {
      final w = _estimateTextWidth(port.name) + _portLabelPadding;
      if (w > maxInputWidth) {
        maxInputWidth = w;
      }
    }

    double maxOutputWidth = 0;
    for (final port in outputs) {
      final w = _estimateTextWidth(port.name) + _portLabelPadding;
      if (w > maxOutputWidth) {
        maxOutputWidth = w;
      }
    }

    // Width must fit both port label columns plus some center space
    final portWidth = maxInputWidth + maxOutputWidth + 40;
    if (portWidth > minWidth) {
      minWidth = portWidth;
    }

    // Ensure minimum
    if (minWidth < _minModuleWidth) {
      minWidth = _minModuleWidth;
    }

    return minWidth;
  }

  /// Synthesizes a schematic layout from the hierarchy.
  ///
  /// If [moduleId] is provided, synthesizes schematic for that module only.
  /// Otherwise synthesizes from the root.
  ///
  /// [expandedNodes] contains the IDs of nodes that should be shown expanded
  /// (with their children visible inside them).
  SchematicLayoutResult synthesize({
    String? moduleId,
    Set<String>? expandedNodes,
  }) {
    final targetNode =
        moduleId != null ? _resolveNode(moduleId) : _hierarchy.root;

    if (targetNode == null) {
      return SchematicLayoutResult.empty();
    }

    final expanded = expandedNodes ?? <String>{};
    final instances = <SchematicInstanceData>[];
    final ports = <SchematicPortData>[];
    final edges = <SchematicEdgeData>[];

    // Synthesize the root and all its children recursively
    _synthesizeNode(
      node: targetNode,
      x: 0,
      y: 0,
      depth: 0,
      expandedNodes: expanded,
      instances: instances,
      ports: ports,
    );

    // Calculate bounds
    final maxX = instances.fold<double>(
      0,
      (max, inst) => inst.x + inst.width > max ? inst.x + inst.width : max,
    );
    final maxY = instances.fold<double>(
      0,
      (max, inst) => inst.y + inst.height > max ? inst.y + inst.height : max,
    );

    return SchematicLayoutResult(
      instances: instances,
      ports: ports,
      edges: edges,
      width: maxX + _padding,
      height: maxY + _padding,
    );
  }

  /// Recursively synthesize a node and its children.
  /// Returns the size (width, height) of the synthesized node.
  ({double width, double height}) _synthesizeNode({
    required HierarchyOccurrence node,
    required double x,
    required double y,
    required int depth,
    required Set<String> expandedNodes,
    required List<SchematicInstanceData> instances,
    required List<SchematicPortData> ports,
  }) {
    final isExpanded = expandedNodes.contains(node.path()) || depth == 0;
    final hasChildren = node.children.isNotEmpty;

    // Calculate port requirements
    final nodePorts = node.ports;
    final inputCount = nodePorts
        .where((p) => p.direction == 'input' || p.direction == 'inout')
        .length;
    final outputCount = nodePorts.where((p) => p.direction == 'output').length;
    final maxPortsOnSide = inputCount > outputCount ? inputCount : outputCount;
    final portRequiredHeight = 30.0 + maxPortsOnSide * (_portHeight + 5) + 20.0;

    // Calculate minimum width based on text (module name + port labels)
    final minTextWidth = _calculateMinWidth(node);

    double instanceWidth;
    double instanceHeight;

    if (isExpanded && hasChildren) {
      // Compute side paddings that clear port labels
      final (leftPad, rightPad) = _portSidePaddings(node);

      // Layout children inside this node
      final childrenLayout = _layoutChildren(
        children: node.children,
        parentX: x + leftPad,
        parentY: y + 40, // Header space
        expandedNodes: expandedNodes,
        depth: depth + 1,
        instances: instances,
        ports: ports,
      );

      // Size this node to contain its children
      instanceWidth = childrenLayout.width + leftPad + rightPad;
      instanceHeight = childrenLayout.height + 60; // Header + bottom margin

      // Ensure minimum size for text and ports
      if (instanceWidth < minTextWidth) {
        instanceWidth = minTextWidth;
      }
      if (instanceHeight < portRequiredHeight) {
        instanceHeight = portRequiredHeight;
      }
    } else {
      // Collapsed node - use minimum size based on text and ports
      instanceWidth = minTextWidth;
      instanceHeight = portRequiredHeight > 80.0 ? portRequiredHeight : 80.0;
    }

    final instance = SchematicInstanceData(
      id: node.path(),
      x: x,
      y: y,
      width: instanceWidth,
      height: instanceHeight,
      name: node.name,
      cls: 'Module',
      cssClass: depth == 0 ? 'node node-0' : 'node',
      hasChildren: hasChildren,
      isExpanded: isExpanded,
      children: node.children.map((c) => c.path()).toList(),
    );
    instances.add(instance);

    // Add ports for this node
    ports.addAll(_createPortsForInstance(node, instance));

    return (width: instanceWidth, height: instanceHeight);
  }

  /// Layout children in a grid and return the total size needed.
  ({double width, double height}) _layoutChildren({
    required List<HierarchyOccurrence> children,
    required double parentX,
    required double parentY,
    required Set<String> expandedNodes,
    required int depth,
    required List<SchematicInstanceData> instances,
    required List<SchematicPortData> ports,
  }) {
    if (children.isEmpty) {
      return (width: 0, height: 0);
    }

    const maxCols = 3;

    // First pass: calculate all child sizes (bottom-up)
    final childSizes = <({double width, double height})>[];
    for (final child in children) {
      final size = _calculateNodeSize(child, expandedNodes, depth);
      childSizes.add(size);
    }

    // Calculate row heights and column widths
    final numRows = (children.length / maxCols).ceil();
    final rowHeights = List<double>.filled(numRows, 0);
    final colWidths = List<double>.filled(maxCols, 0);

    for (var i = 0; i < children.length; i++) {
      final row = i ~/ maxCols;
      final col = i % maxCols;
      final size = childSizes[i];

      if (size.height > rowHeights[row]) {
        rowHeights[row] = size.height;
      }
      if (size.width > colWidths[col]) {
        colWidths[col] = size.width;
      }
    }

    // Second pass: place children with proper positioning (top-down)
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final row = i ~/ maxCols;
      final col = i % maxCols;

      // Calculate X position based on actual column widths
      var x = parentX;
      for (var c = 0; c < col; c++) {
        x += colWidths[c] + _horizontalSpacing;
      }

      // Calculate Y position based on actual row heights
      var y = parentY;
      for (var r = 0; r < row; r++) {
        y += rowHeights[r] + _verticalSpacing;
      }

      _synthesizeNode(
        node: child,
        x: x,
        y: y,
        depth: depth,
        expandedNodes: expandedNodes,
        instances: instances,
        ports: ports,
      );
    }

    // Calculate total size from actual column widths and row heights
    var totalWidth = 0.0;
    final numCols = children.length < maxCols ? children.length : maxCols;
    for (var c = 0; c < numCols; c++) {
      totalWidth += colWidths[c];
      if (c < numCols - 1) {
        totalWidth += _horizontalSpacing;
      }
    }

    var totalHeight = 0.0;
    for (var r = 0; r < numRows; r++) {
      totalHeight += rowHeights[r];
      if (r < numRows - 1) {
        totalHeight += _verticalSpacing;
      }
    }

    return (width: totalWidth, height: totalHeight);
  }

  /// Calculate the size a node would need (without actually creating it).
  /// This is the bottom-up pass that calculates sizes from leaves to root.
  ({double width, double height}) _calculateNodeSize(
    HierarchyOccurrence node,
    Set<String> expandedNodes,
    int depth,
  ) {
    final isExpanded = expandedNodes.contains(node.path());
    final hasChildren = node.children.isNotEmpty;

    // Calculate minimum width based on text (module name + port labels)
    final minTextWidth = _calculateMinWidth(node);

    // Calculate port requirements for height
    final nodePorts = node.ports;
    final inputCount = nodePorts
        .where((p) => p.direction == 'input' || p.direction == 'inout')
        .length;
    final outputCount = nodePorts.where((p) => p.direction == 'output').length;
    final maxPortsOnSide = inputCount > outputCount ? inputCount : outputCount;
    final portRequiredHeight = 30.0 + maxPortsOnSide * (_portHeight + 5) + 20.0;

    if (isExpanded && hasChildren) {
      // Compute side paddings that clear port labels
      final (leftPad, rightPad) = _portSidePaddings(node);

      // Need to calculate children layout size (recursive bottom-up)
      final childrenSize = _calculateChildrenSize(
        node.children,
        expandedNodes,
        depth + 1,
      );
      var width = childrenSize.width + leftPad + rightPad;
      var height = childrenSize.height + 60; // Header + bottom margin

      // Ensure minimum size for text and ports
      if (width < minTextWidth) {
        width = minTextWidth;
      }
      if (height < portRequiredHeight) {
        height = portRequiredHeight;
      }

      return (width: width, height: height);
    } else {
      // Collapsed node - use minimum size based on text and ports
      final height = portRequiredHeight > 80.0 ? portRequiredHeight : 80.0;
      return (width: minTextWidth, height: height);
    }
  }

  /// Calculate total size needed for a set of children.
  /// Uses actual child sizes for proper layout.
  ({double width, double height}) _calculateChildrenSize(
    List<HierarchyOccurrence> children,
    Set<String> expandedNodes,
    int depth,
  ) {
    if (children.isEmpty) {
      return (width: 0, height: 0);
    }

    const maxCols = 3;

    // Calculate all child sizes first (bottom-up recursion)
    final childSizes = <({double width, double height})>[];
    for (final child in children) {
      final size = _calculateNodeSize(child, expandedNodes, depth);
      childSizes.add(size);
    }

    // Calculate row heights and column widths from actual child sizes
    final numRows = (children.length / maxCols).ceil();
    final rowHeights = List<double>.filled(numRows, 0);
    final colWidths = List<double>.filled(maxCols, 0);

    for (var i = 0; i < children.length; i++) {
      final row = i ~/ maxCols;
      final col = i % maxCols;
      final size = childSizes[i];

      if (size.height > rowHeights[row]) {
        rowHeights[row] = size.height;
      }
      if (size.width > colWidths[col]) {
        colWidths[col] = size.width;
      }
    }

    // Sum up total dimensions
    var totalWidth = 0.0;
    final numCols = children.length < maxCols ? children.length : maxCols;
    for (var c = 0; c < numCols; c++) {
      totalWidth += colWidths[c];
      if (c < numCols - 1) {
        totalWidth += _horizontalSpacing;
      }
    }

    var totalHeight = 0.0;
    for (var r = 0; r < numRows; r++) {
      totalHeight += rowHeights[r];
      if (r < numRows - 1) {
        totalHeight += _verticalSpacing;
      }
    }

    return (width: totalWidth, height: totalHeight);
  }

  List<SchematicPortData> _createPortsForInstance(
    HierarchyOccurrence node,
    SchematicInstanceData instance,
  ) {
    final result = <SchematicPortData>[];
    final nodePorts = node.ports;

    // Separate inputs and outputs
    final inputs = nodePorts.where((p) => p.direction == 'input').toList();
    final outputs = nodePorts.where((p) => p.direction == 'output').toList();
    final inouts = nodePorts
        .where((p) => p.direction != 'input' && p.direction != 'output')
        .toList();

    // Place inputs on the left (WEST)
    var westYOffset = 30.0;
    for (final port in inputs) {
      result.add(
        SchematicPortData(
          id: port.name,
          instanceId: instance.id,
          x: instance.x,
          y: instance.y + westYOffset,
          width: _portWidth,
          height: _portHeight,
          name: port.name,
          direction: 'INPUT',
          side: 'WEST',
        ),
      );
      westYOffset += _portHeight + 5;
    }

    // Place outputs on the right (EAST)
    var eastYOffset = 30.0;
    for (final port in outputs) {
      result.add(
        SchematicPortData(
          id: port.name,
          instanceId: instance.id,
          x: instance.x + instance.width - _portWidth,
          y: instance.y + eastYOffset,
          width: _portWidth,
          height: _portHeight,
          name: port.name,
          direction: 'OUTPUT',
        ),
      );
      eastYOffset += _portHeight + 5;
    }

    // Place inouts on the left (WEST) below inputs — bidirectional
    for (final port in inouts) {
      result.add(
        SchematicPortData(
          id: port.name,
          instanceId: instance.id,
          x: instance.x,
          y: instance.y + westYOffset,
          width: _portWidth,
          height: _portHeight,
          name: port.name,
          side: 'WEST',
        ),
      );
      westYOffset += _portHeight + 5;
    }

    return result;
  }

  /// Synthesizes edges between connected ports.
  ///
  /// This is a placeholder - real connectivity requires netlist data.
  /// For now, returns empty list. When real data is loaded, edges can
  /// be created by matching port names between parent and child modules.
  List<SchematicEdgeData> synthesizeEdges(List<SchematicPortData> ports) => [];
}
