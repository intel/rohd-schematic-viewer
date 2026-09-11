// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_wire_zoom.dart
// Zoom-to-fit functionality for selected wires.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:material_ui/material_ui.dart';

import 'package:rohd_schematic_viewer/src/services/services.dart';

/// Represents the zoom/pan state needed to view a wire
class WireViewState {
  /// Scale (zoom level) to apply
  final double scale;

  /// Offset (pan position) to apply
  final Offset offset;

  /// Bounding box of the wire in schematic coordinates
  final Rect wireBounds;

  /// True if the wire fits within the block and zoom is set to 150% of smallest
  /// dimension
  final bool isFocusedZoom;

  /// Constructor for the WireViewState to keep track of zoom and pan for a
  /// wire.
  WireViewState({
    required this.scale,
    required this.offset,
    required this.wireBounds,
    required this.isFocusedZoom,
  });
}

/// Utility class for computing zoom-to-fit transformations for wires
class SchematicWireZoom {
  /// Compute zoom and pan to focus on a specific wire
  ///
  /// Finds all edges with the given [wireId] and computes a bounding box.
  /// Optionally restricts the search to a node scope (for duplicated blocks).
  /// Then determines the appropriate zoom level:
  /// - If the wire's bounding box is large enough to use most of the viewport,
  ///   uses "fit" zoom (fill viewport)
  /// - Otherwise, zooms to 150% of the smallest dimension of the wire's
  ///   bounding box
  ///
  /// Returns null if no edges with the given wireId exist.
  static WireViewState? computeWireZoom({
    required SchematicLayoutResult layout,
    required String wireId,
    required Size viewportSize,
    double padding = 40.0,
    double focusedZoomRatio = 1.5,
    String? scopeNodeId,
  }) {
    final portMap = <String, SchematicPortData>{
      for (final port in layout.ports) port.id: port,
    };

    /// Check if a node is within the given scope (is a descendant of scopeId)
    bool isNodeInScope(String? nodeId, String scopeId) {
      if (nodeId == null) {
        return false;
      }
      if (nodeId == scopeId) {
        return true;
      }

      // Walk up the parent chain to check if scopeId is an ancestor
      String? currentId = nodeId;
      var maxIterations = 100; // Prevent infinite loops
      while (currentId != null && maxIterations-- > 0) {
        if (currentId == scopeId) {
          return true;
        }
        currentId = layout.parentMap[currentId];
      }
      return false;
    }

    String? getEdgeNodeId(SchematicEdgeData edge) {
      String? sourceNodeId;

      if (edge.sourcePort != null) {
        final sourcePort = portMap[edge.sourcePort];
        sourceNodeId = sourcePort?.instanceId;
      }

      return sourceNodeId;
    }

    String? getEdgeTargetNodeId(SchematicEdgeData edge) {
      if (edge.targetPort != null) {
        final targetPort = portMap[edge.targetPort];
        return targetPort?.instanceId;
      }
      return null;
    }

    // Parse wireId to determine which block to search in
    // If wireId contains '/', extract the block path
    var edgesToSearch = layout.edges;
    var searchWireId = wireId;

    if (wireId.contains('/')) {
      // WireId has a path like "adder1/internal_wire_123"
      // We need to find the node with ID matching the block path
      final parts = wireId.split('/');
      if (parts.length >= 2) {
        searchWireId = parts.last; // Use just the wire name for matching
      }
    }

    if (scopeNodeId != null && scopeNodeId.isNotEmpty) {
      // Use hierarchical scope checking: include edges whose source or target
      // nodes are descendants of the scope node
      final scopedEdges = edgesToSearch.where((edge) {
        final sourceNodeId = getEdgeNodeId(edge);
        final targetNodeId = getEdgeTargetNodeId(edge);
        return isNodeInScope(sourceNodeId, scopeNodeId) ||
            isNodeInScope(targetNodeId, scopeNodeId);
      }).toList();

      if (scopedEdges.isNotEmpty) {
        edgesToSearch = scopedEdges;
      }
    }

    // Find all edges with this wireId
    // First try exact match with full wireId
    var matchingEdges = edgesToSearch.where((e) => e.wireId == wireId).toList();

    // If no exact match, try matching by searchWireId (which might be just the
    // wire name without path)
    if (matchingEdges.isEmpty && searchWireId != wireId) {
      matchingEdges =
          edgesToSearch.where((e) => e.wireId == searchWireId).toList();
    }

    // If no exact match, try matching by simple name (last part after /)
    if (matchingEdges.isEmpty) {
      final simpleName = searchWireId.contains('/')
          ? searchWireId.split('/').last
          : searchWireId;
      matchingEdges = edgesToSearch.where((e) {
        final edgeSimpleName =
            e.wireId.contains('/') ? e.wireId.split('/').last : e.wireId;
        return edgeSimpleName == simpleName;
      }).toList();
    }

    // If still no match, try searching for edges whose wireId ends with the
    // simple name
    if (matchingEdges.isEmpty) {
      final simpleName = searchWireId.contains('/')
          ? searchWireId.split('/').last
          : searchWireId;
      matchingEdges = edgesToSearch
          .where(
            (e) =>
                e.wireId.endsWith(simpleName) ||
                e.wireId.contains('/$simpleName'),
          )
          .toList();
    }

    // If still no match, try a broader search: check if simple name appears
    // anywhere in wireId
    if (matchingEdges.isEmpty) {
      final simpleName = searchWireId.contains('/')
          ? searchWireId.split('/').last
          : searchWireId;
      // Remove trailing `__out` or `__in` markers and try again
      final baseName =
          simpleName.replaceAll('__out', '').replaceAll('__in', '');

      if (baseName.isNotEmpty && baseName != simpleName) {
        matchingEdges =
            edgesToSearch.where((e) => e.wireId.contains(baseName)).toList();
      }
    }

    if (matchingEdges.isEmpty) {
      return null;
    }

    // Compute bounding box of all edges
    final wireBounds = _computeEdgeBoundingBox(matchingEdges);
    if (wireBounds.isEmpty) {
      return null;
    }

    // Determine if this is a "fit" zoom (wire spans most of block)
    final blockArea = layout.width * layout.height;
    final wireArea = wireBounds.width * wireBounds.height;
    final isFitZoom = wireArea > 0 && (wireArea / blockArea) > 0.4;

    double scale;
    if (isFitZoom) {
      // Wire is large: use "fit" zoom (zoom to viewport)
      scale = _computeFitZoom(
        wireBounds: wireBounds,
        viewportSize: viewportSize,
        padding: padding,
      );
    } else {
      // Wire is small: zoom to 150% of smallest dimension
      scale = _computeFocusedZoom(
        wireBounds: wireBounds,
        viewportSize: viewportSize,
        focusedZoomRatio: focusedZoomRatio,
        padding: padding,
      );
    }

    // Compute offset to center the wire
    final offset = _computeOffset(
      wireBounds: wireBounds,
      viewportSize: viewportSize,
      scale: scale,
    );

    return WireViewState(
      scale: scale,
      offset: offset,
      wireBounds: wireBounds,
      isFocusedZoom: !isFitZoom,
    );
  }

  /// Compute bounding box of all edge points
  static Rect _computeEdgeBoundingBox(List<SchematicEdgeData> edges) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    for (final edge in edges) {
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

    if (minX == double.infinity || minY == double.infinity) {
      return Rect.zero;
    }

    // Add padding around the edges
    const edgePadding = 20.0;
    return Rect.fromLTRB(
      minX - edgePadding,
      minY - edgePadding,
      maxX + edgePadding,
      maxY + edgePadding,
    );
  }

  /// Compute zoom level to fit bounding box in viewport
  static double _computeFitZoom({
    required Rect wireBounds,
    required Size viewportSize,
    required double padding,
  }) {
    final scaleX = (viewportSize.width - padding) / wireBounds.width;
    final scaleY = (viewportSize.height - padding) / wireBounds.height;
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.05, 3.0);
    return scale;
  }

  /// Compute zoom level to show wire at 150% of its smallest dimension
  static double _computeFocusedZoom({
    required Rect wireBounds,
    required Size viewportSize,
    required double focusedZoomRatio,
    required double padding,
  }) {
    final smallestDimension = wireBounds.width < wireBounds.height
        ? wireBounds.width
        : wireBounds.height;

    // Scale so that the smallest dimension takes up (viewport *
    // focusedZoomRatio) space But cap it at the fit-to-viewport zoom
    final viewportSmallest = viewportSize.width < viewportSize.height
        ? viewportSize.width
        : viewportSize.height;

    final focusedZoom =
        (viewportSmallest * focusedZoomRatio / (smallestDimension * 2)).clamp(
      0.05,
      3.0,
    );

    // Also compute fit zoom as a ceiling
    final fitScaleX = (viewportSize.width - padding) / wireBounds.width;
    final fitScaleY = (viewportSize.height - padding) / wireBounds.height;
    final fitZoom = (fitScaleX < fitScaleY ? fitScaleX : fitScaleY).clamp(
      0.05,
      3.0,
    );

    return focusedZoom < fitZoom ? focusedZoom : fitZoom;
  }

  /// Compute offset to center the bounding box in the viewport
  static Offset _computeOffset({
    required Rect wireBounds,
    required Size viewportSize,
    required double scale,
  }) {
    final scaledWidth = wireBounds.width * scale;
    final scaledHeight = wireBounds.height * scale;

    final offsetX =
        (viewportSize.width - scaledWidth) / 2 - wireBounds.left * scale;
    final offsetY =
        (viewportSize.height - scaledHeight) / 2 - wireBounds.top * scale;

    return Offset(offsetX, offsetY);
  }
}
