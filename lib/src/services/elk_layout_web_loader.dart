// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// elk_layout_web_loader.dart
// Loads the ELK scripts required by the package's web layout engine.
//
// 2026 September
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:js_interop';

import 'package:rohd_schematic_viewer/src/services/schematic_js_interop.dart';
import 'package:web/web.dart' as web;

const _elkAssetCandidates = <({String engine, String wrapper})>[
  (
    engine: 'assets/packages/rohd_schematic_viewer/assets/js/elk.bundled.js',
    wrapper:
        'assets/packages/rohd_schematic_viewer/js_bridge/elk_layout_only.js',
  ),
  (
    engine: 'assets/assets/js/elk.bundled.js',
    wrapper: 'assets/js_bridge/elk_layout_only.js',
  ),
];

Future<void>? _loading;

/// Loads ELK and the Dart-first wrapper from the package asset bundle.
///
/// The standalone viewer preloads these scripts from its own `index.html`, so
/// this is a no-op there. Dependency consumers load the package-owned assets
/// lazily on their first layout request.
Future<void> ensureElkLayoutOnlyLoaded({
  Iterable<({String engine, String wrapper})>? assetCandidates,
}) {
  if (elkLayoutOnlyFn != null) {
    return Future<void>.value();
  }
  return _loading ??= _loadElkLayoutOnly(
    assetCandidates ?? _elkAssetCandidates,
  );
}

Future<void> _loadElkLayoutOnly(
  Iterable<({String engine, String wrapper})> assetCandidates,
) async {
  Object? lastError;

  try {
    for (final candidate in assetCandidates) {
      try {
        await _loadScript(candidate.engine);
        await _loadScript(candidate.wrapper);
        if (elkLayoutOnlyFn != null) {
          return;
        }
        lastError = StateError(
          'The loaded wrapper did not register window.ElkLayoutOnly.',
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw StateError(
      'Unable to load package ELK layout assets: $lastError',
    );
  } on Object {
    _loading = null;
    rethrow;
  }
}

Future<void> _loadScript(String source) {
  final completer = Completer<void>();
  final script = web.HTMLScriptElement()
    ..async = false
    ..src = source
    ..addEventListener(
      'load',
      ((web.Event _) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }).toJS,
    )
    ..addEventListener(
      'error',
      ((web.Event _) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Unable to load web layout script: $source'),
          );
        }
      }).toJS,
    );

  final head = web.document.head;
  if (head != null) {
    head.append(script);
  } else {
    final body = web.document.body;
    if (body == null) {
      return Future<void>.error(
        StateError(
          'Cannot load web layout scripts before the document exists.',
        ),
      );
    }
    body.append(script);
  }

  return completer.future;
}
