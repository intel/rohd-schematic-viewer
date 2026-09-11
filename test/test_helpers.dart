// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// test_helpers.dart
// Shared test utilities for creating LayoutNode test fixtures.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

/// Create a `LayoutNode` for tests, wrapping a placeholder
/// `HierarchyOccurrence`.
///
/// This replaces direct node construction in tests. The `id` is used as both
/// the layout-graph ID and hierarchy node ID. The display `name` defaults to
/// `hwMeta.name` if provided, else `id`.
LayoutNode makeTestNode(
  String id, {
  HwMeta? hwMeta,
  List<ElkPort>? ports,
  List<LayoutNode>? children,
  List<LayoutNode>? hiddenChildren,
  List<LayoutHyperedge>? hyperedges,
  Set<String>? partialChildIds,
  Set<String>? partialHyperedgeIds,
}) {
  final displayName = hwMeta?.name ?? id;
  final hNode = HierarchyOccurrence(name: displayName);
  return LayoutNode(
    id: id,
    occurrence: hNode,
    hwMeta: hwMeta,
    elkPorts: ports,
    children: children,
    hiddenChildren: hiddenChildren,
    hyperedges: hyperedges,
    partialChildIds: partialChildIds,
    partialHyperedgeIds: partialHyperedgeIds,
  );
}
