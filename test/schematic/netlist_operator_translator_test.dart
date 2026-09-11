// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_operator_translator_test.dart
// Tests for netlist operator translation into schematic operator shapes.
//
// 2026 July
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/operator_shapes.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

void main() {
  test('replication uses the concatenation shape', () {
    expect(
      NetlistOperatorTranslator.translate('ReplicationOp'),
      ('CONCAT', 'Operator'),
    );
    expect(OperatorShapes.getPathForOperator('CONCAT'), isNotNull);
  });

  test('flip-flops preserve their controls and signal polarities', () {
    const cases =
        <(String cellType, Map<String, dynamic> parameters, String shape)>[
      (r'$dff', {'CLK_POLARITY': 1}, 'FF_clk1'),
      (
        r'$dffe',
        {'CLK_POLARITY': 0, 'EN_POLARITY': 1},
        'FF_EN_clk0_en1',
      ),
      (
        r'$sdff',
        {'CLK_POLARITY': 1, 'SRST_POLARITY': 0},
        'FF_SRST_clk1_rst0',
      ),
      (
        r'$sdffe',
        {'CLK_POLARITY': 0, 'SRST_POLARITY': 1, 'EN_POLARITY': 0},
        'FF_SRST_EN_clk0_rst1_en0',
      ),
      (
        r'$adff',
        {'CLK_POLARITY': 0, 'ARST_POLARITY': 0},
        'FF_ARST_clk0_rst0',
      ),
      (
        r'$adffe',
        {'CLK_POLARITY': 1, 'ARST_POLARITY': 1, 'EN_POLARITY': 1},
        'FF_ARST_EN_clk1_rst1_en1',
      ),
    ];

    for (final (cellType, parameters, shape) in cases) {
      expect(
        NetlistOperatorTranslator.translate(cellType, parameters),
        (shape, 'Operator'),
        reason: cellType,
      );
    }

    for (final cellType in [r'$aldff', r'$aldffe']) {
      expect(NetlistOperatorTranslator.translate(cellType), ('FF', 'Operator'));
    }
  });

  test('modulo is translated as a primitive operator with percent symbol', () {
    expect(NetlistOperatorTranslator.translate(r'$mod'), ('MOD', 'Operator'));
    expect(NetlistOperatorTranslator.translate('Modulo'), ('MOD', 'Operator'));
    expect(OperatorShapes.getPathForOperator('MOD'), isNotNull);
    expect(OperatorShapes.getTextForOperator('MOD'), '%');
    expect(
      OperatorShapes.getTextOffsetForOperator('MOD'),
      const Offset(12.5, 12.5),
    );
  });

  test(r'modulo cells stay primitive even if a $mod module exists', () {
    final netlist = {
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': {
            'a': {
              'direction': 'input',
              'bits': [1],
            },
            'b': {
              'direction': 'input',
              'bits': [2],
            },
            'y': {
              'direction': 'output',
              'bits': [3],
            },
          },
          'netnames': {
            'a': {
              'bits': [1],
            },
            'b': {
              'bits': [2],
            },
            'y': {
              'bits': [3],
            },
          },
          'cells': {
            'mod_1': {
              'type': r'$mod',
              'port_directions': {'A': 'input', 'B': 'input', 'Y': 'output'},
              'connections': {
                'A': [1],
                'B': [2],
                'Y': [3],
              },
            },
          },
        },
        r'$mod': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
      },
    };

    final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(netlist));
    final top = adapter.schematic.getNode('0');

    expect(top, isNotNull);

    final modNode = top!.children.singleWhere(
      (node) => node.hwMeta.name == 'MOD',
    );
    expect(modNode.hwMeta.cls, 'Operator');
    expect(modNode.children, isEmpty);
    expect(modNode.hiddenChildren, anyOf(isNull, isEmpty));
  });

  test('named Modulo cells stay primitive operators', () {
    final netlist = {
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': {
            'a': {
              'direction': 'input',
              'bits': [1],
            },
            'b': {
              'direction': 'input',
              'bits': [2],
            },
            'y': {
              'direction': 'output',
              'bits': [3],
            },
          },
          'netnames': {
            'a': {
              'bits': [1],
            },
            'b': {
              'bits': [2],
            },
            'y': {
              'bits': [3],
            },
          },
          'cells': {
            'modulo': {
              'type': 'Modulo',
              'port_directions': {
                'in0': 'input',
                'in1': 'input',
                'out': 'output',
              },
              'connections': {
                'in0': [1],
                'in1': [2],
                'out': [3],
              },
            },
          },
        },
        'Modulo': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
      },
    };

    final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(netlist));
    final top = adapter.schematic.getNode('0');

    expect(top, isNotNull);

    final modNode = top!.children.singleWhere(
      (node) => node.hwMeta.name == 'MOD',
    );
    expect(modNode.hwMeta.cls, 'Operator');
    expect(modNode.children, isEmpty);
    expect(modNode.hiddenChildren, anyOf(isNull, isEmpty));
  });
}
