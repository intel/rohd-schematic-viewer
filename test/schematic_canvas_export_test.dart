// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_canvas_export_test.dart
// PNG export viewport rasterization tests.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';

void main() {
  test('keeps the preferred resolution for small visible viewports', () {
    expect(
      pngExportPixelRatioForViewport(const Size(500, 300)),
      6,
    );
  });

  test('limits large viewport raster dimensions without cropping', () {
    const viewportSize = Size(1920, 1080);
    final pixelRatio = pngExportPixelRatioForViewport(viewportSize);
    final outputWidth = viewportSize.width * pixelRatio;
    final outputHeight = viewportSize.height * pixelRatio;

    expect(pixelRatio, lessThan(6));
    expect(outputWidth, lessThanOrEqualTo(4096));
    expect(outputHeight, lessThanOrEqualTo(4096));
    expect(outputWidth * outputHeight, lessThanOrEqualTo(16 * 1024 * 1024));
  });

  test('downscales oversized logical viewports below one-to-one', () {
    const viewportSize = Size(10000, 1000);
    final pixelRatio = pngExportPixelRatioForViewport(viewportSize);

    expect(pixelRatio, lessThan(1));
    expect(viewportSize.width * pixelRatio, lessThanOrEqualTo(4096));
  });
}
