// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_connectivity_test.dart
// Public connectivity facade tests.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert' show jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/schematic_connectivity.dart';

const _netlist = r'''
{
  "modules": {
    "Top": {
      "attributes": {"top": 1},
      "ports": {
        "a": {"direction": "input", "bits": [1]},
        "y": {"direction": "output", "bits": [2]}
      },
      "cells": {
        "inverter": {
          "type": "$_NOT_",
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [1],
            "Y": [2]
          }
        }
      },
      "netnames": {
        "a": {"bits": [1]},
        "y": {"bits": [2]}
      }
    }
  }
}
''';

void main() {
  late NetlistSchematicConnectivity connectivity;

  setUp(() {
    connectivity = NetlistSchematicConnectivity.fromJson(_netlist);
  });

  test('returns immutable endpoint data without exposing layout objects', () {
    final signals = connectivity.hierarchy.root.signals;
    final endpoints = [
      for (final signal in signals) ...connectivity.fanin(signal),
      for (final signal in signals) ...connectivity.fanout(signal),
    ];

    expect(endpoints, isNotEmpty);
    expect(endpoints.first.nodePath, isNotEmpty);
    expect(endpoints.first.portId, isNotEmpty);
    expect(
      endpoints.first.direction.toLowerCase(),
      anyOf('input', 'output', 'inout'),
    );
  });

  test('traverses through transparent primitive gates', () {
    final input = connectivity.hierarchy.root.signals.singleWhere(
      (signal) => signal.name == 'a',
    );

    final endpoints = connectivity.fanout(
      input,
      mode: SchematicTraversalMode.transparent,
    );

    expect(endpoints, isNotEmpty);
    expect(
      endpoints.every((endpoint) => !endpoint.nodePath.endsWith('/inverter')),
      isTrue,
    );
  });

  test('traverses long transparent primitive chains', () {
    final chainedConnectivity = NetlistSchematicConnectivity.fromJson(
      _transparentChainNetlist(256),
    );
    final input = chainedConnectivity.hierarchy.root.signals.singleWhere(
      (signal) => signal.name == 'a',
    );

    final endpoints = chainedConnectivity.fanout(
      input,
      mode: SchematicTraversalMode.transparent,
    );

    expect(endpoints, hasLength(1));
    expect(endpoints.single.direction.toLowerCase(), 'output');
    expect(endpoints.single.nodePath, isNot(contains('inverter')));
  });
}

String _transparentChainNetlist(int gateCount) {
  final cells = <String, Object?>{};
  final netnames = <String, Object?>{
    'a': {
      'bits': [1],
    },
    'y': {
      'bits': [gateCount + 1],
    },
  };

  for (var index = 0; index < gateCount; index++) {
    cells['inverter_$index'] = {
      'type': r'$_NOT_',
      'port_directions': {
        'A': 'input',
        'Y': 'output',
      },
      'connections': {
        'A': [index + 1],
        'Y': [index + 2],
      },
    };
    if (index < gateCount - 1) {
      netnames['n$index'] = {
        'bits': [index + 2],
      };
    }
  }

  return jsonEncode({
    'modules': {
      'Top': {
        'attributes': {'top': 1},
        'ports': {
          'a': {
            'direction': 'input',
            'bits': [1],
          },
          'y': {
            'direction': 'output',
            'bits': [gateCount + 1],
          },
        },
        'cells': cells,
        'netnames': netnames,
      },
    },
  });
}
