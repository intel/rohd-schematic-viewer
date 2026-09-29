// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// main.dart
// Main entry point for the standalone schematic viewer application.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Standalone ROHD Schematic Viewer application.
library;

import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/src/app.dart';
import 'package:rohd_schematic_viewer/src/const/app_version.dart';
import 'package:rohd_schematic_viewer/src/platform/keyboard_init.dart'
    if (dart.library.js_interop) 'package:rohd_schematic_viewer/src/platform/keyboard_init_web.dart';
import 'package:rohd_schematic_viewer/src/platform/url_strategy.dart';

/// Initializes and runs the standalone schematic viewer application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initAppVersion();
  configureUrlStrategyIfWeb();
  initializeKeyboardHandling();
  runApp(const SchematicViewerApp());
}
