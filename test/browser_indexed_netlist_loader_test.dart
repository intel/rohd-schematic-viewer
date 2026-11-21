// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// browser_indexed_netlist_loader_test.dart
// Browser byte-range indexing and deferred connectivity regression tests.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:rohd_schematic_viewer/src/services/indexed_netlist_loader.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

_RangeOnlyBrowserFile _file(String text, {int extraLength = 0}) {
  final blob = web.File(<JSAny>[text.toJS].toJS, 'netlist.json');
  final url = web.URL.createObjectURL(blob);
  addTearDown(() => web.URL.revokeObjectURL(url));
  return _RangeOnlyBrowserFile(
    url,
    length: blob.size + extraLength,
    lastModified: DateTime.fromMillisecondsSinceEpoch(blob.lastModified),
  );
}

void main() {
  test('reads the first browser range without whole-Blob XFile hydration',
      () async {
    final file = _file('0123456789' * 10000);
    final source = FileNetlistByteSource(file);
    expect(source.totalBytes, isNull);
    final bytes = await source.openRead(13, 27).expand((b) => b).toList();
    expect(source.totalBytes, 100000);
    expect(utf8.decode(bytes), '34567890123456');
  });

  test('indexes a large browser file and fetches only requested connectivity',
      () async {
    final json = jsonEncode({
      'modules': {
        'Top': {
          'attributes': {'top': 1},
          'ports': {
            'a': {
              'direction': 'input',
              'bits': [2],
            },
          },
          'cells': {
            'child': {
              'type': 'Leaf',
              'port_directions': {'A': 'input'},
              'connections': {
                'A': List<int>.filled(600000, 2),
              },
            },
          },
        },
        'Leaf': {
          'ports': <String, dynamic>{},
          'cells': {
            'gate': {
              'type': r'$buf',
              'connections': {
                'A': [2],
              },
            },
          },
        },
      },
    });
    final file = _file(json);
    final source = _CountingSource(FileNetlistByteSource(file));
    final progress = <(int, int)>[];
    final loader = await IndexedNetlistLoader.index(
      source,
      onProgress: (bytes, modules) => progress.add((bytes, modules)),
    );
    final size = await file.length();
    expect(size, greaterThan(1024 * 1024));
    expect(source.bytesRead, size);
    expect(source.largestChunk, 1024 * 1024);
    expect(source.chunksRead, (size / (1024 * 1024)).ceil());
    expect(source.reads, [(0, null)]);
    expect(progress.last, (size, 2));
    expect(jsonEncode(loader.hierarchyJson).length, lessThan(size ~/ 100));

    final module = await loader.fetchModuleNetlist('Leaf');
    expect(module.keys, ['Leaf']);
    expect(source.reads, hasLength(2));
    expect(source.bytesRead - size, lessThan(1024));
    final leaf = module['Leaf'] as Map<String, dynamic>;
    final cells = leaf['cells'] as Map<String, dynamic>;
    final gate = cells['gate'] as Map<String, dynamic>;
    expect(gate['connections'], {
      'A': [2],
    });
  });

  test('revoked Blob URLs produce a visible Dart format error', () async {
    final file = _file('{"modules":{"Top":{}}}');
    web.URL.revokeObjectURL(file.path);
    await expectLater(
      IndexedNetlistLoader.index(FileNetlistByteSource(file)),
      throwsFormatException,
    );
  });

  test('rejects an unexpected range response before consuming the body',
      () async {
    final file = _file('{"modules":{"Top":{}}}', extraLength: 1);
    await expectLater(
      IndexedNetlistLoader.index(FileNetlistByteSource(file)),
      throwsFormatException,
    );
  });
}

class _RangeOnlyBrowserFile extends XFile {
  _RangeOnlyBrowserFile(super.path,
      {required super.length, required super.lastModified});

  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      throw StateError('XFile would hydrate the whole Blob before slicing');

  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('Whole-file reads are forbidden');

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      throw StateError('Whole-file reads are forbidden');
}

class _CountingSource extends NetlistByteSource {
  _CountingSource(this.source);

  final NetlistByteSource source;
  final List<(int, int?)> reads = [];
  int bytesRead = 0;
  int largestChunk = 0;
  int chunksRead = 0;

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    reads.add((start, end));
    await for (final chunk in source.openRead(start, end)) {
      chunksRead++;
      bytesRead += chunk.length;
      if (chunk.length > largestChunk) {
        largestChunk = chunk.length;
      }
      yield chunk;
    }
  }
}
