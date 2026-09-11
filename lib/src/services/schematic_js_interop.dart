// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_js_interop.dart
// Minimal JS interop for schematic layout engine.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert' as convert;
import 'dart:js_interop';

// ============================================================================
// External JS declarations for ELK layout
// ============================================================================

/// External reference to window.ElkLayoutOnly (loaded from elk_layout_only.js)
@JS('ElkLayoutOnly')
external JSFunction? get elkLayoutOnlyFn;

/// Extension for accessing properties dynamically on JSObject
extension JSObjectDynamic on JSObject {
  /// Dynamic property access by key.
  external JSAny? operator [](String key);
}

// ============================================================================
// Conversion utilities
// ============================================================================

/// External JSON.stringify to convert JS objects to string
@JS('JSON.stringify')
external JSString? _jsonStringify(JSAny? value);

/// Convert JavaScript values to Dart values using JSON round-trip.
/// This is more reliable than manual type checking for complex objects.
dynamic jsToDart(JSAny? value) {
  if (value == null) {
    return null;
  }

  // Handle primitives directly
  if (value.isA<JSString>()) {
    return (value as JSString).toDart;
  }
  if (value.isA<JSNumber>()) {
    return (value as JSNumber).toDartDouble;
  }
  if (value.isA<JSBoolean>()) {
    return (value as JSBoolean).toDart;
  }

  // For arrays and objects, use JSON round-trip
  try {
    final jsonStr = _jsonStringify(value);
    if (jsonStr != null) {
      return convert.jsonDecode(jsonStr.toDart);
    }
  } on Exception catch (_) {
    // Fall through - return raw value
  }

  return value;
}
