// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// vscode_webview_interop_stub.dart
// Stub implementation for non-web platforms.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Returns null on non-web platforms (no injected schematic).
String? getInjectedSchematicJson() => null;

/// Returns false on non-web platforms.
bool isVscodeWebview() => false;

/// Returns 'dart' on non-web platforms (default parser).
String getInjectedParser() => 'dart';

/// Stub: always returns false on non-web platforms.
bool requestReloadFromDisk() => false;

/// Stub: no-op on non-web platforms.
void listenForExtensionMessages({
  required void Function(String jsonData) onReload,
  void Function(String error)? onError,
  void Function({required bool canSendSignals})? onSignalViewerAvailability,
  void Function(List<String> signalPaths)? onIncomingSignals,
}) {}

/// Stub: always returns false on non-web platforms.
bool postSignalViewerReady() => false;

/// Stub: always returns false on non-web platforms.
bool postSendSignals({required List<String> signalPaths}) => false;

/// Stub: always returns false on non-web platforms.
bool postGoToSource({
  required String file,
  required int line,
  required int col,
}) =>
    false;

/// Stub: always returns false on non-web platforms.
bool postGoToSourceMulti({
  required List<Map<String, Object>> frames,
  int index = 0,
}) =>
    false;

/// Stub: always returns false on non-web platforms.
bool postGoToSourceByName({
  required List<Map<String, String>> signals,
  String? format,
}) =>
    false;

/// Stub: always returns false on non-web platforms.
bool postSavePng({required String pngBase64, required String suggestedName}) =>
    false;
