// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// hierarchy_search_rohd_test.dart
// Tests for ROHD hierarchy search.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_hierarchy/rohd_hierarchy.dart';

void main() {
  test('HierarchyService searchNodes and autocomplete (ROHD-compatible)', () {
    // ROHD now emits Yosys-compatible JSON — same format with or without
    // synthesis. Use NetlistHierarchyAdapter for all netlist data.
    final json = {
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': {
            'Alpha': {'type': 'Alpha', 'connections': <String, dynamic>{}},
            'Beta': {'type': 'Beta', 'connections': <String, dynamic>{}},
          },
        },
        'Alpha': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
        'Beta': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': {
            'Gamma': {'type': 'Gamma', 'connections': <String, dynamic>{}},
          },
        },
        'Gamma': {
          'ports': <String, dynamic>{},
          'netnames': <String, dynamic>{},
          'cells': <String, dynamic>{},
        },
      },
    };

    final svc = NetlistHierarchyAdapter.fromJson(jsonEncode(json));

    // Fuzzy hierarchical search
    final found = svc.searchOccurrences('Top/B/Gam');
    expect(found.any((n) => n.name == 'Gamma'), isTrue);

    // Autocomplete root children
    final suggRoot = svc.autocompletePaths('');
    expect(suggRoot.any((s) => s.contains('Top/Alpha')), isTrue);
    expect(suggRoot.any((s) => s.contains('Top/Beta')), isTrue);

    // Autocomplete suggestions behave hierarchically at each level
    final sugg = svc.autocompletePaths('Top/');
    expect(sugg.any((s) => s.contains('Top/Alpha')), isTrue);
    expect(sugg.any((s) => s.contains('Top/Beta')), isTrue);
  });
}
