// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_netlist_adapter_test.dart
// Tests for netlist hierarchy adapter.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

void main() {
  test('Netlist adapter builds modules and instances', () {
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
            'u_child': {
              'type': 'Child',
              'connections': {
                'a': [1],
                'b': [2],
                'y': [3],
              },
            },
            'and_1': {'type': r'$_AND_', 'connections': <String, dynamic>{}},
          },
        },
        'Child': {
          'ports': {
            'i': {
              'direction': 'input',
              'bits': [10],
            },
          },
          'netnames': {
            'i': {
              'bits': [10],
            },
          },
          'cells': <String, dynamic>{},
        },
      },
    };

    final adapter = NetlistHierarchyAdapter.fromJson(jsonEncode(netlist));

    expect(adapter.root.name, 'Top');

    final rootChildren = adapter.root.children;
    final childNames = rootChildren.map((n) => n.name).toSet();
    expect(childNames.contains('u_child'), isTrue);
    expect(childNames.contains('and_1'), isTrue);

    final childModule = rootChildren.firstWhere((n) => n.name == 'u_child');
    expect(childModule.isPrimitive, isFalse);
    final childPorts = childModule.signals.where((s) => s.isPort).toList();
    expect(childPorts.length, 1);
    expect(childPorts.first.name, 'i');
    expect(childPorts.first.direction, 'input');

    final primitive = rootChildren.firstWhere((n) => n.name == 'and_1');
    expect(primitive.isPrimitive, isTrue);
    expect(primitive.signals.where((s) => s.isPort), isEmpty);

    final rootPorts = adapter.root.signals.where((s) => s.isPort).toList();
    expect(rootPorts.length, 3);
    expect(
      rootPorts.any(
        (p) => p.name == 'a' && p.direction == 'input' && p.width == 1,
      ),
      isTrue,
    );
    expect(
      rootPorts.any(
        (p) => p.name == 'y' && p.direction == 'output' && p.width == 1,
      ),
      isTrue,
    );

    adapter.root.buildAddresses();
    final uChildAddr = OccurrenceAddress.tryFromPathname(
      'Top/u_child',
      adapter.root,
    );
    expect(uChildAddr, isNotNull);
    expect(adapter.occurrenceByAddress(uChildAddr!)?.name, 'u_child');
  });
}
