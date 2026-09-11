// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_rohd_adapter_test.dart
// Tests for ROHD hierarchy adapter.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

void main() {
  test('Netlist adapter builds tree and ports from ROHD-compatible format', () {
    // ROHD now emits Yosys-compatible JSON even without synthesis.
    // Modules have ports and cells but no connectivity data.
    final json = {
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': {
            'a': {
              'direction': 'input',
              'bits': [1, 2, 3, 4],
            },
            'y': {
              'direction': 'output',
              'bits': [5],
            },
          },
          'netnames': <String, dynamic>{},
          'cells': {
            'Child': {'type': 'Child', 'connections': <String, dynamic>{}},
          },
        },
        'Child': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
      },
    };

    final svc = NetlistHierarchyAdapter.fromJson(jsonEncode(json));

    expect(svc.root.name, 'Top');
    final kids = svc.root.children;
    expect(kids.length, 1);
    expect(kids.first.name, 'Child');

    final ports = svc.root.signals.where((s) => s.isPort).toList();
    expect(ports.length, 2);
    expect(
      ports.any((p) => p.name == 'a' && p.direction == 'input' && p.width == 4),
      isTrue,
    );
    expect(
      ports.any(
        (p) => p.name == 'y' && p.direction == 'output' && p.width == 1,
      ),
      isTrue,
    );

    svc.root.buildAddresses();
    final childPath = '${svc.root.path()}/Child';
    final childAddr = OccurrenceAddress.tryFromPathname(childPath, svc.root);
    expect(childAddr, isNotNull);
    expect(svc.occurrenceByAddress(childAddr!)?.name, 'Child');
  });
}
