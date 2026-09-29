// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// transparent_traversal.dart
// Shared transparent-operator traversal helpers.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

const _transparentOperators = <String>{
  'BUF',
  '_BUF_',
  'NOT',
  '_NOT_',
  'SLICE',
  'CONCAT',
  'STRUCT_PACK',
  'STRUCT_UNPACK',
};

/// Whether [node] is a leaf operator that traversal may pass through.
bool isTransparentTraversalNode(LayoutNode node) =>
    node.hwMeta.cls == 'Operator' &&
    _transparentOperators.contains(node.hwMeta.name) &&
    node.children.isEmpty &&
    (node.hiddenChildren == null || node.hiddenChildren!.isEmpty);

/// Port indices on the opposite side of [node] from [entryPortIndex].
List<int> transparentTraversalExitPorts(
  LayoutNode node,
  int entryPortIndex,
) {
  if (entryPortIndex < 0 || entryPortIndex >= node.elkPorts.length) {
    return const [];
  }
  final entryDirection = node.elkPorts[entryPortIndex].direction;
  if (entryDirection == PortDirection.inout) {
    return [
      for (var i = 0; i < node.elkPorts.length; i++)
        if (i != entryPortIndex) i,
    ];
  }

  final oppositeDirection = entryDirection == PortDirection.input
      ? PortDirection.output
      : PortDirection.input;
  return [
    for (var i = 0; i < node.elkPorts.length; i++)
      if (node.elkPorts[i].direction == oppositeDirection ||
          node.elkPorts[i].direction == PortDirection.inout)
        i,
  ];
}
