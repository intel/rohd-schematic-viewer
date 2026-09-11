// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// vscode_webview_interop_web.dart
// Web implementation for VS Code webview integration.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Dynamic property access on JSObject (same pattern as schematic_js_interop).
extension _JSObjectProp on JSObject {
  /// Read a JS property by name.
  external JSAny? operator [](String key);
}

/// JavaScript interop for accessing window properties
@JS('window.SCHEMATIC_JSON_BASE64')
external JSString? get _schematicJsonBase64;

@JS('window.VSCODE_WEBVIEW')
external JSBoolean? get _vscodeWebview;

@JS('window.SCHEMATIC_PARSER')
external JSString? get _schematicParser;

/// Access the VS Code API object for posting messages back to the extension.
@JS('window._vscodeApi')
external JSObject? get _vscodeApiObj;

/// Gets the injected schematic JSON from VS Code webview.
/// Returns null if not running in VS Code webview or no schematic was injected.
String? getInjectedSchematicJson() {
  try {
    final base64Data = _schematicJsonBase64;
    if (base64Data == null) {
      return null;
    }
    final base64String = base64Data.toDart;
    if (base64String.isEmpty) {
      return null;
    }
    // Decode base64 to get the original JSON
    final bytes = base64Decode(base64String);
    return utf8.decode(bytes);
  } on Exception catch (e) {
    throw Exception('Error getting injected schematic: $e');
  }
}

/// Returns true if running in VS Code webview context.
bool isVscodeWebview() {
  try {
    final flag = _vscodeWebview;
    return flag?.toDart ?? false;
  } on Exception catch (_) {
    return false;
  }
}

/// Returns the parser preference injected by the VS Code extension.
/// Returns 'dart' (default) or 'javascript'.
String getInjectedParser() {
  try {
    final parser = _schematicParser;
    if (parser == null) {
      return 'dart';
    }
    return parser.toDart;
  } on Exception catch (_) {
    return 'dart';
  }
}

/// Request the VS Code extension host to reload the JSON file from disk.
/// Returns true if the request was sent, false if not in VS Code webview.
bool requestReloadFromDisk() {
  final api = _vscodeApiObj;
  if (api == null) {
    return false;
  }
  final msg = <String, String>{'type': 'reload'}.jsify();
  // Use the postMessage method on the VS Code API object
  final postMsg = api['postMessage'] as JSFunction?;
  if (postMsg == null) {
    return false;
  }
  postMsg.callAsFunction(api, msg);
  return true;
}

/// Listen for schematic data messages from the VS Code extension host.
///
/// [onReload] is called with the decoded JSON string whenever the extension
/// sends back fresh file content (in response to a reload request).
/// [onError] is called if the extension reports an error.
void listenForExtensionMessages({
  required void Function(String jsonData) onReload,
  void Function(String error)? onError,
  void Function({required bool canSendSignals})? onSignalViewerAvailability,
  void Function(List<String> signalPaths)? onIncomingSignals,
}) {
  web.window.addEventListener(
    'message',
    ((web.MessageEvent event) {
      // VS Code wraps postMessage data inside event.data
      final data = event.data;
      if (data == null) {
        return;
      }
      final jsData = data as JSObject;

      final typeVal = jsData['type'] as JSString?;
      if (typeVal == null) {
        return;
      }
      final type = typeVal.toDart;

      if (type == 'schematicData') {
        final jsonBase64 = (jsData['jsonBase64'] as JSString?)?.toDart;
        if (jsonBase64 != null && jsonBase64.isNotEmpty) {
          final bytes = base64Decode(jsonBase64);
          onReload(utf8.decode(bytes));
        }
      } else if (type == 'reloadError') {
        final errMsg = (jsData['error'] as JSString?)?.toDart ?? 'Unknown';
        onError?.call(errMsg);
      } else if (type == 'signalViewerAvailability') {
        final canSend = _readBool(jsData, 'canSendSignals') ?? false;
        onSignalViewerAvailability?.call(canSendSignals: canSend);
      } else if (type == 'incomingSignals') {
        final paths = _readStringList(jsData, 'signalPaths');
        if (paths.isNotEmpty) {
          onIncomingSignals?.call(paths);
        }
      }
    }).toJS,
  );
}

bool? _readBool(JSObject data, String key) {
  final raw = data[key];
  if (raw == null) {
    return null;
  }
  final dartValue = raw.dartify();
  if (dartValue is bool) {
    return dartValue;
  }
  return dartValue?.toString() == 'true';
}

List<String> _readStringList(JSObject data, String key) {
  final raw = data[key];
  if (raw == null) {
    return const [];
  }
  final dartValue = raw.dartify();
  if (dartValue is List) {
    return dartValue.map((item) => item.toString()).toList(growable: false);
  }
  return const [];
}

bool _postMessage(Map<String, Object> message) {
  final api = _vscodeApiObj;
  if (api == null) {
    return false;
  }
  final postMsg = api['postMessage'] as JSFunction?;
  if (postMsg == null) {
    return false;
  }
  postMsg.callAsFunction(api, message.jsify());
  return true;
}

/// Notify the VS Code extension host that the schematic viewer can be
/// registered for cross-probe signal sends.
bool postSignalViewerReady() =>
    _postMessage(<String, Object>{'type': 'signalViewerReady'});

/// Broadcast selected signal paths through the VS Code extension host.
bool postSendSignals({required List<String> signalPaths}) => _postMessage(
      <String, Object>{
        'type': 'sendSignals',
        'source': 'schematic',
        'signalPaths': signalPaths,
      },
    );

/// Post a single-frame "go to source" request to the VS Code extension host.
///
/// The extension forwards this to the ROHD extension's
/// `rohd.openSourceLocation` command, which opens the file
/// in an editor tab beside the schematic.
///
/// Returns true if the message was posted, false if not in VS Code webview.
bool postGoToSource({
  required String file,
  required int line,
  required int col,
}) =>
    _postMessage(<String, Object>{
      'type': 'openSourceLocation',
      'file': file,
      'line': line,
      'col': col,
    });

/// Post a multi-frame "go to source" request to the VS Code extension host.
///
/// Each frame is a map with `file`, `line`, `col`, and optional `desc` keys.
/// The extension forwards this to `rohd.openSourceLocations` for frame cycling.
///
/// Returns true if the message was posted, false if not in VS Code webview.
bool postGoToSourceMulti({
  required List<Map<String, Object>> frames,
  int index = 0,
}) =>
    _postMessage(<String, Object>{
      'type': 'openSourceLocations',
      'frames': frames,
      'index': index,
    });

/// Post a "go to source by name" request to the VS Code extension host.
///
/// Instead of sending pre-resolved file/line/col, this sends signal identity
/// (module + name). The extension host looks up the signal in the `.flc.json`
/// sidecar or the netlist's embedded ROHD source trace.
///
/// Each signal entry is a map with `module` and `name` keys.
/// If [format] is non-null (`'rohd'` or `'sv'`), only frames of that type
/// will be returned.
///
/// Returns true if the message was posted, false if not in VS Code webview.
bool postGoToSourceByName({
  required List<Map<String, String>> signals,
  String? format,
}) =>
    _postMessage(<String, Object>{
      'type': 'goToSource',
      'signals': signals,
      if (format != null) 'format': format,
    });

/// Post a "save PNG" request to the VS Code extension host.
///
/// The extension shows a native Save dialog, letting the user choose the
/// output path, and writes [pngBase64] (base64-encoded PNG bytes) there.
///
/// Returns true if the message was posted, false if not in VS Code webview.
bool postSavePng({required String pngBase64, required String suggestedName}) =>
    _postMessage(<String, Object>{
      'type': 'savePng',
      'data': pngBase64,
      'suggestedName': suggestedName,
    });
