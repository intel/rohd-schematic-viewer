// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_layout_web.dart
// Web implementation of schematic layout using JavaScript interop.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:rohd_schematic_viewer/src/services/elk_layout_extractor.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_js_interop.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';

/// Web implementation of [SchematicLayoutEngine].
/// Uses browser's JavaScript engine with ELK for layout only.
class SchematicLayoutEngineWeb implements SchematicLayoutEngine {
  static SchematicLayoutEngineWeb? _instance;

  /// Get or create singleton instance via factory constructor.
  factory SchematicLayoutEngineWeb() {
    _instance ??= SchematicLayoutEngineWeb._();
    return _instance!;
  }

  SchematicLayoutEngineWeb._();

  @override
  bool get isAvailable {
    try {
      return elkLayoutOnlyFn != null;
    } on Exception catch (_) {
      return false;
    }
  }

  @override
  SchematicDependencyStatus checkDependencies() {
    try {
      final hasElk = elkLayoutOnlyFn != null;
      return SchematicDependencyStatus(elk: hasElk);
    } on Exception catch (_) {
      return SchematicDependencyStatus(elk: false);
    }
  }

  @override
  Future<SchematicLayoutResult> computeLayoutFromElkGraph(
    String elkGraphJson, {
    String? sessionId,
  }) async {
    try {
      // Use the standalone ElkLayoutOnly function (from elk_layout_only.js)
      final fn = elkLayoutOnlyFn;
      if (fn == null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ElkLayoutOnly not found. ELK JS may not be loaded.',
        );
      }

      // Call the slim JS function (returns a Promise)
      final promise =
          fn.callAsFunction(null, elkGraphJson.toJS) as JSPromise<JSAny?>?;
      if (promise == null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ElkLayoutOnly returned null',
        );
      }

      final jsResult = await promise.toDart;

      // Convert JS result to Dart map.  jsToDart already routes objects
      // through jsonDecode, which yields a fully String-keyed
      // Map<String, dynamic> / List<dynamic> tree.  In that (normal) case we
      // can use it directly and skip the redundant deep re-copy below, which
      // otherwise dominated the inbound conversion cost on large layouts.
      // Fall back to the defensive deep conversion only for unexpected shapes.
      final dartResult = jsToDart(jsResult);
      final resultMap = dartResult is Map<String, dynamic>
          ? dartResult
          : _convertToStringDynamic(dartResult);

      // Check for error from ELK
      if (resultMap['error'] != null) {
        return SchematicLayoutResult(
          instances: <SchematicInstanceData>[],
          ports: [],
          edges: [],
          width: 800,
          height: 600,
          error: 'ELK layout error: ${resultMap['error']}',
        );
      }

      // Post-process entirely in Dart:
      //  1. convertToAbsoluteCoordinates
      //  2. flatten hierarchy → SchematicLayoutResult
      return ElkLayoutExtractor.extract(resultMap);
    } on Exception catch (e) {
      if (kDebugMode) {
        debugPrint('[Web] computeLayoutFromElkGraph error: $e');
      }
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
    // Nothing to dispose for web implementation
  }

  /// Recursively convert LinkedMap/dynamic to `Map<String, dynamic>`
  static Map<String, dynamic> _convertToStringDynamic(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      value.forEach((key, val) {
        result[key.toString()] = _convertValue(val);
      });
      return result;
    }
    return {};
  }

  /// Recursively convert values from JS objects to Dart objects
  static dynamic _convertValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      value.forEach((key, val) {
        result[key.toString()] = _convertValue(val);
      });
      return result;
    } else if (value is List) {
      return value.map(_convertValue).toList();
    }
    return value;
  }
}

/// Factory function to create the web layout engine.
SchematicLayoutEngine createSchematicLayoutEngine() =>
    SchematicLayoutEngineWeb();
