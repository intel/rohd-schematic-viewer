// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_version_test.dart
// Tests for Yosys netlist creator and version validation.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';

void main() {
  Map<String, Object> netlist({String? creator, Object? version}) => {
        if (creator != null) 'creator': creator,
        if (version != null) 'version': version,
        'modules': <String, Object>{
          'top': <String, Object>{
            'attributes': <String, Object>{'top': 1},
            'ports': <String, Object>{},
            'cells': <String, Object>{},
            'netnames': <String, Object>{},
          },
        },
      };

  test('records a known ROHD schema version without gating rendering', () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode(
        netlist(
          creator: 'NetlistSynthesizer (rohd)',
          version: NetlistSchematicAdapter.latestKnownRohdNetlistVersion,
        ),
      ),
    );
    expect(
      adapter.netlistVersion,
      equals(NetlistSchematicAdapter.latestKnownRohdNetlistVersion),
    );
    expect(
      adapter.isRohdNetlistVersion(
        NetlistSchematicAdapter.latestKnownRohdNetlistVersion,
      ),
      isTrue,
    );
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });

  test('accepts ROHD netlists without a schema version', () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode(netlist(creator: 'NetlistSynthesizer (rohd)')),
    );
    expect(adapter.netlistVersion, isNull);
    expect(
      adapter.isRohdNetlistVersion(
        NetlistSchematicAdapter.latestKnownRohdNetlistVersion,
      ),
      isFalse,
    );
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });

  test('accepts unrecognized ROHD netlist schema versions', () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode(
        netlist(creator: 'NetlistSynthesizer (rohd)', version: '999.0.0'),
      ),
    );
    expect(adapter.netlistVersion, equals('999.0.0'));
    expect(
      adapter.isRohdNetlistVersion(
        NetlistSchematicAdapter.latestKnownRohdNetlistVersion,
      ),
      isFalse,
    );
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });

  test('accepts unbranded Yosys-compatible netlists without a version', () {
    final adapter = NetlistSchematicAdapter.fromJson(jsonEncode(netlist()));
    expect(adapter.netlistCreator, isNull);
    expect(adapter.netlistVersion, isNull);
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });

  test('accepts scalar non-string version metadata', () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode(
        netlist(creator: 'NetlistSynthesizer (rohd)', version: 2),
      ),
    );
    expect(adapter.netlistVersion, equals('2'));
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });

  test('ignores structured version metadata without blocking rendering', () {
    final adapter = NetlistSchematicAdapter.fromJson(
      jsonEncode(
        netlist(
          creator: 'NetlistSynthesizer (rohd)',
          version: <String, Object>{'major': 2},
        ),
      ),
    );
    expect(adapter.netlistVersion, isNull);
    expect(adapter.schematic.nodeMap, isNotEmpty);
  });
}
