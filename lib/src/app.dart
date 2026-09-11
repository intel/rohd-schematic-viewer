// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// app.dart
// Main application widget for the standalone schematic viewer.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart' show kIsWeb;
// Embedded DevTools widgets still require Flutter's MaterialLocalizations.
// ignore: migrate_design_widgets
import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_webview_interop_stub.dart'
    if (dart.library.js_interop) 'services/vscode_webview_interop_web.dart';
import 'package:rohd_schematic_viewer/src/ui/flutter_schematic_viewer_page.dart';
import 'package:rohd_schematic_viewer/src/ui/standalone_schematic_viewer_page.dart';

/// Main application widget.
class SchematicViewerApp extends StatelessWidget {
  /// Constructor for [SchematicViewerApp].
  const SchematicViewerApp({super.key});

  ThemeData _buildDarkTheme() => ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF252526),
          elevation: 0,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Colors.blue,
          secondary: Colors.blueAccent,
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF3C3C3C),
          elevation: 8,
          shadowColor: Colors.black54,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      );

  ThemeData _buildLightTheme() => ThemeData.light().copyWith(
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          foregroundColor: Colors.black,
        ),
        colorScheme: const ColorScheme.light(
          primary: Colors.blue,
          secondary: Colors.blueAccent,
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: Colors.white,
          elevation: 8,
          shadowColor: Colors.black26,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
          ),
          textStyle: const TextStyle(color: Colors.black87, fontSize: 13),
        ),
      );

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (context) => SchematicThemeCubit(),
        child: BlocBuilder<SchematicThemeCubit, SchematicThemeMode>(
          builder: (context, themeMode) => MaterialApp(
            title: 'ROHD Schematic Viewer',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: const [
              flutter_material.DefaultMaterialLocalizations.delegate,
            ],
            theme: themeMode == SchematicThemeMode.dark
                ? _buildDarkTheme()
                : _buildLightTheme(),
            // Route based on platform and context:
            // - Desktop (Linux/macOS/Windows): Flutter-only from assets
            // - Web + VS Code webview: Flutter renderer from injected JSON
            // - Web + standalone dev: tabbed UI for testing both renderers
            home: kIsWeb && isVscodeWebview()
                ? const FlutterSchematicViewerPage()
                : const StandaloneSchematicViewerPage(),
          ),
        ),
      );
}
