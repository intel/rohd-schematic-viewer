// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// elk_layout_extractor_test.dart
// Tests for ELK layout extractor.
//
// 2026 April
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';

void main() {
  group('ElkLayoutExtractor', () {
    test('extracts flat layout from simple ELK result', () {
      // Minimal ELK result with one child node, two ports, one edge
      final elkResult = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 400,
        'height': 300,
        'children': [
          <String, dynamic>{
            'id': 'n1',
            'x': 10,
            'y': 20,
            'width': 100,
            'height': 50,
            'hwMeta': <String, dynamic>{
              'name': 'adder',
              'cls': 'Module',
              'bodyText': '',
            },
            'ports': [
              <String, dynamic>{
                'id': 'p1',
                'x': 0,
                'y': 10,
                'width': 7,
                'height': 13,
                'hwMeta': <String, dynamic>{'name': 'A'},
                'direction': 'INPUT',
                'properties': <String, dynamic>{'side': 'WEST'},
              },
              <String, dynamic>{
                'id': 'p2',
                'x': 100,
                'y': 10,
                'width': 7,
                'height': 13,
                'hwMeta': <String, dynamic>{'name': 'Y'},
                'direction': 'OUTPUT',
                'properties': <String, dynamic>{'side': 'EAST'},
              },
            ],
          },
        ],
        'edges': [
          <String, dynamic>{
            'id': 'e1',
            'source': 'n1',
            'sourcePort': 'p2',
            'target': 'n1',
            'targetPort': 'p1',
            'hwMeta': <String, dynamic>{'name': 'wire0', 'signalWidth': 8},
            'sections': [
              <String, dynamic>{
                'startPoint': <String, dynamic>{'x': 110, 'y': 30},
                'endPoint': <String, dynamic>{'x': 10, 'y': 30},
                'bendPoints': [
                  <String, dynamic>{'x': 120, 'y': 30},
                  <String, dynamic>{'x': 120, 'y': 60},
                  <String, dynamic>{'x': 5, 'y': 60},
                  <String, dynamic>{'x': 5, 'y': 30},
                ],
              },
            ],
          },
        ],
      };

      final result = ElkLayoutExtractor.extract(elkResult);

      expect(result.instances, hasLength(1));
      expect(result.instances.first.id, equals('n1'));
      expect(result.instances.first.name, equals('adder'));
      expect(result.instances.first.cls, equals('Module'));

      expect(result.ports, hasLength(2));
      expect(
        result.ports.map((p) => p.name).toList()..sort(),
        equals(['A', 'Y']),
      );

      expect(result.edges, hasLength(1));
      expect(result.edges.first.name, equals('wire0'));
      expect(result.edges.first.signalWidth, equals(8));
      // start + 4 bends + end = 6 points
      expect(result.edges.first.points, hasLength(6));

      expect(result.width, equals(400));
      expect(result.height, equals(300));
    });

    test('converts relative to absolute coordinates', () {
      // Root at (10, 20) with child at (5, 5) relative
      // After conversion, child should be at (10+5, 20+5) = (15, 25)
      final elk = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 200,
        'height': 200,
        'padding': <String, dynamic>{
          'left': 10,
          'top': 20,
          'right': 10,
          'bottom': 10,
        },
        'children': [
          <String, dynamic>{
            'id': 'c1',
            'x': 5,
            'y': 5,
            'width': 50,
            'height': 30,
            'hwMeta': <String, dynamic>{'name': 'child1', 'cls': ''},
            'ports': [
              <String, dynamic>{
                'id': 'cp1',
                'x': 0,
                'y': 5,
                'width': 7,
                'height': 13,
                'hwMeta': <String, dynamic>{'name': 'in'},
                'properties': <String, dynamic>{'side': 'WEST'},
              },
            ],
          },
        ],
      };

      ElkLayoutExtractor.convertToAbsoluteCoordinates(elk, 0, 0);

      final child = (elk['children'] as List).first as Map<String, dynamic>;
      // child.x = 5 + 0 (parent) + 10 (padding.left) = 15
      expect(child['x'], equals(15));
      // child.y = 5 + 0 (parent) + 20 (padding.top) = 25
      expect(child['y'], equals(25));

      // Port absolute = child absolute + port relative
      final port = (child['ports'] as List).first as Map<String, dynamic>;
      expect(port['x'], equals(15)); // 0 + 15
      expect(port['y'], equals(30)); // 5 + 25
    });

    test('root offset is subtracted from extracted positions', () {
      final elk = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 300,
        'height': 200,
        'children': [
          <String, dynamic>{
            'id': 'a',
            'x': 50,
            'y': 60,
            'width': 80,
            'height': 40,
            'hwMeta': <String, dynamic>{'name': 'alpha', 'cls': ''},
          },
        ],
      };

      final result = ElkLayoutExtractor.extract(elk);
      final inst = result.instances.first;
      // Root is at (0,0) so root offset = (0,0). After absolute conversion
      // child is at (50,60). Viewport offset subtracted = (50-0, 60-0).
      expect(inst.x, equals(50));
      expect(inst.y, equals(60));
    });

    test('handles hasChildren and isExpanded flags', () {
      final elk = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 300,
        'height': 200,
        'children': [
          <String, dynamic>{
            'id': 'expanded_node',
            'x': 10,
            'y': 10,
            'width': 100,
            'height': 100,
            'hwMeta': <String, dynamic>{'name': 'exp', 'cls': ''},
            'children': [
              <String, dynamic>{
                'id': 'inner',
                'x': 5,
                'y': 5,
                'width': 30,
                'height': 20,
                'hwMeta': <String, dynamic>{'name': 'inner', 'cls': ''},
              },
            ],
          },
          <String, dynamic>{
            'id': 'collapsed_node',
            'x': 150,
            'y': 10,
            'width': 80,
            'height': 40,
            'hwMeta': <String, dynamic>{'name': 'col', 'cls': ''},
            '_children': [
              <String, dynamic>{
                'id': 'hidden',
                'x': 0,
                'y': 0,
                'width': 20,
                'height': 20,
                'hwMeta': <String, dynamic>{'name': 'hidden', 'cls': ''},
              },
            ],
          },
          <String, dynamic>{
            'id': 'leaf',
            'x': 10,
            'y': 120,
            'width': 40,
            'height': 30,
            'hwMeta': <String, dynamic>{'name': 'leaf', 'cls': ''},
          },
        ],
      };

      final result = ElkLayoutExtractor.extract(elk);
      final byId = {for (final i in result.instances) i.id: i};

      expect(byId['expanded_node']!.hasChildren, isTrue);
      expect(byId['expanded_node']!.isExpanded, isTrue);
      expect(byId['expanded_node']!.children, contains('inner'));

      expect(byId['collapsed_node']!.hasChildren, isTrue);
      expect(byId['collapsed_node']!.isExpanded, isFalse);

      expect(byId['leaf']!.hasChildren, isFalse);
      expect(byId['leaf']!.isExpanded, isFalse);
    });

    test('handles edge with primitive format', () {
      final elk = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 200,
        'height': 200,
        'children': [
          <String, dynamic>{
            'id': 'n1',
            'x': 10,
            'y': 10,
            'width': 50,
            'height': 30,
            'hwMeta': <String, dynamic>{'name': 'n1', 'cls': ''},
          },
        ],
        'edges': [
          <String, dynamic>{
            'id': 'e1',
            'sources': ['src'],
            'targets': ['tgt'],
            'sourcePoint': <String, dynamic>{'x': 10, 'y': 20},
            'targetPoint': <String, dynamic>{'x': 100, 'y': 20},
            'bendPoints': [
              <String, dynamic>{'x': 50, 'y': 20},
            ],
            'hwMeta': <String, dynamic>{'name': 'w', 'signalWidth': 1},
          },
        ],
      };

      final result = ElkLayoutExtractor.extract(elk);
      expect(result.edges, hasLength(1));
      expect(result.edges.first.points, hasLength(3));
      expect(result.edges.first.source, equals('src'));
      expect(result.edges.first.target, equals('tgt'));
    });

    test('produces empty result for empty graph', () {
      final elk = <String, dynamic>{
        'id': 'root',
        'x': 0,
        'y': 0,
        'width': 800,
        'height': 600,
      };

      final result = ElkLayoutExtractor.extract(elk);
      expect(result.instances, isEmpty);
      expect(result.ports, isEmpty);
      expect(result.edges, isEmpty);
      expect(result.width, equals(800));
      expect(result.height, equals(600));
    });
  });
}
