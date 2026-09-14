// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// operator_shapes_test.dart
// Contract tests for every registered schematic operator shape.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/operator_shapes.dart';

void main() {
  setUp(OperatorShapes.clearPathCache);

  test('every registered operator produces a finite non-empty path', () {
    for (final MapEntry(key: name, value: shapeInfo)
        in OperatorShapes.shapes.entries) {
      final path = OperatorShapes.getPathForOperator(name);
      final bounds = path!.getBounds();

      expect(bounds.isFinite, isTrue, reason: name);
      expect(bounds.width, greaterThan(0), reason: name);
      expect(bounds.height, greaterThan(0), reason: name);
      expect(OperatorShapes.getSizeForOperator(name), shapeInfo.$2,
          reason: name);
    }
  });

  test('path and stroke caches reuse paths until cleared', () {
    final firstPath = OperatorShapes.getPathForOperator('NAND');
    expect(OperatorShapes.getPathForOperator('NAND'), same(firstPath));

    final firstStroke = OperatorShapes.getStrokeOnlyPathForOperator('XOR');
    expect(
      OperatorShapes.getStrokeOnlyPathForOperator('XOR'),
      same(firstStroke),
    );
    expect(OperatorShapes.getStrokeOnlyPathForOperator('NXOR'), isNotNull);

    OperatorShapes.clearPathCache();
    expect(
      OperatorShapes.getPathForOperator('NAND'),
      isNot(same(firstPath)),
    );
  });

  test('unknown operators use safe lookup defaults', () {
    expect(
      OperatorShapes.getSizeForOperator('UNKNOWN'),
      OperatorShapes.defaultNodeSize,
    );
    expect(OperatorShapes.getPathForOperator('UNKNOWN'), isNull);
    expect(OperatorShapes.getStrokeOnlyPathForOperator('UNKNOWN'), isNull);
    expect(OperatorShapes.getTextForOperator('UNKNOWN'), isNull);
    expect(OperatorShapes.getTextOffsetForOperator('UNKNOWN'), isNull);
    expect(OperatorShapes.getAdditionalTextForOperator('UNKNOWN'), isNull);
  });

  test('flip-flop variants expose matching sizes without port labels', () {
    const cases = <String, Size>{
      'FF_clk0': OperatorShapes.ffNodeSize,
      'FF_EN_clk1_en0': OperatorShapes.ffSingleCtrlNodeSize,
      'FF_SRST_clk0_rst1': OperatorShapes.ffSingleCtrlNodeSize,
      'FF_ARST_clk1_rst0': OperatorShapes.ffArstNodeSize,
      'FF_SRST_EN_clk0_rst1_en0': OperatorShapes.ffDualCtrlNodeSize,
      'FF_ARST_EN_clk1_rst0_en1': OperatorShapes.ffDualCtrlNodeSize,
    };

    for (final MapEntry(key: name, value: size) in cases.entries) {
      expect(OperatorShapes.shapes[name]?.$2, size, reason: name);
      expect(OperatorShapes.getTextForOperator(name), 'FF', reason: name);
      expect(OperatorShapes.getTextOffsetForOperator(name), isNotNull,
          reason: name);
    }

    expect(
      OperatorShapes.getAdditionalTextForOperator('FF_EN_clk1_en0'),
      isNull,
    );
    expect(
      OperatorShapes.getAdditionalTextForOperator(
        'FF_SRST_EN_clk0_rst1_en0',
      ),
      isNull,
    );
    expect(
      OperatorShapes.getAdditionalTextForOperator(
        'FF_ARST_EN_clk1_rst0_en1',
      ),
      isNull,
    );
    expect(
      OperatorShapes.getAdditionalTextForOperator('DLATCH_en0')!
          .map((label) => label.$1),
      ['en'],
    );
  });

  test('concat and slice sizing covers input and output fanout', () {
    final slice = OperatorShapes.getConcatSliceSize(1, 1);
    final concat = OperatorShapes.getConcatSliceSize(3, 1, isConcat: true);
    final unpack = OperatorShapes.getConcatSliceSize(
      1,
      4,
      isMultiOutput: true,
    );
    final labelled = OperatorShapes.getConcatSliceSize(
      1,
      1,
      maxWestLabelWidth: 60,
      maxEastLabelWidth: 80,
    );

    expect(concat.height, 3 * slice.height);
    expect(unpack.height, 4 * slice.height);
    expect(labelled.width, greaterThan(slice.width));
    expect(OperatorShapes.isConcatSlice('CONCAT'), isTrue);
    expect(OperatorShapes.isConcatSlice('SLICE'), isTrue);
    expect(OperatorShapes.isConcatSlice('STRUCT_PACK'), isTrue);
    expect(OperatorShapes.isConcatSlice('STRUCT_UNPACK'), isTrue);
    expect(OperatorShapes.isConcatSlice('AND'), isFalse);
  });
}
