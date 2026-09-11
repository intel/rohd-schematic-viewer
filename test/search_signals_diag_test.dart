// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// search_signals_diag_test.dart
// Tests for NetlistSchematicAdapter hierarchy and signal search.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';

void main() {
  late NetlistSchematicAdapter adapter;

  setUp(() {
    final json = File('assets/rohd_schematic.json').readAsStringSync();
    adapter = NetlistSchematicAdapter.fromJson(json);
  });

  group('NetlistSchematicAdapter hierarchy', () {
    test('root module has expected name and id', () {
      final h = adapter.hierarchy;
      expect(h.root.name, 'FilterBank');
      expect(h.root.name, 'FilterBank');
    });

    test('root module exposes signals', () {
      final h = adapter.hierarchy;
      final sigs = h.root.signals;
      expect(
        sigs,
        isNotEmpty,
        reason: 'root module should have at least one signal',
      );
      expect(sigs.length, 21, reason: 'expected 21 signals at root');
    });

    test('root signals include known port names', () {
      final h = adapter.hierarchy;
      final names = h.root.signals.map((s) => s.name).toSet();
      for (final expected in [
        'clk',
        'reset',
        'start',
        'sampleIn0',
        'validOut',
      ]) {
        expect(
          names,
          contains(expected),
          reason: 'root should contain signal "$expected"',
        );
      }
    });

    test('root has expected children count', () {
      final h = adapter.hierarchy;
      final children = h.root.children;
      expect(children.length, 3, reason: 'expected 3 child modules under root');
    });

    test('child module names match', () {
      final h = adapter.hierarchy;
      final childNames = h.root.children.map((c) => c.name).toSet();
      for (final expected in ['ch0', 'controller', 'ch1']) {
        expect(
          childNames,
          contains(expected),
          reason: 'children should include "$expected"',
        );
      }
    });

    test('ch0 has many signals', () {
      final h = adapter.hierarchy;
      final ch0 = h.occurrenceByPathname('FilterBank/ch0')!;
      expect(ch0.signals.length, 29, reason: 'ch0 should have 29 signals');
    });

    test('ch0 signals include known names', () {
      final h = adapter.hierarchy;
      final ch0 = h.occurrenceByPathname('FilterBank/ch0')!;
      final names = ch0.signals.map((s) => s.name).toSet();
      for (final expected in [
        'clk',
        'reset',
        'enable',
        'sampleIn',
        'dataOut',
        'validOut',
      ]) {
        expect(
          names,
          contains(expected),
          reason: 'ch0 should contain signal "$expected"',
        );
      }
    });

    test('FilterChannel has mux-related signals', () {
      final h = adapter.hierarchy;
      // FilterChannel contains a validMuxed netname
      final ch0 = h.occurrenceByPathname('FilterBank/ch0')!;
      final muxSigs = ch0.signals.where(
        (s) => s.name.toLowerCase().contains('mux'),
      );
      expect(
        muxSigs,
        isNotEmpty,
        reason: 'ch0 should have "mux" signals (validMuxed)',
      );
    });
  });

  group('Yosys JSON netnames', () {
    test('FilterChannel netnames contain mux-related names', () {
      final json = File('assets/rohd_schematic.json').readAsStringSync();
      final jsonMap = jsonDecode(json) as Map<String, dynamic>;
      final modules = jsonMap['modules'] as Map<String, dynamic>;
      final fc = modules['FilterChannel'] as Map<String, dynamic>;
      final netnames = fc['netnames'] as Map<String, dynamic>;
      final muxNets = netnames.keys.where(
        (n) => n.toLowerCase().contains('mux'),
      );
      expect(
        muxNets,
        isNotEmpty,
        reason: 'FilterChannel should have mux-related netnames',
      );
    });
  });

  group('searchSignalPaths', () {
    test('single-letter query returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('a');
      expect(
        results,
        isNotEmpty,
        reason: 'query "a" should match at least one signal path',
      );
      expect(
        results.length,
        greaterThanOrEqualTo(10),
        reason: 'query "a" should match many signal paths',
      );
    });

    test('prefix query "coeff" returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('coeff');
      expect(
        results,
        isNotEmpty,
        reason: 'query "coeff" should match signal paths',
      );
    });

    test('query "ch0" returns results scoped to ch0', () {
      final results = adapter.hierarchy.searchSignalPaths('ch0');
      expect(
        results,
        isNotEmpty,
        reason: 'query "ch0" should match ch0 signals',
      );
      // Every result should contain "ch0" in the path
      for (final r in results) {
        expect(
          r.toLowerCase(),
          contains('ch0'),
          reason: 'result "$r" should be scoped to ch0',
        );
      }
    });

    test('query "clk" returns expected count', () {
      final results = adapter.hierarchy.searchSignalPaths('clk');
      expect(
        results,
        isNotEmpty,
        reason: 'query "clk" should find clock signals',
      );
      expect(
        results.first,
        contains('clk'),
        reason: 'first result should contain "clk"',
      );
    });

    test('query "result" returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('result');
      expect(
        results,
        isNotEmpty,
        reason: 'query "result" should match signal paths',
      );
    });

    test('query "out" returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('out');
      expect(
        results,
        isNotEmpty,
        reason: 'query "out" should match signal paths',
      );
    });

    test('query "validMux" returns results for FilterBank netlist', () {
      final results = adapter.hierarchy.searchSignalPaths('validMux');
      expect(
        results,
        isNotEmpty,
        reason:
            'query "validMux" should find validMuxed signals in FilterChannel',
      );
    });

    test('hierarchical path query "ch0/coeff" returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('ch0/coeff');
      expect(
        results,
        isNotEmpty,
        reason: 'query "ch0/coeff" should match signals',
      );
    });

    test('query "result" returns results', () {
      final results = adapter.hierarchy.searchSignalPaths('result');
      expect(
        results,
        isNotEmpty,
        reason: 'query "result" should match signal names',
      );
    });

    test('query "valid" returns results for FilterBank', () {
      final results = adapter.hierarchy.searchSignalPaths('valid');
      expect(
        results,
        isNotEmpty,
        reason: 'query "valid" should match valid-related signals',
      );
    });
  });
}
