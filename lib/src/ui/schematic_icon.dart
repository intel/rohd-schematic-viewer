// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_icon.dart
// Custom icon: three colored blocks connected by orthogonal lines,
// resembling a small schematic / block diagram.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A custom-painted icon showing three colored rectangles connected
/// by orthogonal (right-angle) wires — a miniature schematic diagram.
///
/// Layout (within a unit square, scaled to [size]):
///
/// ```text
///   ┌──────┐
///   │  A   │─────┐
///   └──────┘     │
///                ├───────┐
///   ┌──────┐     │       │
///   │  B   │─────┘  ┌──────┐
///   └──────┘        │  C   │
///                   └──────┘
/// ```
class SchematicIcon extends StatelessWidget {
  /// Creates a schematic icon at the given [size].
  const SchematicIcon({super.key, this.size = 20, this.brightness});

  /// Icon size in logical pixels (width = height).
  final double size;

  /// Override brightness to force light/dark wire color.
  /// If null, uses the ambient [Theme.of(context).brightness].
  final Brightness? brightness;

  @override
  Widget build(BuildContext context) {
    final effectiveBrightness = brightness ?? Theme.of(context).brightness;
    return CustomPaint(
      size: Size.square(size),
      painter: _SchematicIconPainter(effectiveBrightness),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('size', size))
      ..add(EnumProperty<Brightness?>('brightness', brightness));
  }
}

class _SchematicIconPainter extends CustomPainter {
  _SchematicIconPainter(this.brightness);

  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width; // square canvas

    // Block dimensions (relative to icon size).
    final bw = s * 0.30; // block width
    final bh = s * 0.22; // block height
    final r = s * 0.04; // corner radius

    // Block positions (top-left corners).
    //  A: upper-left
    //  B: lower-left
    //  C: middle-right
    final ax = s * 0.02;
    final ay = s * 0.08;
    final bx = s * 0.02;
    final by = s * 0.62;
    final cx = s * 0.64;
    final cy = s * 0.38;

    // Wire color adapts to theme.
    final wireColor =
        brightness == Brightness.dark ? Colors.white70 : Colors.black54;
    final wirePaint = Paint()
      ..color = wireColor
      ..strokeWidth = s * 0.045
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Orthogonal wires: A-right → junction → C-left,
    //                   B-right → junction.
    // Junction x sits midway between blocks and C.
    final jx = s * 0.52; // junction x
    final aPortY = ay + bh / 2; // A right-center
    final bPortY = by + bh / 2; // B right-center
    final cPortY = cy + bh / 2; // C left-center

    // Wire from A to junction.
    final wireA = Path()
      ..moveTo(ax + bw, aPortY)
      ..lineTo(jx, aPortY)
      ..lineTo(jx, cPortY);
    canvas.drawPath(wireA, wirePaint);

    // Wire from B to junction.
    final wireB = Path()
      ..moveTo(bx + bw, bPortY)
      ..lineTo(jx, bPortY)
      ..lineTo(jx, cPortY);
    canvas.drawPath(wireB, wirePaint);

    // Wire from junction to C.
    final wireC = Path()
      ..moveTo(jx, cPortY)
      ..lineTo(cx, cPortY);
    canvas.drawPath(wireC, wirePaint);

    // Junction dot.
    final dotPaint = Paint()..color = wireColor;
    canvas.drawCircle(Offset(jx, cPortY), s * 0.04, dotPaint);

    // Block colors.
    const colorA = Color(0xFF4A90D9); // blue
    const colorB = Color(0xFF50B86C); // green
    const colorC = Color(0xFFE8943A); // orange

    // Draw blocks with rounded corners.
    void drawBlock(double x, double y, Color color) {
      final rect = RRect.fromLTRBR(x, y, x + bw, y + bh, Radius.circular(r));
      final fill = Paint()..color = color;
      canvas.drawRRect(rect, fill);
      // Subtle border.
      final border = Paint()
        ..color = color.withAlpha(200)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.02;
      canvas.drawRRect(rect, border);
    }

    drawBlock(ax, ay, colorA);
    drawBlock(bx, by, colorB);
    drawBlock(cx, cy, colorC);
  }

  @override
  bool shouldRepaint(_SchematicIconPainter old) => old.brightness != brightness;
}
