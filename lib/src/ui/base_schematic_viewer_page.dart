// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// base_schematic_viewer_page.dart
// Base class for schematic viewer pages with common functionality.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show Completer, TimeoutException, unawaited;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show SystemMouseCursors, rootBundle;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show
        AvailableSourceFormats,
        CrossProbeService,
        GoToSourceCallback,
        RohdSourceFormat;
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/perf_log.dart';
import 'package:rohd_schematic_viewer/src/platform/platform_emoji.dart'
    as platform_emoji;
import 'package:rohd_schematic_viewer/src/schematic/schematic.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_stub.dart'
    if (dart.library.js_interop) '../services/schematic_layout_web.dart'
    if (dart.library.io) '../services/schematic_layout_native.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_app_bar.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_expansion_mode.dart';

/// Base state class for schematic viewer pages.
/// Contains common logic for layout computation, node toggling, and rendering.
abstract class BaseSchematicViewerState<T extends StatefulWidget>
    extends State<T> {
  SchematicLayoutEngine? _layoutEngine;

  /// Dart schematic adapter (owns the graph in Dart).
  /// Handles parsing and toggle operations.
  @protected
  NetlistSchematicAdapter? schematicAdapter;

  /// Session ID used to isolate JS bridge state.
  String get _sessionId => 'dart';

  /// Protected access to the layout engine for subclasses.
  @protected
  SchematicLayoutEngine? get layoutEngine => _layoutEngine;

  /// Protected access to the session ID for subclasses.
  @protected
  String get sessionId => _sessionId;

  @protected

  /// Current schematic layout result.
  SchematicLayoutResult? layout;
  @protected

  /// Current schematic JSON data.
  String? schematicJson;
  @protected

  /// Current file name.
  String? fileName;
  @protected

  /// Current error message, if any.
  String? error;
  @protected

  /// Loading state.
  bool isLoading = true;
  @protected

  /// Toggling state.
  bool isToggling = false;

  /// Label shown in the busy overlay (e.g. 'Expanding...' or 'Collapsing...').
  @protected
  String togglingLabel = 'Expanding...';
  @protected

  /// Pending node ID for toggle operation.
  String? pendingToggleNodeId;
  @protected

  /// Recently toggled node ID for visual feedback.
  String? recentlyToggledNodeId;

  /// Port ID to focus on after incremental expansion/collapse.
  /// When set, the canvas pans to keep this port centred at the current
  /// zoom level instead of fitting the whole node.
  String? focusPortId;

  /// External hierarchy service from the parent application.
  /// Override in subclass to provide access to the widget's externalHierarchy.
  /// Returns null by default (no external hierarchy).
  @protected
  HierarchyService? get externalHierarchy {
    // Return the adapter's hierarchy if available
    if (schematicAdapter != null) {
      return schematicAdapter!.hierarchy;
    }
    return null;
  }

  /// Optional callback to look up a signal's value by wire name.
  ///
  /// Override in subclass (e.g., `EmbeddedSchematicViewer`) to provide
  /// snapshot values from the parent application. When non-null, the hover
  /// tooltip shows the value on a second line beneath the wire name.
  /// Returns null by default (standalone mode — no value lookup).
  @protected
  ({String value, bool computed, String signalId})? Function(String wireName)?
      get signalValueLookup => null;

  /// Optional callback to send selected signals to other viewers.
  ///
  /// Override in subclass (e.g., `EmbeddedSchematicViewer`) to forward
  /// signal paths to the parent application's cross-probe bus.
  @protected
  void Function(List<String> signalPaths)? get onSendSignals => null;

  /// Whether external widgets are listening for signals.
  ///
  /// Override in subclass to return `true` when the embedding context
  /// has external signal consumers (e.g. waveform viewer in devtools).
  @protected
  bool get hasExternalSignalListeners => false;

  /// Optional callback to navigate to a signal's source for a chosen
  /// [RohdSourceFormat].
  @protected
  GoToSourceCallback? get onGoToSource => null;

  /// Discovers which source formats are navigable for the current module.
  /// Uses cached module info (synchronous).
  @protected
  AvailableSourceFormats? get availableSourceFormats => null;

  /// Notifier for incoming signal paths from other viewers (cross-probing).
  ///
  /// Override in subclass to receive signal paths from the shared bus.
  @protected
  ValueNotifier<List<String>?>? get incomingSignalPaths => null;

  /// Optional `CrossProbeService` for cross-probing between viewers.
  ///
  /// Override in subclass (e.g. `EmbeddedSchematicViewer`) to enable
  /// the `CrossProbeButton` in the AppBar and wire signal selection to the
  /// shared channel.
  @protected
  CrossProbeService? get crossProbeService => null;

  /// Map of emoji to ASCII fallback symbols for when emojis aren't available.
  static const Map<String, String> emojiFallbacks = {
    '': '[D]', // Folder icon
    '🔄': '[R]', // Refresh icon
    '☀️': '[O]', // Sun icon
    '�': '[S]', // Sunrise icon
    '�🌙': '[*]', // Moon icon
    '🎨': '[P]', // Palette icon
    '❌': '[X]', // X icon
  };

  /// Check if an emoji font is available on the system.
  ///
  /// Delegates to the shared `hasEmojiFonts` utility in
  /// `platform/platform_emoji.dart` which caches the result after the
  /// first call so this is safe to call from build methods.
  static bool hasEmojiFonts() => platform_emoji.hasEmojiFonts();

  /// Returns an icon for cross-platform display.
  /// Uses emoji if fonts are available, native Flutter icons otherwise.
  /// On Linux, checks for actual emoji font availability.
  /// On other platforms, uses emoji with ASCII fallback in tooltip.
  Widget platformIcon(
    IconData nativeIcon,
    String emoji, {
    double? size,
    Color? color,
  }) {
    final fallbackText = emojiFallbacks[emoji] ?? emoji;
    final useEmoji = hasEmojiFonts();

    if (useEmoji) {
      // Use emoji on platforms with good emoji support
      return Tooltip(
        message: fallbackText,
        child: Text(
          emoji,
          style: TextStyle(fontSize: size ?? 16, color: color),
        ),
      );
    } else {
      // Use native Flutter icons as fallback
      return Tooltip(
        message: fallbackText,
        child: Icon(nativeIcon, size: size ?? 24, color: color),
      );
    }
  }

  /// Creates the engine used to compute ELK layouts.
  ///
  /// Subclasses can override this to provide a deterministic engine for a
  /// specialized host or widget test.
  @protected
  SchematicLayoutEngine createLayoutEngine() => createSchematicLayoutEngine();

  @override
  void initState() {
    super.initState();
    _layoutEngine = createLayoutEngine();
    loadInitialSchematic();
  }

  @override
  void dispose() {
    _layoutEngine?.dispose();
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<NetlistSchematicAdapter?>(
          'schematicAdapter',
          schematicAdapter,
        ),
      )
      ..add(DiagnosticsProperty<SchematicLayoutResult?>('layout', layout))
      ..add(StringProperty('schematicJson', schematicJson))
      ..add(StringProperty('fileName', fileName))
      ..add(StringProperty('error', error))
      ..add(DiagnosticsProperty<bool>('isLoading', isLoading))
      ..add(DiagnosticsProperty<bool>('isToggling', isToggling))
      ..add(StringProperty('pendingToggleNodeId', pendingToggleNodeId))
      ..add(StringProperty('recentlyToggledNodeId', recentlyToggledNodeId))
      ..add(StringProperty('focusPortId', focusPortId))
      ..add(
        DiagnosticsProperty<HierarchyService?>(
          'externalHierarchy',
          externalHierarchy,
        ),
      )
      ..add(
        DiagnosticsProperty<SchematicLayoutEngine?>(
          'layoutEngine',
          layoutEngine,
        ),
      )
      ..add(StringProperty('sessionId', sessionId))
      ..add(StringProperty('togglingLabel', togglingLabel))
      ..add(
        ObjectFlagProperty<
            ({bool computed, String signalId, String value})? Function(
              String wireName,
            )?>.has('signalValueLookup', signalValueLookup),
      )
      ..add(
        ObjectFlagProperty<void Function(List<String> signalPaths)?>.has(
          'onSendSignals',
          onSendSignals,
        ),
      )
      ..add(
        DiagnosticsProperty<bool>(
          'hasExternalSignalListeners',
          hasExternalSignalListeners,
        ),
      )
      ..add(
        ObjectFlagProperty<GoToSourceCallback?>.has(
          'onGoToSource',
          onGoToSource,
        ),
      )
      ..add(
        ObjectFlagProperty<AvailableSourceFormats?>.has(
          'availableSourceFormats',
          availableSourceFormats,
        ),
      )
      ..add(
        DiagnosticsProperty<ValueNotifier<List<String>?>?>(
          'incomingSignalPaths',
          incomingSignalPaths,
        ),
      )
      ..add(
        DiagnosticsProperty<CrossProbeService?>(
          'crossProbeService',
          crossProbeService,
        ),
      );
  }

  /// Override this to load the initial schematic.
  /// Called automatically in initState().
  void loadInitialSchematic();

  /// Handle reload button press.
  ///
  /// Override in subclasses to customize reload behavior (e.g., reload from
  /// disk via VS Code extension messaging). Default re-processes the current
  /// in-memory JSON.
  void handleReload() {
    if (schematicJson != null) {
      unawaited(computeLayout(schematicJson!));
    }
  }

  /// Compute layout from JSON data.
  ///
  /// Parses netlist JSON in Dart, then uses ELK for layout computation.
  /// When `expandAll` is true, all nodes are recursively expanded before
  /// the first layout pass, avoiding a visible collapse-then-expand redraw.
  ///
  /// Prefer using `expansionMode` instead of `expandAll`.  When
  /// `expansionMode` is provided, `expandAll` is ignored.
  Future<void> computeLayout(
    String jsonData, {
    bool expandAll = false,
    SchematicExpansionMode? expansionMode,
  }) async {
    final engine = _layoutEngine;
    if (engine == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        error = 'Layout engine not available';
        isLoading = false;
      });
      return;
    }

    try {
      if (kPerfLog) {
        debugPrint('[PERF] computeLayout ENTERED');
      }
      schematicJson = jsonData;
      SchematicLayoutResult layoutResult;

      // Yield a frame so the loading indicator can render before
      // the heavy synchronous parse + serialization work begins.
      if (mounted) {
        final completer = Completer<void>();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          completer.complete();
        });
        await completer.future;
        if (!mounted) {
          return;
        }
      }

      // Parse in Dart, serialize to JS format for ELK

      if (kPerfLog) {
        debugPrint('[PERF] JSON input size: ${jsonData.length} chars');
      }
      final parseStart = DateTime.now();

      // Parse netlist JSON with the unified adapter
      schematicAdapter = NetlistSchematicAdapter.fromJson(jsonData);

      final parseEnd = DateTime.now();
      if (kPerfLog) {
        debugPrint(
          '[PERF] NetlistSchematicAdapter.fromJson: '
          '${parseEnd.difference(parseStart).inMilliseconds} ms',
        );
      }

      // Resolve the effective expansion mode.
      // If expansionMode is provided, use it; otherwise fall back to the
      // deprecated expandAll boolean for backward compatibility.
      final effectiveMode = expansionMode ??
          (expandAll
              ? SchematicExpansionMode.fullyExpanded
              : SchematicExpansionMode.defaultView);

      // Apply the requested expansion to the in-memory graph before the
      // first ELK layout pass.
      _applyExpansionMode(effectiveMode);

      // Serialize to JS format and compute layout with timeout.
      // toJsGraph() handles all expansion states (collapsed, partial, full).
      final jsStart = DateTime.now();
      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final jsEnd = DateTime.now();
      if (kPerfLog) {
        debugPrint(
          '[PERF] toJsGraph: ${jsEnd.difference(jsStart).inMilliseconds} ms, '
          'elkGraph size: ${elkGraph.length} chars',
        );
      }

      // Wrap the native call with timeout.
      // QuickJS (used on Linux native) is significantly slower than
      // browser JS engines, so allow generous time for ELK layout.
      final elkStart = DateTime.now();
      if (kPerfLog) {
        debugPrint('[PERF] Starting ELK layout...');
      }
      layoutResult = await engine
          .computeLayoutFromElkGraph(elkGraph, sessionId: _sessionId)
          .timeout(const Duration(seconds: 60));
      final elkEnd = DateTime.now();
      if (kPerfLog) {
        debugPrint(
          '[PERF] ELK layout: ${elkEnd.difference(elkStart).inMilliseconds} ms',
        );
      }

      if (!mounted) {
        return;
      }

      if (layoutResult.hasError) {
        setState(() {
          error = 'Layout error: ${layoutResult.error}';
          isLoading = false;
        });
        return;
      }
      setState(() {
        layout = layoutResult;
        error = null;
        isLoading = false;
      });
    } on TimeoutException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        error = 'Schematic layout timed out (module too complex): $e';
        isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        error = 'Error computing layout: $e';
        isLoading = false;
      });
    }
  }

  /// Apply the given `SchematicExpansionMode` to the already-parsed
  /// `schematicAdapter`'s in-memory graph.
  ///
  /// Called once after `NetlistSchematicAdapter.fromJson()` and before
  /// `toJsGraph()` in `computeLayout`.  The adapter builder has already
  /// set the top module to blocks-only (the `defaultView` behaviour),
  /// so we undo/augment that as needed.
  void _applyExpansionMode(SchematicExpansionMode mode) {
    final adapter = schematicAdapter;
    if (adapter == null) {
      return;
    }
    final graph = adapter.schematic;
    final root = graph.root;

    switch (mode) {
      case SchematicExpansionMode.defaultView:
        // Already set by fromJson (top module in blocks-only mode).
        break;

      case SchematicExpansionMode.collapsed:
        // The adapter builder already put the top module into blocks-only
        // mode (partialChildIds set).  Partial children are not physically
        // moved — they're revealed during toJsGraph() serialization.
        // To collapse, simply clear the partial markers on every node.
        void clearPartials(LayoutNode node) {
          node
            ..partialChildIds = null
            ..partialHyperedgeIds = null;
          node.children.forEach(clearPartials);
          if (node.hiddenChildren != null) {
            node.hiddenChildren!.forEach(clearPartials);
          }
        }
        clearPartials(root);

      case SchematicExpansionMode.blocksOnly:
        // Expand all hierarchy blocks recursively, no wires.
        // The top is already in blocks-only; recursively apply to
        // the revealed children.
        root.children.toList().forEach((child) {
          if (child.isExpandable ||
              child.isExpanded ||
              child.isPartiallyExpanded) {
            graph.expandNonPrimitivesRecursive(child.id);
          }
        });
        // Also apply to children visible via partial expansion.
        final partialIds = root.partialChildIds;
        if (partialIds != null) {
          partialIds.toList().forEach(graph.expandNonPrimitivesRecursive);
        }

      case SchematicExpansionMode.fullyExpanded:
        // Fully expand all nodes with wires.
        void expandChild(LayoutNode child) {
          if (child.isExpandable && !child.isExpanded) {
            graph.toggleNodeRecursive(child.id);
          } else if (child.isExpanded) {
            // Collapse then re-expand to ensure all descendants are expanded.
            graph
              ..toggleNodeRecursive(child.id)
              ..toggleNodeRecursive(child.id);
          }
        }

        root.children.forEach(expandChild);
    }
  }

  /// Hook for subclasses that support incremental loading.
  ///
  /// Returns `true` if `nodeId`'s module is slim and a fetch would be needed.
  ///
  /// Synchronous — safe to call before showing a spinner.  Override in
  /// subclasses that support incremental loading.
  @protected
  bool needsConnectivity(String nodeId) => false;

  /// Called before graph mutations that require wire connectivity
  /// (node toggle, port expand, wire expand). Override to fetch
  /// connectivity data and rebuild the adapter. Returns `true` if
  /// the adapter was rebuilt.
  @protected
  Future<bool> ensureConnectivity(String nodeId) async => false;

  /// Handle node toggle (expand/collapse).
  ///
  /// Uses either Dart-first or JS-first toggle based on `useDartFirstParsing`.
  Future<SchematicLayoutResult?> handleNodeToggle(String nodeId) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null) {
      return null;
    }

    // Determine label before the toggle mutates state.
    final wasExpanded = schematicAdapter?.isExpanded(nodeId) ?? false;

    setState(() {
      isToggling = true;
      togglingLabel = wasExpanded ? 'Collapsing...' : 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    // Wait until the frame is painted and spinner animation starts
    // before beginning heavy processing
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;

    // Request visual updates during processing to keep spinner animating
    SchedulerBinding.instance.ensureVisualUpdate();

    // Ensure connectivity is available for this module before toggling.
    await ensureConnectivity(nodeId);

    try {
      SchematicLayoutResult newLayout;

      if (schematicAdapter == null) {
        if (!mounted) {
          return null;
        }
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
        return null;
      }

      // Toggle in Dart, then re-serialize for layout

      // Snapshot expansion state before mutating, so we can restore
      // exactly if ELK rejects the resulting graph (e.g. partial → full
      // fails, but a blind re-toggle would go full → collapsed instead).
      final preToggleSnapshot = schematicAdapter!.schematic.expansionSnapshot();

      // Toggle in the Dart-owned graph
      final toggled = schematicAdapter!.toggleNode(nodeId);
      if (!toggled) {
        if (!mounted) {
          return null;
        }
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
        return null;
      }

      // Re-serialize and compute layout
      final elkGraph = schematicAdapter!.schematic.toJsGraph();

      newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError) {
        if (!mounted) {
          return null;
        }
        // Restore to pre-toggle state so the adapter stays consistent
        // with the visible layout (which was not updated due to the error).
        schematicAdapter!.schematic.restoreExpansionSnapshot(preToggleSnapshot);
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
        return null;
      }

      if (!mounted) {
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        recentlyToggledNodeId = nodeId;
      });

      // Clear the recently toggled node after the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (!mounted) {
        return null;
      }
      setState(() {
        isToggling = false;
        pendingToggleNodeId = null;
      });
      return null;
    }
  }

  /// Handle collapsing a partially expanded node back to fully collapsed.
  ///
  /// Clears the partial expansion state and re-runs layout so the node
  /// returns to its collapsed appearance.
  Future<SchematicLayoutResult?> handleCollapsePartial(String nodeId) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Collapsing...';
      pendingToggleNodeId = nodeId;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final collapsed = schematicAdapter!.collapsePartialExpansion(nodeId);
      if (!collapsed) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle incremental port expansion.
  ///
  /// Reveals only the internal edges connected to `portId` on node `nodeId`,
  /// plus the submodules at the other end of those edges. This is the
  /// Dart-first path only (port expansion is not supported in JS-first mode).
  Future<SchematicLayoutResult?> handlePortExpand(
    String nodeId,
    String portId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    // Show the spinner only when a network fetch is actually needed.
    if (needsConnectivity(nodeId)) {
      setState(() {
        isToggling = true;
        togglingLabel = 'Expanding...';
        pendingToggleNodeId = nodeId;
      });
      // Yield to let the spinner frame paint before the heavy fetch.
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        completer.complete();
      });
      await completer.future;
      SchedulerBinding.instance.ensureVisualUpdate();
      // Fetch + rebuild adapter.
      await ensureConnectivity(nodeId);
    } else {
      // Already loaded — gate re-entry without triggering a repaint or
      // showing the spinner overlay.  Direct field mutation is safe here
      // because Dart is single-threaded: the gate is set synchronously
      // before the first await below.
      isToggling = true;
      pendingToggleNodeId = nodeId;
      await ensureConnectivity(nodeId); // fast no-op
    }

    final preExpandSnapshot = schematicAdapter!.schematic.expansionSnapshot();
    try {
      final expanded = schematicAdapter!.expandPort(nodeId, portId);
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        schematicAdapter!.schematic.restoreExpansionSnapshot(preExpandSnapshot);
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        // Focus on the specific port that was clicked so the canvas
        // pans to keep it centred at the current zoom level.
        focusPortId = portId;
        recentlyToggledNodeId = null; // port focus overrides node fit
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            focusPortId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      schematicAdapter!.schematic.restoreExpansionSnapshot(preExpandSnapshot);
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle incremental port expansion with pass-through traversal.
  ///
  /// Like `handlePortExpand` but continues through trivial gates (buffers,
  /// inverters, slicers, concatenators) until non-trivial children or
  /// external ports are reached.  Triggered by Shift+clicking a port
  /// marker in the schematic canvas.
  Future<SchematicLayoutResult?> handlePortExpandThrough(
    String nodeId,
    String portId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    if (needsConnectivity(nodeId)) {
      setState(() {
        isToggling = true;
        togglingLabel = 'Expanding...';
        pendingToggleNodeId = nodeId;
      });
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        completer.complete();
      });
      await completer.future;
      SchedulerBinding.instance.ensureVisualUpdate();
      await ensureConnectivity(nodeId);
    } else {
      isToggling = true;
      pendingToggleNodeId = nodeId;
      await ensureConnectivity(nodeId); // fast no-op
    }

    final preExpandSnapshot = schematicAdapter!.schematic.expansionSnapshot();
    try {
      final expanded = schematicAdapter!.expandPortThroughRecursive(
        nodeId,
        portId,
      );
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        schematicAdapter!.schematic.restoreExpansionSnapshot(preExpandSnapshot);
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = portId;
        recentlyToggledNodeId = null;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            focusPortId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      schematicAdapter!.schematic.restoreExpansionSnapshot(preExpandSnapshot);
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle port collapse (click on a boundary port with a visible wire).
  ///
  /// Reverse of `handlePortExpand`: removes the wire and connected trivial
  /// gates from partial expansion.
  Future<SchematicLayoutResult?> handlePortCollapse(
    String nodeId,
    String portId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Collapsing...';
      pendingToggleNodeId = nodeId;
    });

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      // Before collapsing, check if this is the last connection to the port
      // being collapsed and find the closest non-constant connected gate if so
      String? closestConnectedGateId;
      final oldEdges = layout?.edges ?? <SchematicEdgeData>[];

      // Count connections specifically to THIS PORT being collapsed
      var connectionsFromThisPort = 0;
      String? otherPortOnConnection;

      for (final edge in oldEdges) {
        // Check if this edge connects to the specific port being collapsed
        if (edge.sourcePort == portId) {
          connectionsFromThisPort++;
          otherPortOnConnection = edge.targetPort;
        } else if (edge.targetPort == portId) {
          connectionsFromThisPort++;
          otherPortOnConnection = edge.sourcePort;
        }
      }

      // Helper function to check if a gate is a constant (like 0x0, 0x1, etc.)
      bool isConstantGate(String? gateId) {
        if (gateId == null) {
          return false;
        }
        final node = schematicAdapter?.schematic.nodeMap[gateId];
        if (node == null) {
          return false;
        }
        return isConstantName(node.hwMeta.name);
      }

      // Helper function to find the closest non-constant gate by tracing
      // connections
      String? findNonConstantConnectedGate(String startPortId) {
        final visited = <String>{};
        final queue = <String>[startPortId];

        while (queue.isNotEmpty) {
          final currentPortId = queue.removeAt(0);
          if (visited.contains(currentPortId)) {
            continue;
          }
          visited.add(currentPortId);

          // Find the gate for this port
          String? currentGateId;
          try {
            final port = layout!.ports.firstWhere((p) => p.id == currentPortId);
            currentGateId = port.instanceId;
          } on Object catch (_) {
            continue;
          }

          // If this gate is not constant, return it
          if (!isConstantGate(currentGateId)) {
            return currentGateId;
          }

          // If it's constant, queue its connected ports
          for (final edge in oldEdges) {
            if (edge.sourcePort == currentPortId &&
                edge.targetPort != null &&
                !visited.contains(edge.targetPort)) {
              queue.add(edge.targetPort!);
            } else if (edge.targetPort == currentPortId &&
                edge.sourcePort != null &&
                !visited.contains(edge.sourcePort)) {
              queue.add(edge.sourcePort!);
            }
          }
        }

        return null; // No non-constant gate found
      }

      // If this port has only 1 connection, find the closest non-constant gate
      if (connectionsFromThisPort == 1 && otherPortOnConnection != null) {
        closestConnectedGateId = findNonConstantConnectedGate(
          otherPortOnConnection,
        );
      }

      // Use the new method that returns removed gate IDs for smart focus
      // recovery
      final (collapsed, removedGates) =
          schematicAdapter!.collapsePortWithRemoved(nodeId, portId);
      if (!collapsed) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      // Determine focus point for zoom after collapse.
      // Case 1: Original port still exists → focus on it
      // Case 2: Original gate was removed → find closest connected gate that
      // wasn't
      //         removed and focus on one of its ports
      // Case 3: Gates connected to the port were removed → find what those
      //         gates were connected to and focus on a surviving connection
      // Case 4: No good focus point → leave viewport where it was (implicit)
      String? newFocusPortId;
      final portStillExists = newLayout.ports.any((p) => p.id == portId);

      if (portStillExists) {
        // Port still exists—keep it in focus
        newFocusPortId = portId;
      } else if (removedGates.contains(nodeId)) {
        // The gate that owned this port was removed. Find what it was connected
        // to and focus on a gate that wasn't removed.
        String? bestConnectedPort;

        // Look at old edges to find what was connected to portId
        for (final edge in layout?.edges ?? <SchematicEdgeData>[]) {
          if (edge.sourcePort == portId) {
            bestConnectedPort = edge.targetPort;
            break;
          } else if (edge.targetPort == portId) {
            bestConnectedPort = edge.sourcePort;
            break;
          }
        }

        // If we found a connected port, check if it still exists and its gate
        // wasn't also removed
        if (bestConnectedPort != null) {
          SchematicPortData? connectedPort;
          try {
            connectedPort = newLayout.ports.firstWhere(
              (p) => p.id == bestConnectedPort,
            );
          } on Object catch (_) {
            // Port not found in new layout
            connectedPort = null;
          }
          if (connectedPort != null &&
              !removedGates.contains(connectedPort.instanceId)) {
            newFocusPortId = bestConnectedPort;
          }
        }
      } else if (removedGates.isNotEmpty) {
        // Gates connected to the collapsed port were removed. Find what those
        // removed gates were connected to and focus on a survivor.
        String? bestConnectedPort;
        final oldEdges = layout?.edges ?? <SchematicEdgeData>[];

        // Look at edges in the old layout to find what removed gates were
        // connected to
        for (final edge in oldEdges) {
          String? otherPortId;

          // Check if the source port belongs to a removed gate
          try {
            final sourcePort = newLayout.ports.firstWhere(
              (p) => p.id == edge.sourcePort,
            );
            if (removedGates.contains(sourcePort.instanceId)) {
              otherPortId = edge.targetPort;
            }
          } on Object catch (_) {
            // Source port not found in new layout
          }

          // Check if the target port belongs to a removed gate
          if (otherPortId == null) {
            try {
              final targetPort = newLayout.ports.firstWhere(
                (p) => p.id == edge.targetPort,
              );
              if (removedGates.contains(targetPort.instanceId)) {
                otherPortId = edge.sourcePort;
              }
            } on Object catch (_) {
              // Target port not found in new layout
            }
          }

          // If we found a port connected to a removed gate, check if it
          // still exists in the new layout
          if (otherPortId != null) {
            try {
              newLayout.ports.firstWhere((p) => p.id == otherPortId);
              // Found a port connected to a removed gate that still exists
              bestConnectedPort = otherPortId;
              break;
            } on Object catch (_) {
              // Port not found, continue searching
            }
          }
        }

        if (bestConnectedPort != null) {
          newFocusPortId = bestConnectedPort;
        }
      }

      // Case 5: This was the last connection - pan to th e closest connected
      // gate's port
      if (newFocusPortId == null &&
          closestConnectedGateId != null &&
          !removedGates.contains(closestConnectedGateId)) {
        try {
          final closestPort = newLayout.ports.firstWhere(
            (p) => p.instanceId == closestConnectedGateId,
          );
          newFocusPortId = closestPort.id;
        } on Object catch (_) {
          // No port found in closest gate
        }
      }

      // When port-level focus is unavailable, zoom to the parent
      // boundary so the collapsed block is visible in context.
      final parentId = schematicAdapter!.schematic.nodeMap[nodeId]?.parent?.id;

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        if (newFocusPortId != null) {
          focusPortId = newFocusPortId;
        }
        recentlyToggledNodeId = parentId ?? nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            focusPortId = null;
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle recursive port collapse (Shift+click on a boundary port).
  ///
  /// Reverse of `handlePortExpandThrough`: removes the wire and connected
  /// trivial gates recursively across module boundaries.
  ///
  /// Implements smart focus recovery: if collapsing is the last connection
  /// to the original port, finds the closest non-constant connected gate to
  /// focus on after collapse, similar to port collapse behavior.
  Future<SchematicLayoutResult?> handlePortCollapseThrough(
    String nodeId,
    String portId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Collapsing...';
      pendingToggleNodeId = nodeId;
    });

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      // Before collapsing, check if this is the last connection to the port
      // and find the closest non-constant connected gate for focus recovery
      String? closestConnectedGateId;
      final oldEdges = layout?.edges ?? <SchematicEdgeData>[];

      // Count connections specifically to THIS PORT being collapsed
      var connectionsFromThisPort = 0;
      String? otherPortOnConnection;

      for (final edge in oldEdges) {
        // Check if this edge connects to the specific port being collapsed
        if (edge.sourcePort == portId) {
          connectionsFromThisPort++;
          otherPortOnConnection = edge.targetPort;
        } else if (edge.targetPort == portId) {
          connectionsFromThisPort++;
          otherPortOnConnection = edge.sourcePort;
        }
      }

      // Helper function to check if a gate is a constant
      bool isConstantGate(String? gateId) {
        if (gateId == null) {
          return false;
        }
        final node = schematicAdapter?.schematic.nodeMap[gateId];
        if (node == null) {
          return false;
        }
        return isConstantName(node.hwMeta.name);
      }

      // Helper function to find the closest non-constant gate by tracing
      // connections
      String? findNonConstantConnectedGate(String startPortId) {
        final visited = <String>{};
        final queue = <String>[startPortId];

        while (queue.isNotEmpty) {
          final currentPortId = queue.removeAt(0);
          if (visited.contains(currentPortId)) {
            continue;
          }
          visited.add(currentPortId);

          // Find the gate for this port
          String? currentGateId;
          try {
            final port = layout!.ports.firstWhere((p) => p.id == currentPortId);
            currentGateId = port.instanceId;
          } on Object catch (_) {
            continue;
          }

          // If this gate is not constant, return it
          if (!isConstantGate(currentGateId)) {
            return currentGateId;
          }

          // If it's constant, queue its connected ports
          for (final edge in oldEdges) {
            if (edge.sourcePort == currentPortId &&
                edge.targetPort != null &&
                !visited.contains(edge.targetPort)) {
              queue.add(edge.targetPort!);
            } else if (edge.targetPort == currentPortId &&
                edge.sourcePort != null &&
                !visited.contains(edge.sourcePort)) {
              queue.add(edge.sourcePort!);
            }
          }
        }

        return null; // No non-constant gate found
      }

      // If this port has only 1 connection, find the closest non-constant gate
      if (connectionsFromThisPort == 1 && otherPortOnConnection != null) {
        closestConnectedGateId = findNonConstantConnectedGate(
          otherPortOnConnection,
        );
      }

      final collapsed = schematicAdapter!.collapsePortRecursive(nodeId, portId);
      if (!collapsed) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      // Determine focus point for pan after collapse. Case 1: Original port
      // still exists → focus on it Case 2: Was last connection and found a
      // close non-constant gate → focus there Case 3: No good focus point →
      // keep viewport where it was
      String? newFocusPortId;
      final portStillExists = newLayout.ports.any((p) => p.id == portId);

      if (portStillExists) {
        // Port still exists—keep it in focus
        newFocusPortId = portId;
      } else if (closestConnectedGateId != null) {
        // Port was deleted but we found a non-constant gate to focus on
        // Find a port on that gate to focus on
        try {
          final gatePort = newLayout.ports.firstWhere(
            (p) => p.instanceId == closestConnectedGateId,
          );
          newFocusPortId = gatePort.id;
        } on Object catch (_) {
          // Port not found in closest gate
        }
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        if (newFocusPortId != null) {
          focusPortId = newFocusPortId;
        }
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            focusPortId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle "expand non-primitives" button click.
  ///
  /// Reveals all non-primitive (submodule) hidden children of `nodeId`
  /// via partial expansion. Uses the same mechanism as port expansion
  /// but targets all submodules at once.
  Future<SchematicLayoutResult?> handleExpandNonPrimitives(
    String nodeId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final expanded = schematicAdapter!.expandNonPrimitives(nodeId);
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        // Fit the newly expanded node in view.
        focusPortId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle "convert to blocks-only" button click on a fully expanded node.
  ///
  /// Collapses the node and re-expands only non-primitive children
  /// without edges.
  Future<SchematicLayoutResult?> handleConvertToBlocksOnly(
    String nodeId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Collapsing...';
      pendingToggleNodeId = nodeId;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final converted = schematicAdapter!.convertToBlocksOnly(nodeId);
      if (!converted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Recursive version of `handleNodeToggle` (Shift+click).
  ///
  /// Expands/collapses the node and all descendant submodules.
  Future<SchematicLayoutResult?> handleNodeToggleRecursive(
    String nodeId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    // Determine label before the toggle mutates state.
    final wasExpanded = schematicAdapter!.isExpanded(nodeId);
    final wasPartiallyExpanded =
        schematicAdapter!.schematic.nodeMap[nodeId]?.isPartiallyExpanded ??
            false;

    setState(() {
      isToggling = true;
      togglingLabel = (wasExpanded && !wasPartiallyExpanded)
          ? 'Collapsing...'
          : 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final toggled = schematicAdapter!.toggleNodeRecursive(nodeId);
      if (!toggled) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      // When collapsing, zoom to the parent boundary; when expanding,
      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Recursive version of `handleExpandNonPrimitives` (Shift+click).
  ///
  /// Expands non-primitive children down the full hierarchy.
  Future<SchematicLayoutResult?> handleExpandNonPrimitivesRecursive(
    String nodeId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final expanded = schematicAdapter!.expandNonPrimitivesRecursive(nodeId);
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Recursive version of `handleConvertToBlocksOnly` (Shift+click).
  ///
  /// Converts to blocks-only mode down the full hierarchy.
  Future<SchematicLayoutResult?> handleConvertToBlocksOnlyRecursive(
    String nodeId,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Collapsing...';
      pendingToggleNodeId = nodeId;
    });

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final converted = schematicAdapter!.convertToBlocksOnlyRecursive(nodeId);
      if (!converted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle expanding a specific child by name for search navigation.
  ///
  /// Partially reveals only `childName` inside `nodeId` (plus its
  /// connecting hyperedges). Used by the search routine to walk the
  /// hierarchy without fully expanding every level.
  Future<SchematicLayoutResult?> handleExpandChild(
    String nodeId,
    String childName,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    try {
      final expanded = schematicAdapter!.expandChild(nodeId, childName);
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Batch-expand an entire hierarchy path in a single layout cycle.
  ///
  /// Applies all graph mutations (expandChild at each level, and
  /// optionally expandWire at the leaf) **before** serialising and
  /// computing layout. This avoids the N × (toJsGraph + ELK + setState)
  /// overhead incurred by expanding one level at a time.
  ///
  /// `pathSegments` are instance names from top to bottom.
  /// If `targetWireName` is non-null the last segment is treated as
  /// the container of that wire; otherwise it is the target module.
  Future<SchematicLayoutResult?> handleExpandPath(
    List<String> pathSegments, {
    String? targetWireName,
  }) async {
    if (isToggling || pathSegments.isEmpty) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Expanding...';
      pendingToggleNodeId = pathSegments.last;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    // Fetch connectivity only when a wire needs to be revealed at the
    // leaf. Path-only expansion (finding a module) never needs wires.
    if (targetWireName != null) {
      // pathSegments are instance names (e.g. 'ch0') but
      // ensureConnectivity expects a node address (e.g. '0.0').
      // Resolve through the schematic graph.
      final nodeId = schematicAdapter!.schematic.resolvePathToNodeId(
        pathSegments,
      );
      if (nodeId != null) {
        await ensureConnectivity(nodeId);
      }
    }

    try {
      final changed = schematicAdapter!.expandPath(
        pathSegments,
        targetWireName: targetWireName,
      );
      if (!changed) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = null;
        recentlyToggledNodeId = null;
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Handle expanding a node to reveal a specific wire (hyperedge) by name.
  ///
  /// Partially reveals only the child modules connected by `wireName`
  /// inside `nodeId`, plus the wire itself. Used by the search routine
  /// to show a wire without fully expanding the containing module.
  Future<SchematicLayoutResult?> handleExpandWire(
    String nodeId,
    String wireName,
  ) async {
    if (isToggling) {
      return null;
    }
    final engine = _layoutEngine;
    if (engine == null || schematicAdapter == null) {
      return null;
    }

    setState(() {
      isToggling = true;
      togglingLabel = 'Expanding...';
      pendingToggleNodeId = nodeId;
    });

    // Let the spinner appear before heavy processing.
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete();
    });
    await completer.future;
    SchedulerBinding.instance.ensureVisualUpdate();

    // Ensure connectivity for the module containing the wire.
    await ensureConnectivity(nodeId);

    try {
      final expanded = schematicAdapter!.expandWire(nodeId, wireName);
      if (!expanded) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      final elkGraph = schematicAdapter!.schematic.toJsGraph();
      final newLayout = await engine.computeLayoutFromElkGraph(
        elkGraph,
        sessionId: _sessionId,
      );

      if (newLayout.hasError || !mounted) {
        if (mounted) {
          setState(() {
            isToggling = false;
            pendingToggleNodeId = null;
          });
        }
        return null;
      }

      setState(() {
        layout = newLayout;
        isToggling = false;
        pendingToggleNodeId = null;
        focusPortId = null;
        recentlyToggledNodeId = nodeId;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            recentlyToggledNodeId = null;
          });
        }
      });

      return newLayout;
    } on Exception {
      if (mounted) {
        setState(() {
          isToggling = false;
          pendingToggleNodeId = null;
        });
      }
      return null;
    }
  }

  /// Set loading state and optional error message.
  void setLoading({required bool loading, String? errorMessage}) {
    if (!mounted) {
      return;
    }
    setState(() {
      isLoading = loading;
      error = errorMessage;
    });
  }

  /// Set the schematic layout directly (e.g., from synthesized data).
  void setLayout(SchematicLayoutResult newLayout) {
    if (!mounted) {
      return;
    }
    setState(() {
      layout = newLayout;
      error = null;
    });
  }

  /// Set file name.
  void setFileName(String? name) {
    if (!mounted) {
      return;
    }
    setState(() {
      fileName = name;
    });
  }

  /// Load schematic from asset bundle.
  Future<void> loadSchematicFromAsset(
    String assetPath, {
    String? displayName,
  }) async {
    setLoading(loading: true);

    try {
      final jsonData = await rootBundle.loadString(assetPath);
      if (displayName != null) {
        setFileName(displayName);
      }
      await computeLayout(jsonData);
    } on Exception catch (e) {
      setLoading(loading: false, errorMessage: 'Failed to load asset: $e');
    }
  }

  /// Load schematic from file picker.
  ///
  /// Uses `file_selector` which works correctly on Linux, macOS, Windows, and
  /// web — unlike file_picker which has issues on Linux GTK.
  Future<void> loadSchematicFromFile() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'JSON netlists',
        extensions: <String>['json'],
      );
      final xfile = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
      if (xfile == null) {
        return;
      }

      setLoading(loading: true);
      if (kPerfLog) {
        debugPrint('[PERF] loadSchematicFromFile: reading ${xfile.name}...');
      }
      final jsonData = await xfile.readAsString();
      if (kPerfLog) {
        debugPrint(
          '[PERF] loadSchematicFromFile: read ${jsonData.length} chars, '
          'calling computeLayout...',
        );
      }
      setFileName(xfile.name);
      await computeLayout(jsonData);
    } on Exception catch (e) {
      if (kPerfLog) {
        debugPrint('[PERF] loadSchematicFromFile: EXCEPTION: $e');
      }
      setLoading(loading: false, errorMessage: 'Failed to load file: $e');
    }
  }

  /// Build a standard AppBar with configurable components.
  ///
  /// This method provides a consistent AppBar across different viewer
  /// implementations while allowing each to customize which features to show.
  /// Delegates to the shared `SchematicAppBar` widget.
  PreferredSizeWidget buildAppBar({
    required BuildContext context,
    bool showFileNameBadge = false,
    bool showStats = false,
    bool showFilePicker = false,
    bool showReload = true,
    PreferredSizeWidget? bottom,
    bool? appBarPinned,
    ValueChanged<bool>? onAppBarPinnedChanged,
  }) {
    // Build the list of leading actions passed to SchematicAppBar.
    // Each action uses BlocBuilder internally when it needs theme info.
    final leadingActions = <Widget>[
      // Node/Edge count statistics
      if (showStats && layout != null)
        BlocBuilder<SchematicThemeCubit, SchematicThemeMode>(
          builder: (context, themeMode) {
            final isDark = themeMode == SchematicThemeMode.dark;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF252526) : Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Modules: ${layout!.instances.length}  | '
                ' Signals: ${layout!.edges.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            );
          },
        ),
      // File picker button
      if (showFilePicker)
        Tooltip(
          message: 'Open JSON file',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: loadSchematicFromFile,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: platformIcon(Icons.folder_open, '📁', size: 18),
              ),
            ),
          ),
        ),
      // Reload button
      if (showReload)
        Tooltip(
          message: 'Reload current schematic',
          child: MouseRegion(
            cursor: schematicJson != null
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            child: GestureDetector(
              onTap: schematicJson != null ? handleReload : null,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Opacity(
                  opacity: schematicJson != null ? 1.0 : 0.5,
                  child: platformIcon(Icons.refresh, '🔄', size: 18),
                ),
              ),
            ),
          ),
        ),
    ];

    return SchematicAppBar(
      fileName: showFileNameBadge ? fileName : null,
      leadingActions: leadingActions,
      crossProbeService: crossProbeService,
      bottom: bottom,
      appBarPinned: appBarPinned,
      onAppBarPinnedChanged: onAppBarPinnedChanged,
    );
  }

  /// Build the schematic canvas with theme support.
  Widget buildSchematicCanvas({Color? backgroundColor, Key? canvasKey}) {
    if (layout == null) {
      return const SizedBox.shrink();
    }

    return BlocBuilder<SchematicThemeCubit, SchematicThemeMode>(
      builder: (context, themeMode) {
        final isDarkMode = themeMode == SchematicThemeMode.dark;
        final spinnerColor = isDarkMode ? Colors.white : Colors.black87;
        final textColor = isDarkMode ? Colors.white : Colors.black87;

        final canvas = SchematicCanvas(
          key: canvasKey,
          layout: layout!,
          netlistJson: schematicJson,
          externalHierarchy: externalHierarchy,
          colorScheme: isDarkMode
              ? SchematicColorScheme.dark
              : SchematicColorScheme.light,
          onNodeToggle: handleNodeToggle,
          onPortExpand: handlePortExpand,
          onPortExpandThrough: handlePortExpandThrough,
          onPortCollapse: handlePortCollapse,
          onPortCollapseThrough: handlePortCollapseThrough,
          onCollapsePartial: handleCollapsePartial,
          onExpandNonPrimitives: handleExpandNonPrimitives,
          onConvertToBlocksOnly: handleConvertToBlocksOnly,
          onNodeToggleRecursive: handleNodeToggleRecursive,
          onExpandNonPrimitivesRecursive: handleExpandNonPrimitivesRecursive,
          onConvertToBlocksOnlyRecursive: handleConvertToBlocksOnlyRecursive,
          onExpandChild: handleExpandChild,
          onExpandWire: handleExpandWire,
          onExpandPath: handleExpandPath,
          signalNameForPort: (nodeId, portId) =>
              schematicAdapter?.schematic.signalNameForPort(nodeId, portId),
          directDriverSignalPath: (wireName, scopePath) => schematicAdapter
              ?.schematic
              .directDriverSignalPath(wireName, scopePath),
          pendingToggleNodeId: pendingToggleNodeId,
          recentlyToggledNodeId: recentlyToggledNodeId,
          focusPortId: focusPortId,
          isDimmed: isToggling,
          signalValueLookup: signalValueLookup,
          onSendSignals: onSendSignals,
          hasExternalSignalListeners: hasExternalSignalListeners,
          onGoToSource: onGoToSource,
          availableSourceFormats: availableSourceFormats,
          incomingSignalPaths: incomingSignalPaths,
        );

        // Build the loading overlay — a small non-blocking corner badge
        // so the schematic stays visible while the layout recomputes.
        Widget buildLoadingOverlay() => Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? Colors.black.withValues(alpha: 0.65)
                        : Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          color: spinnerColor,
                          strokeWidth: 2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        togglingLabel,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            );

        // Wrap in container with optional background color
        if (backgroundColor != null) {
          return ColoredBox(
            color: backgroundColor,
            child: Stack(
              children: [canvas, if (isToggling) buildLoadingOverlay()],
            ),
          );
        }

        // Return canvas with loading overlay
        return Stack(children: [canvas, if (isToggling) buildLoadingOverlay()]);
      },
    );
  }

  /// Build standard loading indicator.
  Widget buildLoadingIndicator({String message = 'Loading schematic...'}) =>
      Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white54),
            const SizedBox(height: 16),
            Text(message, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );

  /// Build standard error display.
  Widget buildErrorDisplay() {
    if (error == null) {
      return const SizedBox.shrink();
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('⚠️', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 16),
          const Text('Error', style: TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  /// Build empty state display.
  Widget buildEmptyState({
    required String title,
    required String subtitle,
    Widget? action,
  }) =>
      Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📄',
                style: TextStyle(fontSize: 64, color: Colors.white38)),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      );
}
