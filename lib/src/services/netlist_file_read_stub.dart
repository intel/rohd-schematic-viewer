// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// netlist_file_read_stub.dart
// Bounded native file reads with read and cancellation deadlines.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;

/// Native reads do not incur browser fetch overhead.
const int maxReadBytes = 65536;

/// Reads a bounded range using the native file implementation.
Future<Uint8List> readFileRange(
    XFile file, int start, int end, int totalLength) async {
  final bytes = BytesBuilder(copy: false);
  final complete = Completer<void>();
  var finished = false;
  Object? readError;
  final subscription = file.openRead(start, end).listen(
    bytes.add,
    onError: (Object error, StackTrace stack) {
      if (!complete.isCompleted) {
        readError = error;
        complete.completeError(error, stack);
      }
    },
    onDone: () {
      finished = true;
      if (!complete.isCompleted) {
        complete.complete();
      }
    },
  );
  try {
    await complete.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw FormatException('Timed out reading netlist bytes $start:$end'),
    );
    return bytes.takeBytes();
  } finally {
    if (!finished) {
      // A stalled stream can also stall cancellation. Do not hide its read
      // timeout behind an unbounded cleanup wait.
      final failure =
          readError ?? 'Timed out reading netlist bytes $start:$end';
      await subscription.cancel().timeout(
            const Duration(seconds: 1),
            onTimeout: () => throw FormatException('$failure; '
                'stream cancellation timed out for bytes $start:$end'),
          );
    }
  }
}
