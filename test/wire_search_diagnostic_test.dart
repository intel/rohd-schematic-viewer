// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// wire_search_diagnostic_test.dart
// Diagnostic test for wire search functionality.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';

void main() {
  group('Wire Search Diagnostic', () {
    late String schematicJson;
    late NetlistHierarchyAdapter hierarchy;

    setUpAll(() {
      schematicJson = File('assets/rohd_schematic.json').readAsStringSync();
      hierarchy = NetlistHierarchyAdapter.fromJson(schematicJson);
    });

    test('hierarchy is built correctly', () {
      final rootChildren = hierarchy.root.children;
      expect(
        rootChildren,
        isNotEmpty,
        reason: 'Root module should contain child instances',
      );
    });

    test('searchSignalPaths returns results for port name', () {
      // Search for 'clk' which is a top-level port
      final results = hierarchy.searchSignalPaths('clk');
      expect(
        results,
        isNotEmpty,
        reason: 'Hierarchy search should find top-level port "clk"',
      );
    });

    test('searchSignalPaths returns results for out', () {
      final results = hierarchy.searchSignalPaths('out');
      expect(
        results,
        isNotEmpty,
        reason: 'Hierarchy search should find signals matching "out"',
      );
    });

    test('searchSignalPaths returns results for clk', () {
      final results = hierarchy.searchSignalPaths('clk');
      expect(
        results,
        isNotEmpty,
        reason: 'Hierarchy search should find clock signals',
      );
    });

    test('searchSignalPaths returns results for hierarchical path', () {
      final results = hierarchy.searchSignalPaths('FilterBank');
      expect(
        results,
        isNotEmpty,
        reason: 'Hierarchy search should return paths for the top module',
      );
    });

    test('autocompletePaths for partial query', () {
      final suggestions = hierarchy.autocompletePaths('Filter');
      expect(
        suggestions,
        isNotEmpty,
        reason: 'Autocomplete should suggest matching hierarchical paths',
      );
    });

    test('signals for top module', () {
      final signals = hierarchy.root.signals;
      expect(
        signals,
        isNotEmpty,
        reason: 'Top module should expose signals for search',
      );
    });
  });

  group('Dart Parser (NetlistSchematicAdapter) Wire Search', () {
    late String schematicJson;
    late NetlistSchematicAdapter adapter;

    setUpAll(() {
      schematicJson = File('assets/rohd_schematic.json').readAsStringSync();
      adapter = NetlistSchematicAdapter.fromJson(schematicJson);
    });

    test('hierarchy is built correctly', () {
      final hierarchy = adapter.hierarchy;
      final rootChildren = hierarchy.root.children;
      expect(
        rootChildren,
        isNotEmpty,
        reason: 'Dart parser hierarchy should expose children for root',
      );
    });

    test('searchSignalPaths returns results for port name', () {
      final results = adapter.hierarchy.searchSignalPaths('a');
      expect(
        results,
        isNotEmpty,
        reason: 'Dart parser should find signals matching "a"',
      );
    });

    test('searchSignalPaths returns results for hierarchical signal path', () {
      // 'ch0' is a cell instance with a 'dataOut' port; use '/' separator
      // to form a hierarchical query that matches the registered path
      // FilterBank/ch0/dataOut.
      final results = adapter.hierarchy.searchSignalPaths('ch0/dataOut');
      expect(
        results,
        isNotEmpty,
        reason: 'Dart parser should find signals via hierarchical path '
            'ch0/dataOut',
      );
    });

    test('searchSignalPaths returns results for clk', () {
      final results = adapter.hierarchy.searchSignalPaths('clk');
      expect(
        results.length >= 2,
        isTrue,
        reason: 'Should find at least clk signals in ch0 and ch1',
      );
    });

    test('signals count should include netnames', () {
      // Get signals for top module
      final signals = adapter.hierarchy.root.signals;
      // Should have more than just the 12 ports
      expect(
        signals.length > 12,
        isTrue,
        reason: 'Should have netnames in addition to ports',
      );
    });
  });
}
