// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// standalone_schematic_viewer_page.dart
// Unified standalone page for both desktop and web-dev environments.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart'
    show
        DiagnosticPropertiesBuilder,
        DiagnosticsProperty,
        StringProperty,
        kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_webview_interop_stub.dart'
    if (dart.library.js_interop) '../services/vscode_webview_interop_web.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';

/// Default schematic file name for demo.
const String _defaultSchematicFileName = 'rohd_schematic.json';

/// Standalone page used for **both** desktop (Linux / macOS / Windows) and
/// web-dev (standalone browser, not VS Code extension) environments.
///
/// Loads a default schematic from assets and displays the Dart-first
/// Flutter CustomPaint schematic viewer.
class StandaloneSchematicViewerPage extends StatefulWidget {
  /// Constructor for [StandaloneSchematicViewerPage].
  const StandaloneSchematicViewerPage({
    this.initialSchematicJson,
    this.layoutEngine,
    super.key,
  });

  /// Optional initial netlist JSON, used instead of loading the demo asset.
  final String? initialSchematicJson;

  /// Optional layout engine override for specialized hosts and widget tests.
  final SchematicLayoutEngine? layoutEngine;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('initialSchematicJson', initialSchematicJson))
      ..add(
        DiagnosticsProperty<SchematicLayoutEngine?>(
          'layoutEngine',
          layoutEngine,
        ),
      );
  }

  @override
  State<StandaloneSchematicViewerPage> createState() =>
      _StandaloneSchematicViewerPageState();
}

class _StandaloneSchematicViewerPageState
    extends BaseSchematicViewerState<StandaloneSchematicViewerPage> {
  bool _appBarPinned = true;
  final _canvasKey = GlobalKey<SchematicCanvasState>();

  @override
  SchematicLayoutEngine createLayoutEngine() =>
      widget.layoutEngine ?? super.createLayoutEngine();

  @override
  Future<void> loadInitialSchematic() async {
    setLoading(loading: true);

    try {
      String? jsonData;
      String? loadedFileName;

      final initialJson = widget.initialSchematicJson;
      if (initialJson != null) {
        jsonData = initialJson;
        loadedFileName = 'Provided schematic';
      } else {
        // Evict any cached copy so we re-read the actual file from disk/server.
        const assetKey = kIsWeb
            ? _defaultSchematicFileName
            : 'assets/$_defaultSchematicFileName';
        rootBundle.evict(assetKey);

        if (kIsWeb) {
          // Check if running in VS Code webview with injected schematic.
          final injectedJson = getInjectedSchematicJson();
          if (injectedJson != null && injectedJson.isNotEmpty) {
            jsonData = injectedJson;
            loadedFileName = 'VS Code Schematic';
          } else {
            // On web, rootBundle prepends 'assets/' automatically.
            jsonData = await rootBundle.loadString(_defaultSchematicFileName);
            loadedFileName = _defaultSchematicFileName;
          }
        } else {
          // Desktop: full asset path required.
          jsonData = await rootBundle.loadString(
            'assets/$_defaultSchematicFileName',
          );
          loadedFileName = _defaultSchematicFileName;
        }
      }

      setFileName(loadedFileName);
      await computeLayout(jsonData);
    } on Exception catch (e) {
      debugPrint('Failed to load initial schematic: $e');
      setLoading(loading: false, errorMessage: 'Failed to load schematic: $e');
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SchematicThemeCubit, SchematicThemeMode>(
        builder: (context, themeMode) => Scaffold(
          body: AppBarOverlay(
            autoHide: !_appBarPinned && layout != null,
            appBar: buildAppBar(
              context: context,
              showFileNameBadge: true,
              showFilePicker: true,
              appBarPinned: _appBarPinned,
              onAppBarPinnedChanged: _setAppBarPinned,
            ),
            body: RepaintBoundary(child: _buildBody()),
          ),
        ),
      );

  void _setAppBarPinned(bool pinned) {
    if (pinned == _appBarPinned) {
      return;
    }

    final canvasState = _canvasKey.currentState;
    if (canvasState != null) {
      canvasState.setView(
        offset: canvasState.currentOffset +
            Offset(0, pinned ? -kToolbarHeight : kToolbarHeight),
        scale: canvasState.currentScale,
      );
    }
    setState(() => _appBarPinned = pinned);
  }

  Widget _buildBody() {
    if (isLoading) {
      return buildLoadingIndicator();
    }
    if (error != null) {
      return buildErrorDisplay();
    }
    if (layout == null ||
        (layout!.instances.isEmpty && layout!.edges.isEmpty)) {
      return buildEmptyState(
        title: 'No schematic data',
        subtitle: 'Load a netlist JSON file to view schematic.',
      );
    }
    return buildSchematicCanvas(canvasKey: _canvasKey);
  }
}
