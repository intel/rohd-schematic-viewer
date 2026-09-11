// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_search_netlist_test.dart
// Tests for netlist hierarchy search.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

void main() {
  test('HierarchyService searchNodes and autocomplete (netlist)', () {
    final netlist = {
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': {
            'u_child': {'type': 'Child', 'connections': <String, dynamic>{}},
            'u_and': {'type': r'$and', 'connections': <String, dynamic>{}},
          },
        },
        'Child': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': {
            'leaf': {'type': r'$not', 'connections': <String, dynamic>{}},
          },
        },
      },
    };

    final svc = NetlistHierarchyAdapter.fromJson(jsonEncode(netlist));

    final found = svc.searchOccurrences('Top/u_ch');
    expect(found.any((n) => n.name == 'u_child'), isTrue);

    final sugg = svc.autocompletePaths('Top/u_');
    expect(sugg.any((s) => s.contains('Top/u_child')), isTrue);
    expect(sugg.any((s) => s.contains('Top/u_and')), isTrue);
  });
}
