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
import 'package:rohd_hierarchy/rohd_hierarchy.dart' show BaseHierarchyAdapter;
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

const _hierarchicalNetlist = r'''
{
  "modules": {
    "Top": {
      "attributes": {"top": 1},
      "ports": {
        "top_a": {"direction": "input", "bits": [1]},
        "top_y": {"direction": "output", "bits": [2]}
      },
      "cells": {
        "u1": {
          "type": "Child",
          "port_directions": {
            "a": "input",
            "y": "output"
          },
          "connections": {
            "a": [1],
            "y": [2]
          }
        }
      },
      "netnames": {
        "top_a": {"bits": [1]},
        "top_y": {"bits": [2]}
      }
    },
    "Child": {
      "ports": {
        "a": {"direction": "input", "bits": [10]},
        "y": {"direction": "output", "bits": [11]}
      },
      "cells": {
        "inverter": {
          "type": "$_NOT_",
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [10],
            "Y": [11]
          }
        }
      },
      "netnames": {
        "a": {"bits": [10]},
        "y": {"bits": [11]}
      }
    }
  }
}
''';

const _nestedSameNameNetlist = r'''
{
  "modules": {
    "Top": {
      "attributes": {"top": 1},
      "ports": {
        "input": {"direction": "input", "bits": [1]},
        "output": {"direction": "output", "bits": [2]}
      },
      "cells": {
        "u1": {
          "type": "Child",
          "port_directions": {
            "a": "input",
            "y": "output"
          },
          "connections": {
            "a": [1],
            "y": [2]
          }
        }
      },
      "netnames": {
        "mid": {"bits": [1]},
        "output": {"bits": [2]}
      }
    },
    "Child": {
      "ports": {
        "a": {"direction": "input", "bits": [10]},
        "y": {"direction": "output", "bits": [11]}
      },
      "cells": {
        "first": {
          "type": "$_NOT_",
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [10],
            "Y": [12]
          }
        },
        "second": {
          "type": "$_NOT_",
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [12],
            "Y": [11]
          }
        }
      },
      "netnames": {
        "a": {"bits": [10]},
        "mid": {"bits": [12]},
        "y": {"bits": [11]}
      }
    }
  }
}
''';

const _aliasNetlist = r'''
{
  "modules": {
    "Top": {
      "attributes": {"top": 1},
      "ports": {
        "input_alias": {"direction": "input", "bits": [1]},
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
        "first_alias": {"bits": [1]},
        "input_alias": {"bits": [1]},
        "later_alias": {"bits": [1]},
        "y": {"bits": [2]}
      }
    }
  }
}
''';

const _twoBitNetlist = r'''
{
  "modules": {
    "Top": {
      "attributes": {"top": 1},
      "ports": {
        "a": {"direction": "input", "bits": [1, 2]},
        "y": {"direction": "output", "bits": [3, 4]}
      },
      "cells": {
        "buffer": {
          "type": "$_BUF_",
          "port_directions": {
            "A": "input",
            "Y": "output"
          },
          "connections": {
            "A": [1, 2],
            "Y": [3, 4]
          }
        }
      },
      "netnames": {
        "a": {"bits": [1, 2]},
        "y": {"bits": [3, 4]}
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

  test('deduplicates opaque endpoints for multi-bit signals', () {
    final busConnectivity = NetlistSchematicConnectivity.fromJson(
      _twoBitNetlist,
    );
    final input = busConnectivity.hierarchy.root.signals.singleWhere(
      (signal) => signal.name == 'a',
    );
    final output = busConnectivity.hierarchy.root.signals.singleWhere(
      (signal) => signal.name == 'y',
    );

    final consumers = busConnectivity.fanout(input);
    final drivers = busConnectivity.fanin(output);

    expect(consumers, hasLength(1));
    expect(drivers, hasLength(1));
    expect(consumers.single.nodePath, endsWith('/buffer'));
    expect(drivers.single.nodePath, endsWith('/buffer'));
  });

  test('uses canonical endpoint paths with an external hierarchy', () {
    final externalHierarchy = BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'Top',
        definition: 'Top',
        signals: [
          SignalOccurrence(
            name: 'a',
            width: 1,
            direction: 'input',
            portIndex: 0,
          ),
          SignalOccurrence(
            name: 'y',
            width: 1,
            direction: 'output',
            portIndex: 1,
          ),
        ],
        children: [
          HierarchyOccurrence(
            name: 'inverter',
            definition: r'$_NOT_',
            isPrimitive: true,
          ),
        ],
      ),
    );
    final externalConnectivity = NetlistSchematicConnectivity.fromJson(
      _netlist,
      externalHierarchy: externalHierarchy,
    );
    final input = externalConnectivity.hierarchy.root.signals.singleWhere(
      (signal) => signal.name == 'a',
    );

    final endpoints = externalConnectivity.fanout(input);
    final inverterEndpoint = endpoints.singleWhere(
      (endpoint) => endpoint.nodePath == 'Top/inverter',
    );

    expect(inverterEndpoint.nodeAddress, isNotNull);
    expect(
      inverterEndpoint.nodeAddress,
      externalHierarchy.root.children.single.address,
    );
  });

  test('matches a child scope with an instance-named external root', () {
    final externalHierarchy = BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'dut',
        definition: 'Top',
        signals: [
          SignalOccurrence(
            name: 'top_a',
            width: 1,
            direction: 'input',
            portIndex: 0,
          ),
          SignalOccurrence(
            name: 'top_y',
            width: 1,
            direction: 'output',
            portIndex: 1,
          ),
        ],
        children: [
          HierarchyOccurrence(
            name: 'u1',
            definition: 'Child',
            signals: [
              SignalOccurrence(
                name: 'a',
                width: 1,
                direction: 'input',
                portIndex: 0,
              ),
              SignalOccurrence(
                name: 'y',
                width: 1,
                direction: 'output',
                portIndex: 1,
              ),
            ],
            children: [
              HierarchyOccurrence(
                name: 'inverter',
                definition: r'$_NOT_',
                isPrimitive: true,
              ),
            ],
          ),
        ],
      ),
    );
    final externalConnectivity = NetlistSchematicConnectivity.fromJson(
      _hierarchicalNetlist,
      externalHierarchy: externalHierarchy,
    );
    final childInput = externalConnectivity
        .hierarchy.root.children.single.signals
        .singleWhere((signal) => signal.name == 'a');

    final endpoints = externalConnectivity.fanout(childInput);
    final inverterEndpoint = endpoints.singleWhere(
      (endpoint) => endpoint.nodePath == 'dut/u1/inverter',
    );

    expect(inverterEndpoint.nodeAddress, isNotNull);
    expect(
      inverterEndpoint.nodeAddress,
      externalHierarchy.root.children.single.children.single.address,
    );
  });

  test('does not match a same-name signal in the parent scope', () {
    final externalHierarchy = BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'Top',
        definition: 'Top',
        signals: [
          SignalOccurrence(
            name: 'input',
            width: 1,
            direction: 'input',
            portIndex: 0,
          ),
          SignalOccurrence(
            name: 'output',
            width: 1,
            direction: 'output',
            portIndex: 1,
          ),
          SignalOccurrence(name: 'mid', width: 1),
        ],
        children: [
          HierarchyOccurrence(
            name: 'u1',
            definition: 'Child',
            signals: [
              SignalOccurrence(
                name: 'a',
                width: 1,
                direction: 'input',
                portIndex: 0,
              ),
              SignalOccurrence(
                name: 'y',
                width: 1,
                direction: 'output',
                portIndex: 1,
              ),
              SignalOccurrence(name: 'mid', width: 1),
            ],
            children: [
              HierarchyOccurrence(
                name: 'first',
                definition: r'$_NOT_',
                isPrimitive: true,
              ),
              HierarchyOccurrence(
                name: 'second',
                definition: r'$_NOT_',
                isPrimitive: true,
              ),
            ],
          ),
        ],
      ),
    );
    final externalConnectivity = NetlistSchematicConnectivity.fromJson(
      _nestedSameNameNetlist,
      externalHierarchy: externalHierarchy,
    );
    final childMid = externalConnectivity.hierarchy.root.children.single.signals
        .singleWhere((signal) => signal.name == 'mid');

    final drivers = externalConnectivity.fanin(childMid);
    final consumers = externalConnectivity.fanout(childMid);

    expect(
      drivers.map((endpoint) => endpoint.nodePath),
      orderedEquals(['Top/u1/first']),
    );
    expect(
      consumers.map((endpoint) => endpoint.nodePath),
      orderedEquals(['Top/u1/second']),
    );
  });

  test('resolves port and later netname aliases sharing a Yosys bit', () {
    final aliasConnectivity = NetlistSchematicConnectivity.fromJson(
      _aliasNetlist,
    );
    final signals = aliasConnectivity.hierarchy.root.signals;
    final aliases = [
      signals.singleWhere((signal) => signal.name == 'input_alias'),
      signals.singleWhere((signal) => signal.name == 'later_alias'),
    ];

    for (final alias in aliases) {
      expect(
        aliasConnectivity.fanin(alias).map((endpoint) => endpoint.nodePath),
        orderedEquals(['Top']),
      );
      expect(
        aliasConnectivity.fanout(alias).map((endpoint) => endpoint.nodePath),
        orderedEquals(['Top/inverter']),
      );
    }
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
