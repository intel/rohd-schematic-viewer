// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_file_read_web.dart
// Bounded browser file reads using verified Blob byte ranges.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:web/web.dart' as web;

/// Amortizes browser fetch overhead without buffering the entire file.
const int maxReadBytes = 1024 * 1024;

/// Reads only the requested bytes, without XFile's whole-Blob XHR hydration.
Future<Uint8List> readFileRange(
    XFile file, int start, int end, int totalLength) async {
  if (!file.path.startsWith('blob:')) {
    throw const FormatException(
        'Browser netlists must be selected files with Blob URLs');
  }
  final controller = web.AbortController();
  try {
    return await _readRange(file.path, start, end, totalLength, controller)
        .timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        controller.abort();
        throw FormatException(
            'Timed out reading browser netlist bytes $start:$end');
      },
    );
  } on Exception {
    rethrow;
  } catch (error) {
    // JS Promise rejections need not be Dart Exceptions. Normalize them for
    // the viewer's existing visible file-error handler.
    throw FormatException(
        'Failed to read browser netlist bytes $start:$end: $error');
  } finally {
    controller.abort();
  }
}

Future<Uint8List> _readRange(String url, int start, int end, int totalLength,
    web.AbortController controller) async {
  final headers = web.Headers()..set('Range', 'bytes=$start-${end - 1}');
  final response = await web.window
      .fetch(
        url.toJS,
        web.RequestInit(headers: headers, signal: controller.signal),
      )
      .toDart;
  final expectedRange = 'bytes $start-${end - 1}/$totalLength';
  if (response.status != 206 ||
      response.headers.get('Content-Range') != expectedRange) {
    throw FormatException(
        'Browser did not honor netlist byte range $start:$end '
        '(status ${response.status}); refusing a whole-file read');
  }
  final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
  if (bytes.length != end - start) {
    throw const FormatException('Netlist range was truncated; reload the file');
  }
  return bytes;
}
