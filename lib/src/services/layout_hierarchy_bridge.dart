// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// layout_hierarchy_bridge.dart
// Bridge between schematic layout and source-agnostic hierarchy service.
// Provides scope checks using stable hierarchical paths.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

/// Bridge between schematic layout and hierarchy service.
class LayoutHierarchyBridge {
  /// Source-agnostic hierarchy service.
  final HierarchyService hierarchy;

  /// The layout whose instances this bridge maps.
  final SchematicLayoutResult layout;

  /// Map from layout instance ID to hierarchy node (module/instance)
  final Map<String, String> instanceIdToOccurrenceId;

  /// Create a new [LayoutHierarchyBridge].
  LayoutHierarchyBridge({
    required this.hierarchy,
    required this.layout,
    required this.instanceIdToOccurrenceId,
  });

  /// Build a [LayoutHierarchyBridge] from hierarchy and layout data.
  factory LayoutHierarchyBridge.build({
    required HierarchyService hierarchy,
    required SchematicLayoutResult layout,
  }) {
    final instanceIdToOccurrenceId = <String, String>{};

    // Map layout instances to hierarchy nodes using their hierarchical names
    for (final layoutInstance in layout.instances) {
      var instancePath = layoutInstance.name;
      if (instancePath.startsWith('root/')) {
        instancePath = instancePath.substring(5);
      }
      if (instancePath.isNotEmpty) {
        final addr = OccurrenceAddress.tryFromPathname(
          instancePath,
          hierarchy.root,
        );
        final node = addr != null ? hierarchy.occurrenceByAddress(addr) : null;
        if (node != null) {
          instanceIdToOccurrenceId[layoutInstance.id] = node.path();
        }
      }
    }

    return LayoutHierarchyBridge(
      hierarchy: hierarchy,
      layout: layout,
      instanceIdToOccurrenceId: instanceIdToOccurrenceId,
    );
  }

  /// Check if a layout instance is in scope of another layout instance using
  /// hierarchy paths when available; falls back to visual hierarchy.
  bool isInstanceInScope(String? instanceId, String scopeId) {
    if (instanceId == null) {
      return false;
    }
    if (instanceId == scopeId) {
      return true;
    }

    final occurrenceId = instanceIdToOccurrenceId[instanceId];
    final scopeOccurrenceId = instanceIdToOccurrenceId[scopeId];
    if (occurrenceId != null && scopeOccurrenceId != null) {
      // Occurrence IDs are hierarchical paths (e.g. "Top/child").
      final occurrencePath = occurrenceId;
      final scopePath = scopeOccurrenceId;
      if (occurrencePath == scopePath) {
        return true;
      }
      if (occurrencePath.startsWith('$scopePath/')) {
        return true;
      }
      return false;
    }

    // Fallback: walk the layout parent map
    String? current = instanceId;
    var maxIterations = 100;
    while (current != null && maxIterations-- > 0) {
      if (current == scopeId) {
        return true;
      }
      current = layout.parentMap[current];
    }
    return false;
  }
}
