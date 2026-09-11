// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_native.dart
// Native implementation of schematic layout using flutter_js (QuickJS).
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:rohd_schematic_viewer/src/perf_log.dart';
import 'package:rohd_schematic_viewer/src/services/services.dart';

/// Native implementation of [SchematicLayoutEngine].
/// Uses QuickJS via flutter_js with bundled ELK.js for layout only.
///
/// All parsing (netlist → ELK graph) and post-processing (coordinate
/// conversion, flattening) is done in Dart. Only the ELK layout
/// computation itself runs in JavaScript.
class SchematicLayoutEngineNative implements SchematicLayoutEngine {
  static SchematicLayoutEngineNative? _instance;

  JavascriptRuntime? _jsRuntime;
  bool _initialized = false;
  String? _initError;

  /// Get singleton instance.
  factory SchematicLayoutEngineNative() {
    _instance ??= SchematicLayoutEngineNative._();
    return _instance!;
  }

  SchematicLayoutEngineNative._();

  /// Check if an error represents a missing asset.
  /// rootBundle.loadString throws FlutterError for missing assets.
  bool _isAssetNotFoundError(Object error) =>
      error is FlutterError &&
      error.toString().contains('Unable to load asset');

  /// Load an asset, trying both package-prefixed and direct paths.
  /// When running as a dependency, assets are at 'packages/rohd_schematic_viewer/...'.
  /// When running directly or with staged assets, assets are at 'assets/...'.
  Future<String?> _loadAssetOrNull(String path, {String? notFoundLog}) async {
    // Try the provided path first
    try {
      return await rootBundle.loadString(path);
    } on Object catch (e) {
      if (!_isAssetNotFoundError(e)) {
        rethrow;
      }
      // Path not found, try alternative
    }

    // Try staged assets location first (for assets staged by parent app)
    if (path.contains('/assets/js/')) {
      final filename = path.split('/').last;
      final stagedPath = 'assets/js/$filename';
      try {
        return await rootBundle.loadString(stagedPath);
      } on Object catch (e) {
        if (!_isAssetNotFoundError(e)) {
          rethrow;
        }
      }
    }

    // If path starts with 'packages/rohd_schematic_viewer/', try without prefix
    if (path.startsWith('packages/rohd_schematic_viewer/')) {
      final directPath = path.substring(
        'packages/rohd_schematic_viewer/'.length,
      );
      try {
        return await rootBundle.loadString(directPath);
      } on Object catch (e) {
        if (!_isAssetNotFoundError(e)) {
          rethrow;
        }
      }
    }
    // If path doesn't have prefix, try with prefix
    else if (!path.startsWith('packages/')) {
      final packagePath = 'packages/rohd_schematic_viewer/$path';
      try {
        return await rootBundle.loadString(packagePath);
      } on Object catch (e) {
        if (!_isAssetNotFoundError(e)) {
          rethrow;
        }
      }
    }

    if (notFoundLog != null) {
      debugPrint('$notFoundLog: Asset not found at $path');
    }
    return null;
  }

  /// Load a required asset, trying both package-prefixed and direct paths.
  /// Throws an exception if the asset cannot be found at either location.
  Future<String> _loadAssetRequired(String path) async {
    final content = await _loadAssetOrNull(path);
    if (content == null) {
      throw Exception('Unable to load required asset: $path');
    }
    return content;
  }

  /// Initialize the JavaScript runtime with ELK only.
  Future<void> _initialize() async {
    if (_initialized) {
      return;
    }

    try {
      // Create QuickJS runtime
      try {
        _jsRuntime = getJavascriptRuntime(xhr: false);
      } on Exception catch (e) {
        _initError = 'QuickJS runtime unavailable: $e. Native layout engine '
            'is disabled.';
        debugPrint('[SchematicLayoutNative] $_initError');
        return;
      }

      // Enable Promise handling for async ELK layout
      _jsRuntime!.enableHandlePromises();

      // ELK.js is GWT-compiled and assigns $wnd from the first defined
      // global: window → global → self.  QuickJS provides none of these
      // but always has `globalThis` (ES2020), which carries Math, JSON, etc.
      // Defining `global = globalThis` before loading ELK ensures $wnd is
      // set correctly and $wnd.Math.max / $wnd.Math.min work at runtime.
      _jsRuntime!.evaluate(
        'if (typeof global === "undefined") { var global = globalThis; }',
      );

      // Load and evaluate ELK.js (bundled in assets)
      debugPrint('[SchematicLayoutNative] Loading ELK.js...');
      final elkJs = await _loadAssetRequired(
        'packages/rohd_schematic_viewer/assets/js/elk.bundled.js',
      );
      debugPrint(
        '[SchematicLayoutNative] ELK.js loaded: ${elkJs.length} bytes',
      );
      final elkResult = _jsRuntime!.evaluate(elkJs);
      if (elkResult.isError) {
        debugPrint(
          '[SchematicLayoutNative] ELK.js evaluation error: '
          '${elkResult.stringResult}',
        );
        throw Exception('Failed to load ELK.js: ${elkResult.stringResult}');
      }
      debugPrint('[SchematicLayoutNative] ELK.js evaluated successfully');

      // Load the standalone Dart-first ELK wrapper
      debugPrint(
        '[SchematicLayoutNative] Loading elk_layout_only_native.js...',
      );
      final elkOnlyJs = await _loadAssetRequired(
        'packages/rohd_schematic_viewer/assets/js/elk_layout_only_native.js',
      );
      final elkOnlyResult = _jsRuntime!.evaluate(elkOnlyJs);
      if (elkOnlyResult.isError) {
        debugPrint(
          '[SchematicLayoutNative] elk_layout_only warning: '
          '${elkOnlyResult.stringResult}',
        );
        throw Exception(
          'Failed to load elk_layout_only: ${elkOnlyResult.stringResult}',
        );
      }
      debugPrint('[SchematicLayoutNative] ElkLayoutOnly loaded');

      // Verify ElkLayoutOnly is available
      final checkResult = _jsRuntime!.evaluate('''
        (function() {
          if (typeof ElkLayoutOnly !== 'function') return 'ElkLayoutOnly not a function';
          return 'OK';
        })()
      ''');
      debugPrint('[SchematicLayoutNative] Check: ${checkResult.stringResult}');

      _initialized = true;
      debugPrint('[SchematicLayoutNative] Initialized (ELK only)');
    } on Exception catch (e) {
      _initError = e.toString();
      debugPrint('[SchematicLayoutNative] Initialization error: $e');
    }
  }

  @override
  bool get isAvailable => _initialized && _jsRuntime != null;

  @override
  SchematicDependencyStatus checkDependencies() {
    if (!_initialized) {
      return SchematicDependencyStatus(elk: _jsRuntime != null);
    }

    try {
      final result = _jsRuntime!.evaluate(
        'typeof ElkLayoutOnly === "function"',
      );
      return SchematicDependencyStatus(elk: result.stringResult == 'true');
    } on Exception {
      return SchematicDependencyStatus(elk: false);
    }
  }

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) async {
    // Ensure initialized
    if (!_initialized) {
      await _initialize();
    }

    if (!_initialized || _jsRuntime == null) {
      return SchematicLayoutResult(
        instances: <SchematicInstanceData>[],
        ports: [],
        edges: [],
        width: 800,
        height: 600,
        error: _initError ?? 'JavaScript runtime not initialized',
      );
    }

    try {
      // Escape and store the JSON
      final escapedJson = jsonEncode(elkGraphJson);
      if (kPerfLog) {
        debugPrint('[PERF] ELK input JSON size: ${escapedJson.length} chars');
      }

      _jsRuntime!.evaluate('var __elkInput = $escapedJson;');

      // Call the standalone ElkLayoutOnly function (returns a Promise)
      final promiseResult = _jsRuntime!.evaluate(
        'FLUTTER_NATIVEJS_REGISTER_'
        'PROMISE(ElkLayoutOnly(__elkInput))',
      );

      if (promiseResult.isError) {
        debugPrint(
          '[Native] elkLayoutOnly promise error: '
          '${promiseResult.stringResult}',
        );
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ELK promise error: ${promiseResult.stringResult}',
        );
      }

      final promiseIdx = int.tryParse(promiseResult.stringResult);
      if (promiseIdx == null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'Invalid promise index',
        );
      }

      // Wait for the promise to resolve
      const maxWaitMs = 30000;
      const checkIntervalMs = 50;
      var elapsed = 0;
      if (kPerfLog) {
        debugPrint('[PERF] Waiting for ELK promise...');
      }

      while (_jsRuntime!.isPendingPromise(promiseIdx) && elapsed < maxWaitMs) {
        _jsRuntime!.executePendingJob();
        await Future<void>.delayed(
          const Duration(milliseconds: checkIntervalMs),
        );
        elapsed += checkIntervalMs;
      }

      if (elapsed >= maxWaitMs) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ELK layout timeout after ${maxWaitMs}ms',
        );
      }

      if (!_jsRuntime!.isFulfilledPromise(promiseIdx)) {
        final err = _jsRuntime!.evaluate(
          'JSON.stringify(FLUTTER_NATIVEJS_'
          'PENDING_PROMISES[$promiseIdx].getValue())',
        );
        _jsRuntime!.evaluate('FLUTTER_NATIVEJS_CLEAN_PROMISE($promiseIdx)');
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ELK layout failed: ${err.stringResult}',
        );
      }

      // Get raw ELK result JSON
      final resultJs = _jsRuntime!.evaluate(
        'JSON.stringify(FLUTTER_NATIVEJS_'
        'PENDING_PROMISES[$promiseIdx].getValue())',
      );
      _jsRuntime!.evaluate('FLUTTER_NATIVEJS_CLEAN_PROMISE($promiseIdx)');

      if (resultJs.isError) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'JS error: ${resultJs.stringResult}',
        );
      }

      // Parse raw ELK result and extract in Dart
      final rawElk = jsonDecode(resultJs.stringResult) as Map<String, dynamic>?;
      if (rawElk == null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'Invalid ELK result',
        );
      }

      if (rawElk['error'] != null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ELK layout error: ${rawElk['error']}',
        );
      }

      // Post-process entirely in Dart
      final layoutResult = ElkLayoutExtractor.extract(rawElk);

      if (kDebugMode) {
        debugPrint(
          '[Native] Layout: '
          '${layoutResult.instances.length} instances, '
          '${layoutResult.edges.length} edges (${elapsed}ms ELK)',
        );
      }

      return layoutResult;
    } on Exception catch (e) {
      debugPrint('[Native] computeLayoutFromElkGraph error: $e');
      return SchematicLayoutResult(
        instances: <SchematicInstanceData>[],
        ports: [],
        edges: [],
        width: 800,
        height: 600,
        error: 'Layout error: $e',
      );
    }
  }

  @override
  void dispose() {
    // Note: This is a singleton engine shared across multiple viewers.
    // We don't actually dispose the JS runtime here because other viewers
    // may still need it. The runtime will be cleaned up when the app exits.
  }

  /// Force dispose of the singleton instance.
  /// Use only when you're sure no other code needs the engine.
  void forceDispose() {
    _jsRuntime?.dispose();
    _jsRuntime = null;
    _initialized = false;
    _instance = null;
  }
}

/// Factory function to create the native layout engine.
SchematicLayoutEngine createSchematicLayoutEngine() =>
    SchematicLayoutEngineNative();
