// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_web_test.dart
// Browser integration test for package-owned ELK asset loading.
//
// 2026 September
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:rohd_schematic_viewer/src/services/elk_layout_web_loader.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_js_interop.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('loads the engine before the wrapper', () async {
    expect(elkLayoutOnlyFn, isNull);

    String createScriptUrl(String source) => web.URL.createObjectURL(
          web.Blob(
            <JSAny>[source.toJS].toJS,
            web.BlobPropertyBag(type: 'text/javascript'),
          ),
        );

    final engineUrl = createScriptUrl('window.ELK = function() {};');
    final wrapperUrl = createScriptUrl('''
      if (typeof window.ELK !== 'function') {
        throw new Error('ELK must load before the wrapper');
      }
      window.ElkLayoutOnly = function() {};
    ''');
    addTearDown(() {
      web.URL.revokeObjectURL(engineUrl);
      web.URL.revokeObjectURL(wrapperUrl);
    });

    await ensureElkLayoutOnlyLoaded(
      assetCandidates: [(engine: engineUrl, wrapper: wrapperUrl)],
    );

    expect(elkLayoutOnlyFn, isNotNull);
  });
}
