// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// layout_edge_test.dart
// Unit tests for LayoutHyperedge signal references and ELK serialization.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

// Test fixtures use dynamic maps to match ELK's untyped JSON structures.
// ignore_for_file: avoid_dynamic_calls

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_data.dart';

void main() {
  group('LayoutHyperedge', () {
    late SignalOccurrence testSignal;
    late LayoutHyperedge edge;

    setUp(() {
      testSignal = SignalOccurrence(name: 'test_signal', width: 8);

      edge = LayoutHyperedge(
        id: 'edge1',
        signal: testSignal,
        sources: [('nodeA', 0)],
        targets: [('nodeB', 0)],
      );
    });

    test('LayoutHyperedge stores signal reference correctly', () {
      expect(edge.signal, equals(testSignal));
      expect(edge.signal.name, equals('test_signal'));
    });

    test('LayoutHyperedge delegates name and width to SignalOccurrence', () {
      expect(edge.name, equals('test_signal'));
      expect(edge.width, equals(8));
    });

    test('LayoutHyperedge stores source and target references', () {
      expect(edge.sources.length, equals(1));
      expect(edge.sources[0], equals(('nodeA', 0)));
      expect(edge.targets.length, equals(1));
      expect(edge.targets[0], equals(('nodeB', 0)));
    });

    test('LayoutHyperedge.isOneToOne returns true for 1:1 connectivity', () {
      expect(edge.isOneToOne, isTrue);
    });

    test('LayoutHyperedge.isOneToOne returns false for N:M connectivity', () {
      final nToMEdge = LayoutHyperedge(
        id: 'edge2',
        signal: testSignal,
        sources: [('nodeA', 0), ('nodeC', 0)],
        targets: [('nodeB', 0)],
      );
      expect(nToMEdge.isOneToOne, isFalse);
      expect(nToMEdge.isNtoM, isTrue);
    });

    test('LayoutHyperedge supports multiple targets', () {
      final broadcastEdge = LayoutHyperedge(
        id: 'broadcast',
        signal: testSignal,
        sources: [('nodeA', 0)],
        targets: [('nodeB', 0), ('nodeC', 0), ('nodeD', 0)],
      );

      expect(broadcastEdge.sources.length, equals(1));
      expect(broadcastEdge.targets.length, equals(3));
      expect(broadcastEdge.isOneToOne, isFalse);
    });

    test('LayoutHyperedge.toElkEdges() converts 1:1 to single ELK edge', () {
      String resolver(String nodeId, int portIndex) => '${nodeId}_p$portIndex';

      final edges = edge.toElkEdges(resolver);

      expect(edges.length, equals(1));
      final json = edges.first;
      expect(json['id'], equals('edge1'));
      expect(json['source'], equals('nodeA'));
      expect(json['sourcePort'], equals('nodeA_p0'));
      expect(json['target'], equals('nodeB'));
      expect(json['targetPort'], equals('nodeB_p0'));
      expect(json['hwMeta']['name'], equals('test_signal'));
      expect(json['hwMeta']['signalWidth'], equals(8));
    });

    test('LayoutHyperedge.toElkEdges() excludes signalWidth if width is 1', () {
      final singleBitEdge = LayoutHyperedge(
        id: 'edge_1bit',
        signal: SignalOccurrence(name: 'single_bit', width: 1),
        sources: const [('nodeA', 0)],
        targets: const [('nodeB', 0)],
      );

      final json = singleBitEdge.toElkEdges((n, p) => '${n}_p$p').first;

      expect((json['hwMeta'] as Map).containsKey('signalWidth'), isFalse);
    });

    test('LayoutHyperedge.toElkEdges() produces cartesian product for N:M', () {
      final nToMEdge = LayoutHyperedge(
        id: 'nm1',
        signal: testSignal,
        sources: [('nodeA', 0), ('nodeA', 1)],
        targets: [('nodeB', 0)],
      );

      final edges = nToMEdge.toElkEdges((n, p) => '${n}_p$p');

      expect(edges.length, equals(2));
      expect(edges[0]['id'], equals('nm1_0'));
      expect(edges[1]['id'], equals('nm1_1'));
    });

    test('LayoutHyperedge signal is the single source of truth', () {
      expect(edge.name, equals(edge.signal.name));
      expect(edge.width, equals(edge.signal.width));

      final updatedEdge = LayoutHyperedge(
        id: edge.id,
        signal: SignalOccurrence(name: 'updated_name', width: 16),
        sources: edge.sources,
        targets: edge.targets,
      );

      expect(updatedEdge.name, equals('updated_name'));
      expect(updatedEdge.width, equals(16));
    });
  });
}
