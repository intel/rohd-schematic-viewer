// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_schematic_adapter_test.dart
// Tests for the Yosys JSON schematic adapter.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

void main() {
  test('maps documented Yosys primitive cells without legacy adapter helpers',
      () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode({
        'modules': {
          'Top': {
            'attributes': {'top': 1},
            'ports': <String, dynamic>{},
            'netnames': <String, dynamic>{},
            'cells': {
              'reduce_or': _cell(r'$reduce_or'),
              'flip_flop': _flipFlopCell(r'$dff'),
              'enabled_flip_flop': _flipFlopCell(r'$dffe'),
              'sync_reset_flip_flop': _flipFlopCell(r'$sdff'),
              'sync_reset_enabled_flip_flop': _flipFlopCell(r'$sdffe'),
              'async_reset_flip_flop': _flipFlopCell(r'$adff'),
              'async_reset_enabled_flip_flop': _flipFlopCell(r'$adffe'),
              'async_load_flip_flop': _flipFlopCell(r'$aldff'),
              'async_load_enabled_flip_flop': _flipFlopCell(r'$aldffe'),
              'latch': _cell(r'$dlatch', parameters: {'EN_POLARITY': 1}),
              'mux': _cell(r'$pmux'),
              'replicate_x3': _replicationCell(outputWidth: 12),
              'replicate_x5': _replicationCell(outputWidth: 20),
            },
          },
        },
      }),
    );

    final top = adapter.schematic.getNode('0')!;
    final children =
        top.children.isNotEmpty ? top.children : top.hiddenChildren!;

    expect(_nodeNamed(children, 'reduce_or').hwMeta.name, 'OR');
    for (final instanceName in [
      'flip_flop',
      'enabled_flip_flop',
      'sync_reset_flip_flop',
      'sync_reset_enabled_flip_flop',
      'async_reset_flip_flop',
      'async_reset_enabled_flip_flop',
      'async_load_flip_flop',
      'async_load_enabled_flip_flop',
    ]) {
      final node = _nodeNamed(children, instanceName);
      expect(node.hwMeta.name, 'FF');
      expect(
        node.elkPorts.singleWhere((port) => port.hwMeta.name == 'CLK').side,
        PortSide.south,
        reason: instanceName,
      );
    }
    expect(_nodeNamed(children, 'latch').hwMeta.name, 'DLATCH_en1');
    expect(_nodeNamed(children, 'mux').hwMeta.name, 'MUX');
    for (final (instanceName, outputLabel) in [
      ('replicate_x3', '3 X --> [11:0]'),
      ('replicate_x5', '5 X --> [19:0]'),
    ]) {
      final node = _nodeNamed(children, instanceName);
      expect(node.hwMeta.name, 'CONCAT');
      expect(
        node.elkPorts.map((port) => port.hwMeta.name),
        containsAll(['[3:0]', outputLabel]),
      );
    }
    expect(children.every((node) => node.hwMeta.cls == 'Operator'), isTrue);
  });
}

Map<String, dynamic> _flipFlopCell(String type) => {
      'type': type,
      'parameters': <String, dynamic>{},
      'port_directions': {'CLK': 'input', 'D': 'input', 'Q': 'output'},
      'connections': {
        'CLK': [1],
        'D': [2],
        'Q': [3],
      },
    };

Map<String, dynamic> _replicationCell({required int outputWidth}) => {
      'type': 'ReplicationOp',
      'parameters': <String, dynamic>{},
      'port_directions': {
        '_a4': 'input',
        '_replicated_a4': 'output',
      },
      'connections': {
        '_a4': [1, 2, 3, 4],
        '_replicated_a4': List.generate(outputWidth, (index) => index + 10),
      },
    };

Map<String, dynamic> _cell(
  String type, {
  Map<String, dynamic> parameters = const {},
}) =>
    {
      'type': type,
      'parameters': parameters,
      'port_directions': <String, dynamic>{},
      'connections': <String, dynamic>{},
    };

LayoutNode _nodeNamed(List<LayoutNode> nodes, String instanceName) =>
    nodes.singleWhere(
      (node) => node.hwMeta.extra?['instanceName'] == instanceName,
    );
