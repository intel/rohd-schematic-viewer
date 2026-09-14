// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// operator_shapes.dart
// Library of operator shapes for rendering schematic symbols.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:math' as math;
import 'dart:ui';

/// Library of operator shapes for rendering schematic symbols.
/// These shapes define the operator symbols used by the Flutter renderer.
///
/// All shapes return Path objects that can be drawn with Canvas.drawPath().
/// Shapes are designed to scale smoothly at any zoom level.
class OperatorShapes {
  /// Default node size for most operators [width, height]
  static const defaultNodeSize = Size(25, 25);

  /// Size for FF (simple flip-flop) operators [width, height]
  static const ffNodeSize = Size(25, 40);

  /// Size for MUX operators [width, height]
  static const muxNodeSize = Size(20, 40);

  /// Size for FF_ARST operators [width, height]
  static const ffArstNodeSize = Size(40, 50);

  /// Size for FF operators with a single extra control pin (enable-only
  /// `$dffe`, or sync-reset-only `$sdff`) [width, height]
  static const ffSingleCtrlNodeSize = Size(40, 50);

  /// Size for FF operators with both a reset and an enable pin
  /// (`$sdffe`, `$adffe`) [width, height]
  static const ffDualCtrlNodeSize = Size(40, 60);

  /// Size for DLATCH operators [width, height]
  static const dlatchNodeSize = Size(50, 25);

  /// Size for SHIFT operators [width, height]
  static const shiftNodeSize = Size(50, 50);

  /// Width of the vertical bar for CONCAT/SLICE operators
  static const concatSliceBarWidth = 2.0;

  /// Vertical spacing per port for CONCAT/SLICE
  static const concatSlicePortSpacing = 15.0;

  /// Minimum height for CONCAT/SLICE bar
  static const concatSliceMinHeight = 15.0;

  /// Map of operator names to their shape constructors and sizes
  static final Map<String, (Path Function(), Size)> shapes = {
    'BUF': (drawBuf, defaultNodeSize),
    'TRIBUF': (drawTriBuf, defaultNodeSize),
    'NOT': (drawNot, defaultNodeSize),
    'AND': (drawAnd, defaultNodeSize),
    'NAND': (drawNand, defaultNodeSize),
    'OR': (drawOr, defaultNodeSize),
    'NOR': (drawNor, defaultNodeSize),
    'XOR': (drawXor, defaultNodeSize),
    'NXOR': (drawNxor, defaultNodeSize),
    'RISING_EDGE': (drawRisingEdge, defaultNodeSize),
    'FALLING_EDGE': (drawFallingEdge, defaultNodeSize),
    'ADD': (() => drawCircleWithText('+'), defaultNodeSize),
    'SUB': (() => drawCircleWithText('-'), defaultNodeSize),
    'EQ': (() => drawCircleWithText('='), defaultNodeSize),
    'NE': (() => drawCircleWithText('!='), defaultNodeSize),
    'LT': (() => drawCircleWithText('<'), defaultNodeSize),
    'LE': (() => drawCircleWithText('<='), defaultNodeSize),
    'GE': (() => drawCircleWithText('>='), defaultNodeSize),
    'GT': (() => drawCircleWithText('>'), defaultNodeSize),
    'SHL': (() => drawCircleWithText('<<'), defaultNodeSize),
    'SHR': (() => drawCircleWithText('>>'), defaultNodeSize),
    'SHIFT': (() => drawBiggerCircleWithText('<<,>>'), shiftNodeSize),
    'MUL': (() => drawCircleWithText('*'), defaultNodeSize),
    'DIV': (() => drawCircleWithText('/'), defaultNodeSize),
    'MOD': (() => drawCircleWithText('%'), defaultNodeSize),
    'FF': (drawFF, ffNodeSize),
    'FF_ARST_clk0_rst0': (
      () => drawFFArst(clkPolarity: false, arstPolarity: false),
      ffArstNodeSize,
    ),
    'FF_ARST_clk1_rst1': (
      () => drawFFArst(clkPolarity: true, arstPolarity: true),
      ffArstNodeSize,
    ),
    'FF_ARST_clk0_rst1': (
      () => drawFFArst(clkPolarity: true, arstPolarity: false),
      ffArstNodeSize,
    ),
    'FF_ARST_clk1_rst0': (
      () => drawFFArst(clkPolarity: false, arstPolarity: true),
      ffArstNodeSize,
    ),
    // $dff: clock-polarity-only flip-flop (no reset/enable pins).
    for (final clk in [0, 1])
      'FF_clk$clk': (
        () => drawFFClk(clkPolarity: clk == 1),
        ffNodeSize,
      ),
    // $dffe: flip-flop with an enable pin.
    for (final clk in [0, 1])
      for (final en in [0, 1])
        'FF_EN_clk${clk}_en$en': (
          () => drawFFEn(clkPolarity: clk == 1, enPolarity: en == 1),
          ffSingleCtrlNodeSize,
        ),
    // $sdff: flip-flop with a synchronous reset pin (same shape as
    // FF_ARST; only the text label differs between sync/async reset).
    for (final clk in [0, 1])
      for (final rst in [0, 1])
        'FF_SRST_clk${clk}_rst$rst': (
          () => drawFFArst(clkPolarity: clk == 1, arstPolarity: rst == 1),
          ffSingleCtrlNodeSize,
        ),
    // $sdffe: flip-flop with a synchronous reset pin and an enable pin.
    for (final clk in [0, 1])
      for (final rst in [0, 1])
        for (final en in [0, 1])
          'FF_SRST_EN_clk${clk}_rst${rst}_en$en': (
            () => drawFFRstEn(
                  clkPolarity: clk == 1,
                  rstPolarity: rst == 1,
                  enPolarity: en == 1,
                ),
            ffDualCtrlNodeSize,
          ),
    // $adffe: flip-flop with an asynchronous reset pin and an enable pin.
    for (final clk in [0, 1])
      for (final rst in [0, 1])
        for (final en in [0, 1])
          'FF_ARST_EN_clk${clk}_rst${rst}_en$en': (
            () => drawFFRstEn(
                  clkPolarity: clk == 1,
                  rstPolarity: rst == 1,
                  enPolarity: en == 1,
                ),
            ffDualCtrlNodeSize,
          ),
    'DLATCH_en0': (() => drawDLatch(enPolarity: false), dlatchNodeSize),
    'DLATCH_en1': (() => drawDLatch(enPolarity: true), dlatchNodeSize),
    'MUX': (drawMux, muxNodeSize),
    'LATCHED_MUX': (drawLatchedMux, muxNodeSize),
    // SLICE and CONCAT use dynamic sizing; these are placeholder
    // defaults. Actual sizes from getConcatSliceSize() based on port count.
    'SLICE': (
      () => drawConcatSliceBar(concatSliceBarWidth, 20),
      const Size(5, 20),
    ),
    'CONCAT': (
      () => drawConcatSliceBar(concatSliceBarWidth, 20),
      const Size(5, 20),
    ),
  };

  /// Draw a negation circle (used by NOT, NAND, NOR, NXOR)
  static Path drawNegationCircle(double x, double y) =>
      Path()..addOval(Rect.fromCircle(center: Offset(x, y), radius: 3));

  /// Draw a basic circle (used by arithmetic operators)
  static Path drawCircle() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12.5, 12.5), radius: 12.5));

  /// Draw a bigger circle (used by SHIFT operator)
  static Path drawBiggerCircle() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(25, 25), radius: 25));

  /// Draw a circle with text label (for arithmetic and comparison operators)
  /// Note: This returns the path for the circle only. Text must be drawn
  /// separately.
  static Path drawCircleWithText(String text) => drawCircle();

  /// Draw a bigger circle with text label (for SHIFT operator) Note: This
  /// returns the path for the circle only. Text must be drawn separately.
  static Path drawBiggerCircleWithText(String text) => drawBiggerCircle();

  /// Draw an operator box (used by FF and edge detectors)
  static Path drawOperatorBox() =>
      Path()..addRect(const Rect.fromLTWH(0, 0, 25, 25));

  /// Draw an AND gate symbol SVG path: "M0,0 L0,25 L15,25 A15 12.5 0 0 0 15,0
  /// Z" Scaled by 0.8 and translated (0, 3)
  ///
  /// NOTE: Size provider architecture test (Jan 2026) Setting AND to a
  /// different size (e.g., Size(50, 50)) confirmed that:
  /// - Flutter can independently control operator sizes via OperatorShapes
  /// - The size provider callback sends dimensions to JavaScript
  /// - ELK layout engine uses Flutter-provided sizes
  /// - Flutter rendering and ELK layout stay synchronized.
  static Path drawAnd() {
    final path = Path()
      // Bake in scale(0.8) and translate(0, 3)
      // Original points:
      // M0,0 L0,25 L15,25 A15 12.5 0 0 0 15,0 Z
      // Scaled points:
      // M0,3 L0,23 L12,23 A12 10 0 0 0 12,3 Z
      ..moveTo(0, 3)
      ..lineTo(0, 23)
      ..lineTo(12, 23)
      ..arcToPoint(
        const Offset(12, 3),
        radius: const Radius.elliptical(12, 10),
        clockwise: false,
      )
      ..close();
    return path;
  }

  /// Draw a NAND gate symbol (AND gate with negation circle)
  static Path drawNand() {
    final path = drawAnd()..addPath(drawNegationCircle(34, 12.5), Offset.zero);
    return path;
  }

  /// Draw an OR gate symbol
  /// SVG path: "M3,0 A30 25 0 0 1 3,25 A30 25 0 0 0 33,12.5 A30 25 0 0 0 3,0 z"
  /// Scaled by 0.8 and translated (0, 3)
  static Path drawOr() {
    final path = Path()
      // Bake in scale(0.8) and translate(0, 3)
      // Original OR_SHAPE_PATH:
      // M3,0 A30 25 0 0 1 3,25 A30 25 0 0 0 33,12.5 A30 25 0 0 0 3,0 z
      // Scaled points and radii:
      // M2.4,3 A24 20 0 0 1 2.4,23 A24 20 0 0 0 26.4,13 A24 20 0 0 0 2.4,3 z
      ..moveTo(2.4, 3)
      ..arcToPoint(
        const Offset(2.4, 23),
        radius: const Radius.elliptical(24, 20),
      )
      ..arcToPoint(
        const Offset(26.4, 13),
        radius: const Radius.elliptical(24, 20),
        clockwise: false,
      )
      ..arcToPoint(
        const Offset(2.4, 3),
        radius: const Radius.elliptical(24, 20),
        clockwise: false,
      )
      ..close();
    return path;
  }

  /// Draw a NOR gate symbol (OR gate with negation circle)
  static Path drawNor() =>
      drawOr()..addPath(drawNegationCircle(34, 12.5), Offset.zero);

  /// Draw an XOR gate symbol (OR gate with extra arc)
  /// Note: The extra arc should be drawn separately with stroke-only
  /// Use getStrokeOnlyPathForOperator() to get the additional arc
  static Path drawXor() => drawOr();

  /// Draw an NXOR gate symbol (XOR gate with negation circle)
  static Path drawNxor() {
    final path = drawOr()..addPath(drawNegationCircle(35, 12.5), Offset.zero);
    return path;
  }

  /// Draw a buffer (BUF) gate symbol — isosceles triangle, no negation circle.
  /// 25×25 to fill the full default node width so both the input
  /// wire (x=0) and output wire (x=25) touch the shape.
  /// Path: "M0,0 L0,25 L25,12.5 Z"
  static Path drawBuf() {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 25)
      ..lineTo(25, 12.5)
      ..close();
    return path;
  }

  /// Draw a tri-state buffer — buffer triangle + enable diamond indicator.
  ///
  /// Same triangle as [drawBuf] with a small diamond on the bottom edge
  /// marking the enable port (SOUTH side).
  static Path drawTriBuf() {
    final path = Path()
      // Main triangle (same as BUF)
      ..moveTo(0, 0)
      ..lineTo(0, 25)
      ..lineTo(25, 12.5)
      ..close()
      // Enable diamond at the midpoint of the bottom edge
      ..moveTo(8.3, 20.8)
      ..lineTo(6, 18.5)
      ..lineTo(8.3, 16.2)
      ..lineTo(10.6, 18.5)
      ..close();
    return path;
  }

  /// Draw a NOT gate symbol
  /// SVG path: "M0,2.5 L0,22.5 L20,12.5 Z" plus negation circle
  static Path drawNot() {
    final path = Path()
      ..moveTo(0, 2.5)
      ..lineTo(0, 22.5)
      ..lineTo(20, 12.5)
      ..close()
      ..addPath(drawNegationCircle(23, 12.5), Offset.zero);
    return path;
  }

  /// Draw a flip-flop register symbol (25×40 box with clock triangle)
  static Path drawFF() {
    final path = Path()..addRect(const Rect.fromLTWH(0, 0, 25, 40));
    // Clock triangle centred vertically: midY = 20, span ±5
    final triangle = Path()
      ..moveTo(0, 15)
      ..lineTo(5, 20)
      ..lineTo(0, 25);
    path.addPath(triangle, Offset.zero);
    return path;
  }

  /// Draw a flip-flop with async reset symbol
  static Path drawFFArst({
    required bool arstPolarity,
    required bool clkPolarity,
  }) {
    final path = Path()
      // Rectangle 40x50
      ..addRect(const Rect.fromLTWH(0, 0, 40, 50));

    // Clock triangle: "M0,7.5 L6,12.5 L0,17.5 z"
    final triangle = Path()
      ..moveTo(0, 7.5)
      ..lineTo(6, 12.5)
      ..lineTo(0, 17.5)
      ..close();
    path.addPath(triangle, Offset.zero);

    // Clock polarity circle (if inverted)
    if (!clkPolarity) {
      path.addPath(drawNegationCircle(1, 12.5), Offset.zero);
    }

    // ARST polarity circle (if inverted)
    if (!arstPolarity) {
      path.addPath(drawNegationCircle(1, 25), Offset.zero);
    }

    return path;
  }

  /// Draw a D-latch symbol
  static Path drawDLatch({required bool enPolarity}) {
    final path = Path()
      // Rectangle 50x25
      ..addRect(const Rect.fromLTWH(0, 0, 50, 25));

    // Enable polarity circle (if inverted)
    if (!enPolarity) {
      path.addPath(drawNegationCircle(1, 16.5), Offset.zero);
    }

    return path;
  }

  /// Draw a flip-flop with clock polarity indicator (no reset/enable pins).
  ///
  /// Uses the standard [drawFF] shape and adds a negation circle on the
  /// clock input when [clkPolarity] is `false` (falling-edge triggered).
  static Path drawFFClk({required bool clkPolarity}) {
    final path = drawFF();
    if (!clkPolarity) {
      path.addPath(drawNegationCircle(1, 20), Offset.zero);
    }
    return path;
  }

  /// Draw a flip-flop with clock + enable pins.
  ///
  /// Reuses the [drawFFArst] envelope (40x50 rectangle with a clock triangle
  /// and a second control pin at the reset position) so the enable pin lines
  /// up with the existing wire routing. Polarity circles are added when
  /// [clkPolarity] or [enPolarity] is `false`.
  static Path drawFFEn({
    required bool clkPolarity,
    required bool enPolarity,
  }) =>
      drawFFArst(clkPolarity: clkPolarity, arstPolarity: enPolarity);

  /// Draw a flip-flop with clock + reset + enable pins.
  ///
  /// Extends the [drawFFArst] shape (rectangle + clock triangle + reset
  /// polarity) with an additional enable-pin negation circle when
  /// [enPolarity] is `false`.
  static Path drawFFRstEn({
    required bool clkPolarity,
    required bool rstPolarity,
    required bool enPolarity,
  }) {
    final path = Path()..addRect(const Rect.fromLTWH(0, 0, 40, 60));

    final triangle = Path()
      ..moveTo(0, 7.5)
      ..lineTo(6, 12.5)
      ..lineTo(0, 17.5)
      ..close();
    path.addPath(triangle, Offset.zero);

    if (!clkPolarity) {
      path.addPath(drawNegationCircle(1, 12.5), Offset.zero);
    }
    if (!rstPolarity) {
      path.addPath(drawNegationCircle(1, 30), Offset.zero);
    }
    if (!enPolarity) {
      path.addPath(drawNegationCircle(1, 47.5), Offset.zero);
    }

    return path;
  }

  /// Draw a rising edge detector symbol
  static Path drawRisingEdge() {
    final path = drawOperatorBox();
    // Add rising edge symbol: "M5,20 L12.5,20 L12.5,5 L20,5"
    final edge = Path()
      ..moveTo(5, 20)
      ..lineTo(12.5, 20)
      ..lineTo(12.5, 5)
      ..lineTo(20, 5);
    path.addPath(edge, Offset.zero);
    return path;
  }

  /// Draw a falling edge detector symbol
  static Path drawFallingEdge() {
    final path = drawOperatorBox();
    // Add falling edge symbol: "M5,5 L12.5,5 L12.5,20 L20,20"
    final edge = Path()
      ..moveTo(5, 5)
      ..lineTo(12.5, 5)
      ..lineTo(12.5, 20)
      ..lineTo(20, 20);
    path.addPath(edge, Offset.zero);
    return path;
  }

  /// Draw a multiplexer symbol
  /// SVG path: "M0,0 L20,10 L20,30 L0,40 Z"
  static Path drawMux() {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(20, 10)
      ..lineTo(20, 30)
      ..lineTo(0, 40)
      ..close();
    return path;
  }

  /// Draw a latched multiplexer symbol (MUX with "LA" label area)
  /// Note: The "LA" text must be drawn separately
  static Path drawLatchedMux() => drawMux();

  /// Get the size for a given operator name
  static Size getSizeForOperator(String operatorName) {
    final shapeInfo = shapes[operatorName];
    return shapeInfo?.$2 ?? defaultNodeSize;
  }

  /// Cached paths — lazily populated on first call per operator name.
  static final Map<String, Path> _pathCache = {};

  /// Get the path for a given operator name (cached after first call).
  static Path? getPathForOperator(String operatorName) {
    final cached = _pathCache[operatorName];
    if (cached != null) {
      return cached;
    }
    final shapeInfo = shapes[operatorName];
    if (shapeInfo == null) {
      return null;
    }
    final path = shapeInfo.$1();
    _pathCache[operatorName] = path;
    return path;
  }

  /// Clear the cached paths (call if shapes change dynamically).
  static void clearPathCache() => _pathCache.clear();

  /// Return the center of the **gate body** for text placement.
  ///
  /// For operators with an output negation bubble (NOT, NAND, NOR, NXOR)
  /// the full path bounds are wider than the visible body, which makes
  /// text appear off-center.  This method returns the centroid of just
  /// the body (triangle, D-shape, etc.), ignoring the bubble.
  ///
  /// Returns `null` when no special adjustment is needed (text can use
  /// `path.getBounds().center` as usual).
  static Offset? getBodyCenter(String operatorName) {
    switch (operatorName) {
      // NOT: triangle vertices (0,2.5), (0,22.5), (20,12.5)
      //   centroid x = (0+0+20)/3 ≈ 6.7, nudged right for visual balance
      case 'NOT':
        return const Offset(9, 12.5);

      // NAND: AND body runs from x=0..~24 (arc apex), y=3..23
      //   visual center ≈ (10, 13)
      case 'NAND':
        return const Offset(10, 13);

      // NOR / NXOR: OR body runs from x≈2.4..~26, y=3..23
      //   visual center ≈ (12, 13)
      case 'NOR':
      case 'NXOR':
        return const Offset(12, 13);

      default:
        return null;
    }
  }

  /// Get the text label for operators that display text
  /// Returns null for operators that don't have a text label
  static String? getTextForOperator(String operatorName) {
    if (operatorName.startsWith('FF_')) {
      return 'FF';
    }
    final textMap = {
      'AND': '^',
      'OR': 'v',
      'NOR': '!|',
      'XOR': '^',
      'NXOR': '!^',
      'NOT': '~',
      'FF': 'FF',
      'FF_ARST_clk0_rst0': 'ADFF',
      'FF_ARST_clk1_rst1': 'ADFF',
      'FF_ARST_clk0_rst1': 'ADFF',
      'FF_ARST_clk1_rst0': 'ADFF',
      'DLATCH_en0': 'DLATCH',
      'DLATCH_en1': 'DLATCH',
      'ADD': '+',
      'SUB': '-',
      'EQ': '=',
      'NE': '!=',
      'LT': '<',
      'LE': '<=',
      'GE': '>=',
      'GT': '>',
      'SHL': '<<',
      'SHR': '>>',
      'SHIFT': '<<,>>',
      'MUL': '*',
      'DIV': '/',
      'MOD': '%',
    };
    return textMap[operatorName];
  }

  /// Get the text position offset for operators that display text
  /// Returns the offset from the top-left corner of the shape
  static Offset? getTextOffsetForOperator(String operatorName) {
    if (operatorName.startsWith('FF_SRST_EN_') ||
        operatorName.startsWith('FF_ARST_EN_')) {
      return const Offset(20, 30);
    }
    if (operatorName.startsWith('FF_EN_') ||
        operatorName.startsWith('FF_SRST_') ||
        operatorName.startsWith('FF_ARST_')) {
      return const Offset(20, 25);
    }
    if (operatorName.startsWith('FF_clk')) {
      return const Offset(12.5, 20);
    }
    // Map of operator names to their text positions
    final offsetMap = {
      'AND': const Offset(12.5, 12.5),
      'OR': const Offset(12.5, 12.5),
      'NOR': const Offset(12.5, 12.5),
      'XOR': const Offset(12.5, 12.5),
      'NXOR': const Offset(12.5, 12.5),
      'NOT': const Offset(12.5, 12.5),
      'FF': const Offset(12.5, 20),
      'FF_ARST_clk0_rst0': const Offset(20, 25),
      'FF_ARST_clk1_rst1': const Offset(20, 25),
      'FF_ARST_clk0_rst1': const Offset(20, 25),
      'FF_ARST_clk1_rst0': const Offset(20, 25),
      'DLATCH_en0': const Offset(25, 12.5),
      'DLATCH_en1': const Offset(25, 12.5),
      // Arithmetic and comparison operators (centered in circle)
      'ADD': const Offset(12.5, 12.5),
      'SUB': const Offset(12.5, 12.5),
      'EQ': const Offset(12.5, 12.5),
      'NE': const Offset(12.5, 12.5),
      'LT': const Offset(12.5, 12.5),
      'LE': const Offset(12.5, 12.5),
      'GE': const Offset(12.5, 12.5),
      'GT': const Offset(12.5, 12.5),
      'SHL': const Offset(12.5, 12.5),
      'SHR': const Offset(12.5, 12.5),
      'SHIFT': const Offset(25, 25),
      'MUL': const Offset(12.5, 12.5),
      'DIV': const Offset(12.5, 12.5),
      'MOD': const Offset(12.5, 12.5),
    };
    return offsetMap[operatorName];
  }

  /// Get additional text labels for operators that need visible annotations.
  ///
  /// Flip-flop control pins intentionally do not have labels: their pin
  /// positions and the symbol shape identify the controls without adding
  /// text such as "SRST" or "ARST" to the device body.
  /// Returns a list of (text, offset, fontSize) tuples.
  static List<(String, Offset, double)>? getAdditionalTextForOperator(
    String operatorName,
  ) {
    if (operatorName.startsWith('DLATCH_')) {
      return [('en', const Offset(4, 19), 8.0)];
    }
    return null;
  }

  /// Padding above/below the first/last port in a CONCAT/SLICE bar.
  static const concatSliceVerticalPadding = 4.0;

  /// Horizontal padding on each side of the bar.
  /// Inflates the ELK node so neighbours are kept further away;
  /// the renderer draws the 2 px bar centered inside this wider box.
  static const concatSliceHorizontalPadding = 20.0;

  /// Minimum ELK width for CONCAT/SLICE (bar + 2×padding).
  static const concatSliceMinWidth = 42.0;

  /// Compute the dynamic size for a CONCAT or SLICE operator.
  ///
  /// [maxWestLabelWidth] / [maxEastLabelWidth] are the widest port-name
  /// widths (in layout units) on each side so ELK allocates enough room.
  /// When [isConcat] is true the height scales as N × sliceBaseHeight
  /// so a 2-input CONCAT is 2× a SLICE, 3-input is 3×, etc.
  /// When [isMultiOutput] is true (e.g. STRUCT_UNPACK), the height scales
  /// by the number of east (output) ports instead.
  static Size getConcatSliceSize(
    int westPortCount,
    int eastPortCount, {
    double maxWestLabelWidth = 0,
    double maxEastLabelWidth = 0,
    bool isConcat = false,
    bool isMultiOutput = false,
  }) {
    // Base height for a single SLICE (1 port per side)
    const sliceBaseHeight =
        concatSlicePortSpacing + 2 * concatSliceVerticalPadding;

    double height;
    if (isConcat && westPortCount > 1) {
      // CONCAT / STRUCT_PACK: N inputs → N × sliceBaseHeight
      height = westPortCount * sliceBaseHeight;
    } else if (isMultiOutput && eastPortCount > 1) {
      // STRUCT_UNPACK: N outputs → N × sliceBaseHeight
      height = eastPortCount * sliceBaseHeight;
    } else {
      final maxPorts =
          westPortCount > eastPortCount ? westPortCount : eastPortCount;
      height =
          maxPorts * concatSlicePortSpacing + 2 * concatSliceVerticalPadding;
    }
    if (height < concatSliceMinHeight) {
      height = concatSliceMinHeight;
    }

    // Width accounts for port-name labels so ELK reserves enough room
    // and neighbors don't overlap the drawn text. Each side gets at least
    // the default padding; if a label is wider it replaces the padding.
    const labelGap = 10.0; // gap between bar edge and label text
    final leftPad = math.max(
      concatSliceHorizontalPadding,
      maxWestLabelWidth + labelGap,
    );
    final rightPad = math.max(
      concatSliceHorizontalPadding,
      maxEastLabelWidth + labelGap,
    );
    var width = concatSliceBarWidth + leftPad + rightPad;
    if (width < concatSliceMinWidth) {
      width = concatSliceMinWidth;
    }
    return Size(width, height);
  }

  /// Draw a vertical bar path for CONCAT/SLICE operators.
  static Path drawConcatSliceBar(double width, double height) =>
      Path()..addRect(Rect.fromLTWH(0, 0, width, height));

  /// Check whether an operator name is a CONCAT/SLICE/STRUCT_PACK/STRUCT_UNPACK type.
  /// All of these render as a narrow vertical bar with port labels.
  static bool isConcatSlice(String operatorName) =>
      operatorName == 'CONCAT' ||
      operatorName == 'SLICE' ||
      operatorName == 'STRUCT_PACK' ||
      operatorName == 'STRUCT_UNPACK';

  /// Cached stroke-only paths (lazily populated).
  static final Map<String, Path> _strokePathCache = {};

  /// Get stroke-only paths for operators that need additional line work
  /// Returns paths that should be stroked but not filled (e.g., XOR extra arc)
  static Path? getStrokeOnlyPathForOperator(String operatorName) {
    final cached = _strokePathCache[operatorName];
    if (cached != null) {
      return cached;
    }
    if (operatorName == 'XOR' || operatorName == 'NXOR') {
      // Extra arc for XOR/NXOR gates
      // Original SVG: "M0,0 A30 25 0 0 1 0,25"
      // Scaled: M0,3 A24 20 0 0 1 0,23
      final path = Path()
        ..moveTo(0, 3)
        ..arcToPoint(
          const Offset(0, 23),
          radius: const Radius.elliptical(24, 20),
        );
      _strokePathCache[operatorName] = path;
      return path;
    }
    return null;
  }
}
