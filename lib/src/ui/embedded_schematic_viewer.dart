// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// embedded_schematic_viewer.dart
// Minimal schematic viewer for embedding in other UIs (no AppBar/Scaffold).
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show Completer, unawaited;
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show
        AvailableSourceFormats,
        CrossProbeService,
        GoToSourceCallback,
        RohdSourceFormat,
        resolveNavigableFormats;
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_graph.dart';
import 'package:rohd_schematic_viewer/src/services/hierarchy_schematic_synthesizer.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_extension_client.dart'
    show RohdExtensionClient, RohdModuleInfo;
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_dump_stub.dart'
    if (dart.library.js_interop) 'package:rohd_schematic_viewer/src/ui/schematic_dump_web.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_expansion_mode.dart';

/// Resolve a pathname to a `HierarchyOccurrence` via address lookup.
HierarchyOccurrence? _resolveNode(HierarchyService hs, String pathname) {
  final addr = OccurrenceAddress.tryFromPathname(pathname, hs.root);
  if (addr == null) {
    return null;
  }
  return hs.occurrenceByAddress(addr);
}

/// Embedded schematic viewer that loads from a bundled asset or provided JSON.
/// No AppBar, no Scaffold - just the schematic canvas for embedding.
///
/// Use this widget when you need to embed a schematic viewer in a larger UI
/// (e.g., in DevTools tabs, embedded panels, etc.).
///
/// When `externalHierarchy` is provided, the schematic viewer will use the
/// shared hierarchy from the parent application instead of loading its own.
/// This enables synchronized selection across different viewers.
class EmbeddedSchematicViewer extends StatefulWidget {
  /// Asset path to load the schematic from.
  /// Ignored if `schematicJson` or `netlistJsonMap` is provided.
  final String? assetPath;

  /// Schematic JSON data to render directly (as a JSON string).
  /// If provided, `assetPath` is ignored.
  final String? schematicJson;

  /// Schematic JSON data as a Map (parsed from ROHD interface).
  /// Preferred over `schematicJson` when available.
  /// If provided, both `schematicJson` and `assetPath` are ignored.
  final Map<String, dynamic>? netlistJsonMap;

  /// Initial theme mode for the schematic viewer.
  /// When provided, the embedded viewer will start with this theme mode.
  final SchematicThemeMode? initialThemeMode;

  /// External hierarchy service from the parent application.
  /// When provided, the schematic viewer uses this instead of loading its own.
  /// This enables shared state across DevTools, Wave Viewer, and Schematic.
  final HierarchyService? externalHierarchy;

  /// Callback when a module is selected in the schematic.
  /// The parent can use this to sync selection with other viewers.
  final ValueChanged<HierarchyOccurrence?>? onModuleSelected;

  /// The currently selected module from the parent application.
  /// When this changes, the schematic will update to show this module as root.
  final HierarchyOccurrence? selectedModule;

  /// Whether the schematic tab is currently visible to the user.
  /// When false, expensive layout computations are deferred until visible.
  /// This prevents the schematic from blocking the UI when the waveform
  /// (or another tab) is active.
  final bool isVisible;

  /// Optional callback to look up a signal's current value by wire name.
  ///
  /// When provided (embedded/DevTools mode), the hover tooltip shows the
  /// signal value on a second line beneath the wire name. When null
  /// (standalone mode), only the wire name is shown.
  final ({String value, bool computed, String signalId})? Function(
    String wireName,
  )? signalValueLookupFn;

  /// Optional callback to fetch full schematic data for a single module.
  ///
  /// Used for incremental loading: when `netlistJsonMap` contains
  /// hierarchy-slim data (modules with empty netnames/connections), the
  /// viewer calls this to fetch full connectivity on demand as the user
  /// expands modules. Returns a JSON map
  /// `{"DefinitionName": { ports, cells, netnames }}` or `null`.
  final Future<Map<String, dynamic>?> Function(String definitionName)?
      fetchModuleNetlist;

  /// Called after incremental module fetches enrich the netlist JSON.
  ///
  /// The enriched JSON map (with full cell connectivity) is passed so the
  /// parent can re-create evaluators that depend on complete netlist data.
  final ValueChanged<Map<String, dynamic>>? onNetlistEnriched;

  /// Default asset path used when neither assetPath nor schematicJson is
  /// provided.
  static const String defaultAssetPath = 'assets/rohd_schematic.json';

  /// Callback when user wants to send selected signals to other viewers.
  final void Function(List<String> signalPaths)? onSendSignals;

  /// Whether external widgets (e.g. waveform viewer) are listening for
  /// signals.  When `false`, the "Send Signals" context-menu item is hidden.
  /// Defaults to `false` (most embeddings don't have external listeners).
  final bool hasExternalSignalListeners;

  /// Callback when user wants to navigate to a signal's source for a chosen
  /// [RohdSourceFormat].
  final GoToSourceCallback? onGoToSourceCallback;

  /// Notifier for incoming signal paths from other viewers (cross-probing).
  ///
  /// When the value changes, the schematic viewer highlights the
  /// corresponding wires.
  final ValueNotifier<List<String>?>? incomingSignalPaths;

  /// Optional `CrossProbeService` for cross-probing between viewers.
  ///
  /// When provided, overrides `onSendSignals`, `incomingSignalPaths`, and
  /// `hasExternalSignalListeners` with service-backed equivalents so the
  /// caller only needs to pass the service instead of wiring three separate
  /// callbacks.

  final CrossProbeService? crossProbeService;

  /// Optional ROHD extension client for handshaking.
  ///
  /// When provided, the viewer queries the extension for available source
  /// formats whenever the selected module changes.  The "Go to ROHD" and
  /// "Go to SV" context-menu items are shown only for the formats the
  /// extension reports as available for the current module.
  ///
  /// Supply a `FlcExtensionClient` in DevTools mode, a
  /// `VscodeSchematicExtensionClient` in VS Code webview mode, or leave
  /// `null` / omit to show all go-to options unconditionally.
  final RohdExtensionClient? extensionClient;

  /// Controls the initial expansion state after loading.
  ///
  /// Defaults to `SchematicExpansionMode.defaultView` (top module shows
  /// non-primitive sub-modules as blocks, no wires).
  final SchematicExpansionMode initialExpansionMode;

  /// Constructor for `EmbeddedSchematicViewer`.
  const EmbeddedSchematicViewer({
    super.key,
    this.assetPath,
    this.schematicJson,
    this.netlistJsonMap,
    this.initialThemeMode,
    this.externalHierarchy,
    this.onModuleSelected,
    this.selectedModule,
    this.isVisible = true,
    this.signalValueLookupFn,
    this.fetchModuleNetlist,
    this.onNetlistEnriched,
    this.onSendSignals,
    this.hasExternalSignalListeners = false,
    this.onGoToSourceCallback,
    this.incomingSignalPaths,
    this.crossProbeService,
    this.extensionClient,
    this.initialExpansionMode = SchematicExpansionMode.defaultView,
  });

  @override
  State<EmbeddedSchematicViewer> createState() =>
      _EmbeddedSchematicViewerState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('assetPath', assetPath))
      ..add(StringProperty('schematicJson', schematicJson))
      ..add(
        DiagnosticsProperty<Map<String, dynamic>?>(
          'netlistJsonMap',
          netlistJsonMap,
        ),
      )
      ..add(
        EnumProperty<SchematicThemeMode?>('initialThemeMode', initialThemeMode),
      )
      ..add(
        DiagnosticsProperty<HierarchyService?>(
          'externalHierarchy',
          externalHierarchy,
        ),
      )
      ..add(
        ObjectFlagProperty<ValueChanged<HierarchyOccurrence?>?>.has(
          'onModuleSelected',
          onModuleSelected,
        ),
      )
      ..add(
        DiagnosticsProperty<HierarchyOccurrence?>(
          'selectedModule',
          selectedModule,
        ),
      )
      ..add(DiagnosticsProperty<bool>('isVisible', isVisible))
      ..add(
        ObjectFlagProperty<
            ({String value, bool computed, String signalId})? Function(
                String)?>.has('signalValueLookupFn', signalValueLookupFn),
      )
      ..add(
        ObjectFlagProperty<Future<Map<String, dynamic>?> Function(String)?>.has(
          'fetchModuleNetlist',
          fetchModuleNetlist,
        ),
      )
      ..add(
        ObjectFlagProperty<ValueChanged<Map<String, dynamic>>?>.has(
          'onNetlistEnriched',
          onNetlistEnriched,
        ),
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
          'onGoToSourceCallback',
          onGoToSourceCallback,
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
      )
      ..add(
        DiagnosticsProperty<RohdExtensionClient?>(
          'extensionClient',
          extensionClient,
        ),
      )
      ..add(
        EnumProperty<SchematicExpansionMode>(
          'initialExpansionMode',
          initialExpansionMode,
        ),
      );
  }
}

/// Cached module state: the expensive layout result, the cheap JSON
/// string (for rebuilding the adapter), the user's expansion state,
/// and the last pan/zoom position.
class _CachedModule {
  final SchematicLayoutResult layout;
  final String jsonString;
  final ExpansionSnapshot expansionSnapshot;
  final Offset? viewOffset;
  final double? viewScale;
  _CachedModule(
    this.layout,
    this.jsonString,
    this.expansionSnapshot, {
    this.viewOffset,
    this.viewScale,
  });
}

class _EmbeddedSchematicViewerState
    extends BaseSchematicViewerState<EmbeddedSchematicViewer> {
  static const bool _cachingEnabled = true;

  // Private state for tracking current module
  // Track current root module for selection-based navigation
  String? _currentModuleId;

  // Cache of computed layouts + expansion state per module.
  // Key is netlist module key (class name) or instance ID (for synthesis).
  // The expensive ELK layout is cached; on restore we show it instantly
  // and rebuild the adapter with saved expansion state in the background.
  final Map<String, _CachedModule> _moduleCache = {};

  // Mapping from hierarchy instance ID (e.g., 'dut') to module key
  // (e.g., 'FilterBank'). Built when both the netlist JSON
  // and hierarchy are available.
  final Map<String, String> _instanceIdToModuleKey = {};

  /// Raw incoming signal paths buffered because `_currentModuleId` was null
  /// when they arrived.  Replayed after `_selectModule` sets the ID.
  List<String>? _pendingIncomingRaw;

  // Deferred module selection when the schematic tab is not visible.
  // Stored here so we can process it when the tab becomes visible,
  // avoiding expensive ELK layout work while the user is on another tab.
  HierarchyOccurrence? _pendingModule;
  bool _hasPendingModule = false;

  // Guards against _selectModule being called while the initial async
  // _loadFromJsonMap is still running. Without this, didUpdateWidget can
  // fire a _selectModule for the root before the cache and instance→moduleKey
  // mapping are populated, causing _extractAndComputeFromJson to overwrite
  // the expanded layout with a single collapsed block.
  bool _initialLoadInProgress = false;

  // Tracks which nodes are user-expanded in light-synthesis mode.
  // Light synthesis has no schematicAdapter, so expansion state is tracked
  // here and each toggle triggers a full re-synthesis pass.
  // Keyed by the current module scope (null = root view).
  final Map<String?, Set<String>> _lightSynthExpandedNodes = {};

  // Memoize the theme cubit to avoid recreating on every rebuild
  late final SchematicThemeCubit _themeCubit;

  // Key for accessing the SchematicCanvas state (pan/zoom read/write)
  final GlobalKey<SchematicCanvasState> _canvasKey =
      GlobalKey<SchematicCanvasState>();

  @override
  HierarchyService? get externalHierarchy {
    // When the schematicAdapter is available, use its hierarchy.
    // If an external hierarchy was passed to fromJson(), the adapter
    // already holds the shared instance (no duplicate tree).
    // Otherwise it falls back to its own internally-built hierarchy.
    if (schematicAdapter != null) {
      return schematicAdapter!.hierarchy;
    }
    // Fall back to externally-provided hierarchy (e.g., hierarchy-only mode
    // without schematic JSON).
    return widget.externalHierarchy;
  }

  @override
  ({String value, bool computed, String signalId})? Function(String wireName)?
      get signalValueLookup => widget.signalValueLookupFn;

  @override
  void Function(List<String> signalPaths)? get onSendSignals {
    final service = widget.crossProbeService;
    if (service != null) {
      // Service path: translate def-name paths → instance paths, then
      // broadcast.
      return (paths) {
        final translated = paths.map(_defPathToInstancePath).toList();
        debugPrint(
          '[EmbeddedSchematicViewer] onSendSignals (service): '
          '$paths → $translated',
        );
        service.send(translated, source: 'schematic');
      };
    }
    final outer = widget.onSendSignals;
    if (outer == null) {
      return null;
    }
    // Wrap the callback: translate definition-name-based paths from the
    // canvas into instance-path-based paths before putting them on the bus.
    return (paths) {
      final translated = paths.map(_defPathToInstancePath).toList();
      debugPrint(
        '[EmbeddedSchematicViewer] onSendSignals translation: '
        '$paths → $translated',
      );
      outer(translated);
    };
  }

  @override
  bool get hasExternalSignalListeners =>
      widget.crossProbeService != null || widget.hasExternalSignalListeners;

  @override
  CrossProbeService? get crossProbeService => widget.crossProbeService;

  // Local notifier fed to the canvas.  We translate incoming instance-based
  // paths into definition-name-based paths that the canvas recognises.
  ValueNotifier<List<String>?>? _translatedIncoming;

  @override
  ValueNotifier<List<String>?>? get incomingSignalPaths => _translatedIncoming;

  void _onRawIncomingSignals() {
    final raw = widget.incomingSignalPaths?.value;
    if (raw == null || raw.isEmpty) {
      _pendingIncomingRaw = null;
      _translatedIncoming?.value = raw;
      return;
    }
    // If the module scope is not set yet and we have an external hierarchy,
    // buffer the raw paths and return.  They will be replayed from
    // _selectModule once _currentModuleId is assigned.
    if (_currentModuleId == null && widget.externalHierarchy != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] incoming buffered '
        '(module not loaded): $raw',
      );
      _pendingIncomingRaw = raw;
      return;
    }
    _pendingIncomingRaw = null;
    if (_currentModuleId != null) {
      final translated = raw.map(_instancePathToDefPath).toList();
      debugPrint(
        '[EmbeddedSchematicViewer] incoming translation: '
        '$raw → $translated',
      );
      _translatedIncoming?.value = translated;
    } else {
      // No hierarchy context — pass through untranslated.
      debugPrint(
        '[EmbeddedSchematicViewer] incoming pass-through '
        '(no hierarchy): $raw',
      );
      _translatedIncoming?.value = raw;
    }
  }

  /// Listener for `CrossProbeService.incomingSignals` — same translation
  /// logic as `_onRawIncomingSignals` but reads from the service.
  void _onServiceIncomingSignals() {
    final raw = widget.crossProbeService?.incomingSignals.value;
    if (raw == null || raw.isEmpty) {
      _pendingIncomingRaw = null;
      _translatedIncoming?.value = raw;
      return;
    }
    if (_currentModuleId == null && widget.externalHierarchy != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] service incoming buffered '
        '(module not loaded): $raw',
      );
      _pendingIncomingRaw = raw;
      return;
    }
    _pendingIncomingRaw = null;
    if (_currentModuleId != null) {
      final translated = raw.map(_instancePathToDefPath).toList();
      debugPrint(
        '[EmbeddedSchematicViewer] service incoming: $raw → $translated',
      );
      _translatedIncoming?.value = translated;
    } else {
      debugPrint(
        '[EmbeddedSchematicViewer] service incoming pass-through '
        '(no hierarchy): $raw',
      );
      _translatedIncoming?.value = raw;
    }
  }

  /// If `_pendingIncomingRaw` is non-null, translate and forward now that
  /// `_currentModuleId` is available.
  void _replayPendingIncomingSignals() {
    final raw = _pendingIncomingRaw;
    if (raw == null || raw.isEmpty || _currentModuleId == null) {
      return;
    }
    _pendingIncomingRaw = null;
    final translated = raw.map(_instancePathToDefPath).toList();
    debugPrint(
      '[EmbeddedSchematicViewer] replaying buffered incoming: '
      '$raw → $translated',
    );
    _translatedIncoming?.value = translated;
  }

  /// Convert a definition-name-based path emitted by the canvas into a
  /// full instance-hierarchy path suitable for the waveform viewer.
  ///
  /// Example:  `AdderModule/intermediate_sum`
  ///         → `top/adder0/intermediate_sum`
  String _defPathToInstancePath(String path) {
    final moduleId = _currentModuleId; // e.g. "root/adder0"
    if (moduleId == null) {
      return path;
    }
    final moduleKey = _instanceIdToModuleKey[moduleId]; // definition name
    if (moduleKey == null) {
      return path;
    }
    if (path.startsWith('$moduleKey/')) {
      return '$moduleId${path.substring(moduleKey.length)}';
    }
    if (path == moduleKey) {
      return moduleId;
    }
    return path;
  }

  /// Convert an instance-hierarchy path from the bus into a
  /// definition-name-based path that the canvas can process.
  ///
  /// Example:  `top/adder0/intermediate_sum`
  ///         → `AdderModule/intermediate_sum`
  String _instancePathToDefPath(String path) {
    final moduleId = _currentModuleId; // e.g. "root/adder0"
    if (moduleId == null) {
      return path;
    }
    final moduleKey = _instanceIdToModuleKey[moduleId]; // definition name
    if (moduleKey == null) {
      return path;
    }
    if (path.startsWith('$moduleId/')) {
      return '$moduleKey${path.substring(moduleId.length)}';
    }
    if (path == moduleId) {
      return moduleKey;
    }
    return path;
  }

  @override
  void initState() {
    super.initState();
    _themeCubit = SchematicThemeCubit(
      widget.initialThemeMode ?? SchematicThemeMode.dark,
    );
    if (widget.crossProbeService != null) {
      _translatedIncoming = ValueNotifier<List<String>?>(null);
      widget.crossProbeService!.incomingSignals.addListener(
        _onServiceIncomingSignals,
      );
    } else if (widget.incomingSignalPaths != null) {
      _translatedIncoming = ValueNotifier<List<String>?>(null);
      widget.incomingSignalPaths!.addListener(_onRawIncomingSignals);
    }
    // Ping the extension at startup and subscribe to module-info updates.
    final client = widget.extensionClient;
    if (client != null) {
      unawaited(client.ping());
      client.currentModuleInfo.addListener(_onModuleInfoChanged);
    }
  }

  void _onModuleInfoChanged() {
    final info = widget.extensionClient?.currentModuleInfo.value;
    if (mounted) {
      setState(() {
        _moduleInfo = info;
      });
    }
  }

  // ── Extension-aware go-to callbacks ──────────────────────────────────────

  /// Resolved module info from the extension (null = not yet queried or
  /// no extension client set).  Used to conditionally show go-to menu items.
  RohdModuleInfo? _moduleInfo;

  @override
  GoToSourceCallback? get onGoToSource {
    final outer = widget.onGoToSourceCallback;
    if (outer == null) {
      return null;
    }
    return (format, paths) {
      final translated = paths.map(_defPathToInstancePath).toList();
      debugPrint(
        '[EmbeddedSchematicViewer] onGoToSource($format): '
        '$paths → $translated',
      );
      outer(format, translated);
    };
  }

  @override
  AvailableSourceFormats? get availableSourceFormats =>
      () => resolveNavigableFormats(_moduleInfo);

  // Node toggle is handled by the base class layout engine.
  // The netlist JSON contains the full hierarchy, and the adapter
  // handles expand/collapse via _children internally.

  @override
  void dispose() {
    widget.crossProbeService?.incomingSignals.removeListener(
      _onServiceIncomingSignals,
    );
    widget.incomingSignalPaths?.removeListener(_onRawIncomingSignals);
    widget.extensionClient?.currentModuleInfo.removeListener(
      _onModuleInfoChanged,
    );
    _translatedIncoming?.dispose();
    unawaited(_themeCubit.close());
    super.dispose();
  }

  // Whether the initial load was deferred because the tab was hidden.
  // When the tab becomes visible we check this flag and run
  // loadInitialSchematic() at that point.
  bool _initialLoadDeferred = false;

  @override
  Future<void> loadInitialSchematic() async {
    debugPrint('[EmbeddedSchematicViewer] loadInitialSchematic() called');
    debugPrint('[EmbeddedSchematicViewer]   isVisible: ${widget.isVisible}');
    debugPrint(
      '[EmbeddedSchematicViewer]   externalHierarchy: '
      '${widget.externalHierarchy != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   netlistJsonMap: '
      '${widget.netlistJsonMap != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   schematicJson: '
      '${widget.schematicJson != null ? 'present' : 'null'}',
    );

    debugPrint('[EmbeddedSchematicViewer]   assetPath: ${widget.assetPath}');

    // Defer the expensive initial layout computation until the schematic
    // tab is actually visible.  This avoids blocking the UI on startup
    // with a potentially very large top-level module that the user may
    // never look at in the schematic.
    if (!widget.isVisible) {
      debugPrint(
        '[EmbeddedSchematicViewer] Tab not visible — deferring '
        'initial schematic load',
      );
      _initialLoadDeferred = true;
      return;
    }

    // Load from ROHD schematic JSON (Map format) if available. The ROHD
    // inspector always generates netlist-compatible JSON with cells referencing
    // subModules (hierarchy without connectivity). When full synthesis is
    // available, cells also have internal connectivity for routing.
    if (widget.netlistJsonMap != null) {
      debugPrint('[EmbeddedSchematicViewer] Parsing ROHD schematic JSON');
      await _loadFromJsonMap(widget.netlistJsonMap!);
      return;
    }

    // When external hierarchy is provided without schematic JSON, use light
    // synthesis
    if (widget.externalHierarchy != null && widget.schematicJson == null) {
      debugPrint(
        '[EmbeddedSchematicViewer] Loading from external hierarchy '
        '(using light synthesis)',
      );
      await _synthesizeFromHierarchyLight();
      return;
    }

    if (widget.schematicJson != null) {
      debugPrint('[EmbeddedSchematicViewer] Loading from provided JSON string');
      await _loadFromJson(widget.schematicJson!);
    } else if (widget.assetPath != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] Loading from asset: '
        '${widget.assetPath}',
      );
      await _loadFromAsset();
    } else {
      // No hierarchy, JSON, or asset path - wait for hierarchy to be provided
      debugPrint(
        '[EmbeddedSchematicViewer] No initial data - '
        'waiting for hierarchy',
      );
      setLoading(loading: true);
    }
  }

  Future<void> _loadFromJsonMap(Map<String, dynamic> jsonMap) async {
    _initialLoadInProgress = true;
    setLoading(loading: true);

    // Yield a frame so the loading indicator renders before the
    // heavy synchronous jsonEncode + parse work begins.
    if (mounted) {
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        completer.complete();
      });
      await completer.future;
      if (!mounted) {
        _initialLoadInProgress = false;
        return;
      }
    }

    try {
      // ── Incremental loading diagnostics ──
      final modules = jsonMap['modules'] as Map<String, dynamic>?;
      if (modules != null) {
        var treeCount = 0;
        var slimCount = 0;
        var fullCount = 0;
        for (final entry in modules.entries) {
          final level = _moduleDataLevel(entry.value as Map<String, dynamic>);
          if (level == _levelTree) {
            treeCount++;
          } else if (level == _levelSlim) {
            slimCount++;
          } else {
            fullCount++;
          }
        }
        final initialJsonSize = jsonEncode(jsonMap).length;
        debugPrint(
          '[INCREMENTAL] Initial schematic: '
          '${modules.length} modules '
          '($fullCount full, $slimCount slim, $treeCount tree), '
          '${(initialJsonSize / 1024).toStringAsFixed(1)} KB',
        );
        final incomplete = treeCount + slimCount;
        if (incomplete > 0 && widget.fetchModuleNetlist != null) {
          debugPrint(
            '[INCREMENTAL] Incomplete modules detected — '
            'on-demand fetch enabled',
          );
        } else if (incomplete > 0) {
          debugPrint(
            '[INCREMENTAL] Incomplete modules detected but '
            'no fetchModuleNetlist callback — '
            'modules will render without connectivity',
          );
        } else {
          debugPrint(
            '[INCREMENTAL] All modules have full connectivity — '
            'no incremental fetching needed',
          );
        }
      }

      // Eagerly fetch full connectivity for the root (top) module so the
      // initial view has wires, not just port stubs.  Sub-modules are still
      // fetched on-demand when the user drills into them.
      if (modules != null && widget.fetchModuleNetlist != null) {
        // Find the top module key.
        String? topKey;
        for (final entry in modules.entries) {
          final attrs = (entry.value as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>?;
          if (attrs?['top'] == 1) {
            topKey = entry.key;
            break;
          }
        }
        // Fall back to the only module if there is exactly one.
        topKey ??= modules.length == 1 ? modules.keys.first : null;

        if (topKey != null &&
            _needsUpgrade(modules[topKey] as Map<String, dynamic>)) {
          debugPrint(
            '[INCREMENTAL] Fetching full connectivity for root '
            'module "$topKey" before initial layout',
          );
          await _ensureModuleConnectivity(topKey, modules);
        }
      }

      // Convert map to JSON string for computeLayout
      final jsonString = jsonEncode(jsonMap);

      // Diagnostic: dump the schematic JSON we received for comparison.
      if (kDebugMode) {
        final modules = jsonMap['modules'] as Map<String, dynamic>?;
        debugPrint(
          '[EmbeddedSchematicViewer][DIAG] jsonMap top-level keys: '
          '${jsonMap.keys.toList()}',
        );
        debugPrint(
          '[EmbeddedSchematicViewer][DIAG] jsonString length: '
          '${jsonString.length}',
        );
        if (modules != null) {
          debugPrint(
            '[EmbeddedSchematicViewer][DIAG] Total modules: '
            '${modules.length}',
          );
          for (final entry in modules.entries) {
            final mod = entry.value as Map<String, dynamic>;
            final attrs = mod['attributes'] as Map<String, dynamic>?;
            final cells = mod['cells'] as Map<String, dynamic>? ?? {};
            final ports = mod['ports'] as Map<String, dynamic>? ?? {};
            final netnames = mod['netnames'] as Map<String, dynamic>? ?? {};
            debugPrint(
              '[EmbeddedSchematicViewer][DIAG]   ${entry.key}: '
              'cells=${cells.length}, ports=${ports.length}, '
              'netnames=${netnames.length}'
              '${attrs?["top"] == 1 ? " [TOP]" : ""}',
            );
          }
        }
        // Store on window so user can run:
        //   copy(window._rohdSchematicDump)
        // in the browser console, paste to a file, and diff against the
        // known-good bundled JSON.
        try {
          setRohdSchematicDump(jsonString);
          debugPrint(
            '[EmbeddedSchematicViewer][DIAG] Stored schematic JSON '
            'on window._rohdSchematicDump (${jsonString.length} chars). '
            'Run copy(window._rohdSchematicDump) in console to extract.',
          );
        } on Object catch (e) {
          debugPrint(
            '[EmbeddedSchematicViewer][DIAG] Could not store dump: '
            '$e',
          );
        }
      }

      debugPrint(
        '[EmbeddedSchematicViewer] _loadFromJsonMap: calling '
        'computeLayout (${jsonString.length} chars)...',
      );
      await computeLayout(jsonString);
      debugPrint(
        '[EmbeddedSchematicViewer] _loadFromJsonMap: computeLayout '
        'returned, layout=${layout != null}, '
        'instances=${layout?.instances.length ?? 0}',
      );

      // The initial computeLayout already shows the top-level module with
      // its sub-blocks as collapsed children (cells → child instances).
      // No additional expansion is needed — the netlist adapter's toggleNode
      // can actually collapse the view when called at this stage.
      // Preserve any error computeLayout set (e.g. ELK failed to load) so it
      // surfaces to the user instead of being cleared into a blank state.
      setLoading(loading: false, errorMessage: error);
      // Cache the layout result for the top module
      if (layout != null) {
        final modules = jsonMap['modules'] as Map<String, dynamic>?;
        if (modules != null) {
          // Find top module (module key = class name)
          var topModuleKey = '';
          for (final entry in modules.entries) {
            final attrs = (entry.value as Map<String, dynamic>)['attributes']
                as Map<String, dynamic>?;
            if (attrs?['top'] == 1) {
              topModuleKey = entry.key;
              break;
            }
          }
          if (topModuleKey.isNotEmpty) {
            _moduleCache[topModuleKey] = _CachedModule(
              layout!,
              jsonString,
              schematicAdapter?.schematic.expansionSnapshot() ??
                  const ExpansionSnapshot(
                    fullyExpanded: <String>{},
                    partials: <String,
                        ({Set<String> childIds, Set<String> edgeIds})>{},
                  ),
            );
            debugPrint(
              '[EmbeddedSchematicViewer] Cached layout for top module: '
              '$topModuleKey with full expansion snapshot',
            );
          }

          // Build instance ID → module key mapping using hierarchy + JSON
          _buildInstanceToModuleKeyMapping(modules);

          // Set _currentModuleId to the hierarchy root so that
          // _saveCurrentExpansionState() works when navigating away
          // from the initial top module.  Without this, the expanded
          // state is lost because _currentModuleId is null and the
          // save bails out early.
          if (_currentModuleId == null && widget.externalHierarchy != null) {
            _currentModuleId = widget.externalHierarchy!.root.path();
            _replayPendingIncomingSignals();
            // Query source formats for the initial root module so the
            // cross-probe status icon reflects available languages from
            // the start (without requiring user navigation).
            final rootModule = widget.externalHierarchy!.root;
            final rootKey = _instanceIdToModuleKey[rootModule.path()];
            final client = widget.extensionClient;
            if (client != null) {
              final queryName =
                  rootKey ?? rootModule.definition ?? rootModule.path();
              debugPrint(
                '[EmbeddedSchematicViewer] initial queryModule: '
                '"$queryName" (instancePath=${rootModule.path()})',
              );
              unawaited(
                client.queryModule(
                  queryName,
                  instancePath: rootModule.path().split('/'),
                ),
              );
            }
          }
        }
      }
      if (layout == null) {
        setLoading(
          loading: false,
          errorMessage:
              error ?? 'Schematic layout completed without a layout result.',
        );
        _initialLoadInProgress = false;
        return;
      }

      setLoading(loading: false, errorMessage: error);
      _initialLoadInProgress = false;

      // Process any module selection that was deferred during initial load
      if (_hasPendingModule) {
        debugPrint(
          '[EmbeddedSchematicViewer] Processing deferred module '
          'selection after initial load: ${_pendingModule?.path()}',
        );
        _hasPendingModule = false;
        final pending = _pendingModule;
        _pendingModule = null;
        _selectModule(pending);
      }
    } on Exception catch (e) {
      _initialLoadInProgress = false;
      setLoading(loading: false, errorMessage: 'Failed to compute layout: $e');
    }
  }

  /// Builds the mapping from hierarchy instance IDs to module keys.
  ///
  /// Netlist JSON from ROHD uses class names as module keys
  /// (e.g., 'FilterBank') while the hierarchy tree uses
  /// instance paths (e.g., 'dut'). This walks both trees in parallel to
  /// build the correspondence.
  void _buildInstanceToModuleKeyMapping(Map<String, dynamic> modules) {
    _instanceIdToModuleKey.clear();

    final hierarchy = widget.externalHierarchy;
    if (hierarchy == null) {
      debugPrint(
        '[EmbeddedSchematicViewer] No hierarchy available, '
        'cannot build instance mapping',
      );
      return;
    }

    // Find top module key
    String? topModuleKey;
    for (final entry in modules.entries) {
      final attrs = (entry.value as Map<String, dynamic>)['attributes']
          as Map<String, dynamic>?;
      if (attrs?['top'] == 1) {
        topModuleKey = entry.key;
        break;
      }
    }
    if (topModuleKey == null) {
      debugPrint('[EmbeddedSchematicViewer] No top module found in JSON');
      return;
    }

    // Map root hierarchy node to top module key
    final root = hierarchy.root;
    _mapInstanceRecursive(modules, topModuleKey, root);

    debugPrint(
      '[EmbeddedSchematicViewer] Built instance→moduleKey mapping: '
      '${_instanceIdToModuleKey.length} entries',
    );
    // Log first few entries for debugging
    final entries = _instanceIdToModuleKey.entries.take(10).toList();
    for (final e in entries) {
      debugPrint('[EmbeddedSchematicViewer]   ${e.key} → ${e.value}');
    }
  }

  String? _findTopModuleKey(Map<String, dynamic>? netlistJsonMap) {
    final modules = netlistJsonMap?['modules'] as Map<String, dynamic>?;
    if (modules == null || modules.isEmpty) {
      return null;
    }
    for (final entry in modules.entries) {
      final attrs = (entry.value as Map<String, dynamic>)['attributes']
          as Map<String, dynamic>?;
      if (attrs?['top'] == 1) {
        return entry.key;
      }
    }
    return modules.keys.first;
  }

  bool _isLikelyIncrementalNetlistUpdate(
    Map<String, dynamic>? oldMap,
    Map<String, dynamic> newMap,
  ) {
    if (oldMap == null) {
      return false;
    }
    final oldModules = oldMap['modules'] as Map<String, dynamic>?;
    final newModules = newMap['modules'] as Map<String, dynamic>?;
    if (oldModules == null || newModules == null) {
      return false;
    }

    final oldTop = _findTopModuleKey(oldMap);
    final newTop = _findTopModuleKey(newMap);
    if (oldTop != newTop) {
      return false;
    }

    final oldKeys = oldModules.keys.toSet();
    final newKeys = newModules.keys.toSet();
    return oldKeys.length == newKeys.length && oldKeys.containsAll(newKeys);
  }

  String _enrichJsonWithSharedModules(
    String localJsonString,
    Map<String, dynamic> sharedModules,
  ) {
    final localJson = jsonDecode(localJsonString) as Map<String, dynamic>;
    final localMods = localJson['modules'] as Map<String, dynamic>?;
    if (localMods == null) {
      return localJsonString;
    }

    var enriched = false;
    for (final key in localMods.keys.toList()) {
      final localMod = localMods[key] as Map<String, dynamic>;
      final sharedMod = sharedModules[key] as Map<String, dynamic>?;
      if (sharedMod != null &&
          _moduleDataLevel(localMod) < _moduleDataLevel(sharedMod)) {
        localMods[key] = sharedMod;
        enriched = true;
      }
    }

    return enriched ? jsonEncode(localJson) : localJsonString;
  }

  void _applyIncrementalNetlistUpdate(Map<String, dynamic> updatedJsonMap) {
    final sharedModules = updatedJsonMap['modules'] as Map<String, dynamic>?;
    if (sharedModules == null) {
      return;
    }

    _buildInstanceToModuleKeyMapping(sharedModules);

    // Keep current adapter JSON in sync with newly fetched full modules,
    // while preserving expansion state and current layout.
    if (schematicAdapter != null && schematicJson != null) {
      final snapshot = schematicAdapter!.schematic.expansionSnapshot();
      final enrichedCurrent = _enrichJsonWithSharedModules(
        schematicJson!,
        sharedModules,
      );
      if (enrichedCurrent != schematicJson) {
        schematicJson = enrichedCurrent;
        schematicAdapter = NetlistSchematicAdapter.fromJson(enrichedCurrent);
        schematicAdapter!.schematic.restoreExpansionSnapshot(snapshot);
        _nodeAddrToModuleKey = null;
        debugPrint(
          '[EmbeddedSchematicViewer] Incremental update: '
          'refreshed current adapter JSON in place',
        );
      }
    }

    // Keep cached JSON payloads synchronized so restoring a module cache hit
    // doesn't regress to stale slim-module definitions.
    for (final entry in _moduleCache.entries.toList()) {
      final cached = entry.value;
      if (cached.jsonString.isEmpty) {
        continue;
      }
      final enriched = _enrichJsonWithSharedModules(
        cached.jsonString,
        sharedModules,
      );
      if (enriched == cached.jsonString) {
        continue;
      }
      _moduleCache[entry.key] = _CachedModule(
        cached.layout,
        enriched,
        cached.expansionSnapshot,
        viewOffset: cached.viewOffset,
        viewScale: cached.viewScale,
      );
    }
  }

  /// Recursively maps hierarchy instance IDs to module keys.
  ///
  /// For each hierarchy node, records `node.path() → moduleKey`. Then looks at
  /// the cells in the netlist module to find child mappings: each cell's key
  /// is the instance name (matching `child.name`) and `cell`'type'`` is
  /// the module key for that child.
  ///
  /// When a child can't be matched via cells (e.g. because the parent is
  /// a slim module with no cell data), falls back to the child's `definition`
  /// field which is the definition/class name — the same key used in the
  /// netlist JSON.
  void _mapInstanceRecursive(
    Map<String, dynamic> modules,
    String moduleKey,
    HierarchyOccurrence node,
  ) {
    _instanceIdToModuleKey[node.path()] = moduleKey;

    // Get cells from this netlist module to map children
    final moduleData = modules[moduleKey] as Map<String, dynamic>?;
    final cells =
        moduleData?['cells'] as Map<String, dynamic>? ?? <String, dynamic>{};

    // For each hierarchy child, find matching cell by instance name
    for (final child in node.children) {
      final cellData = cells[child.name] as Map<String, dynamic>?;
      if (cellData != null) {
        final cellType = cellData['type'] as String?;
        if (cellType != null && modules.containsKey(cellType)) {
          _mapInstanceRecursive(modules, cellType, child);
          continue;
        }
      }
      // Fallback: use the hierarchy node's `definition` field (module/class
      // name) as the module key.  This handles slim modules whose cells
      // lack definition information or whose instance names don't match.
      final childType = child.definition;
      if (childType != null && modules.containsKey(childType)) {
        _mapInstanceRecursive(modules, childType, child);
      }
    }
  }

  Future<void> _loadFromJson(String jsonData) async {
    setLoading(loading: true);
    try {
      await computeLayout(jsonData, expansionMode: widget.initialExpansionMode);
    } on Exception catch (e) {
      setLoading(loading: false, errorMessage: 'Failed to compute layout: $e');
    }
  }

  Future<void> _loadFromAsset() async {
    setLoading(loading: true);
    try {
      final path = widget.assetPath ?? EmbeddedSchematicViewer.defaultAssetPath;
      final jsonData = await rootBundle.loadString(path);
      await computeLayout(jsonData);
    } on Exception catch (e) {
      setLoading(loading: false, errorMessage: 'Failed to load schematic: $e');
    }
  }

  @override
  void didUpdateWidget(covariant EmbeddedSchematicViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Swap the raw incoming-signals listener when the notifier changes.
    if (oldWidget.incomingSignalPaths != widget.incomingSignalPaths) {
      oldWidget.incomingSignalPaths?.removeListener(_onRawIncomingSignals);
      if (widget.incomingSignalPaths != null) {
        _translatedIncoming ??= ValueNotifier<List<String>?>(null);
        widget.incomingSignalPaths!.addListener(_onRawIncomingSignals);
      }
    }

    debugPrint('[EmbeddedSchematicViewer] didUpdateWidget called');
    debugPrint(
      '[EmbeddedSchematicViewer]   Old hierarchy: '
      '${oldWidget.externalHierarchy != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   New hierarchy: '
      '${widget.externalHierarchy != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   Old netlistJsonMap: '
      '${oldWidget.netlistJsonMap != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   New netlistJsonMap: '
      '${widget.netlistJsonMap != null ? 'present' : 'null'}',
    );
    debugPrint(
      '[EmbeddedSchematicViewer]   schematicJson: '
      '${widget.schematicJson != null ? 'present' : 'null'}',
    );

    // Fast path: if the tab is hidden and none of the structural props
    // changed (hierarchy, netlist, selected module, visibility), skip all
    // processing — the rebuild was likely triggered by an unrelated cubit
    // (e.g. SnapshotCubit).
    if (!widget.isVisible &&
        !oldWidget.isVisible &&
        identical(widget.externalHierarchy, oldWidget.externalHierarchy) &&
        identical(widget.netlistJsonMap, oldWidget.netlistJsonMap) &&
        widget.selectedModule == oldWidget.selectedModule &&
        widget.schematicJson == oldWidget.schematicJson) {
      return;
    }

    // IMPORTANT: process visibility transition before any early-return
    // reload/defer branches below. Otherwise a netlist/hierarchy change can
    // return early and skip the deferred-load trigger forever.
    if (widget.isVisible && !oldWidget.isVisible && _initialLoadDeferred) {
      debugPrint(
        '[EmbeddedSchematicViewer] Tab became visible — running '
        'deferred initial schematic load',
      );
      _initialLoadDeferred = false;
      unawaited(loadInitialSchematic());
      return;
    }

    // Sync theme cubit if initialThemeMode changed
    if (widget.initialThemeMode != oldWidget.initialThemeMode &&
        widget.initialThemeMode != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] Theme mode changed, '
        'updating cubit',
      );
      _themeCubit.setTheme(widget.initialThemeMode!);
    }

    // If netlistJsonMap changed, either refresh caches in-place (incremental
    // enrichment) or reload from scratch (true design swap).
    // When the tab is hidden and the initial load was deferred, just
    // mark the deferred flag — loadInitialSchematic will pick up the
    // latest widget data when the tab becomes visible.
    if (widget.netlistJsonMap != oldWidget.netlistJsonMap &&
        widget.netlistJsonMap != null) {
      if (_initialLoadDeferred || !widget.isVisible) {
        debugPrint(
          '[EmbeddedSchematicViewer] Schematic JSON map changed '
          'but tab hidden — deferring',
        );
        _initialLoadDeferred = true;
        return;
      } else {
        final incremental = _isLikelyIncrementalNetlistUpdate(
          oldWidget.netlistJsonMap,
          widget.netlistJsonMap!,
        );
        if (incremental && layout != null && schematicAdapter != null) {
          debugPrint(
            '[EmbeddedSchematicViewer] Schematic JSON map changed '
            '(incremental) — updating cache/mappings in place',
          );
          _applyIncrementalNetlistUpdate(widget.netlistJsonMap!);
          // Continue processing this didUpdateWidget call. A module selection
          // change can arrive in the same frame as incremental enrichment,
          // and returning early here would drop that selection update.
        } else {
          debugPrint(
            '[EmbeddedSchematicViewer] Schematic JSON map changed '
            '(design swap) — reloading',
          );
          unawaited(_loadFromJsonMap(widget.netlistJsonMap!));
          return;
        }
      }
    }

    // If netlistJsonMap is no longer present but hierarchy is, fetch from
    // server or fall back to light synthesis
    if (oldWidget.netlistJsonMap != null &&
        widget.netlistJsonMap == null &&
        widget.externalHierarchy != null) {
      if (_initialLoadDeferred || !widget.isVisible) {
        debugPrint(
          '[EmbeddedSchematicViewer] Schematic JSON removed but '
          'tab hidden — deferring',
        );
        _initialLoadDeferred = true;
      } else {
        debugPrint(
          '[EmbeddedSchematicViewer] Schematic JSON removed but '
          'hierarchy available, fetching or light-synthesizing',
        );
        unawaited(_fetchOrSynthesizeModule());
      }
      return;
    }

    // If external hierarchy changed (and no netlistJsonMap), fetch from
    // server or fall back to light synthesis
    if (widget.externalHierarchy != oldWidget.externalHierarchy &&
        widget.externalHierarchy != null &&
        widget.netlistJsonMap == null) {
      if (_initialLoadDeferred || !widget.isVisible) {
        debugPrint(
          '[EmbeddedSchematicViewer] Hierarchy changed but '
          'tab hidden — deferring',
        );
        _initialLoadDeferred = true;
      } else {
        debugPrint(
          '[EmbeddedSchematicViewer] Hierarchy changed, '
          'fetching or light-synthesizing',
        );
        unawaited(_fetchOrSynthesizeModule());
      }
    } else if (widget.externalHierarchy != oldWidget.externalHierarchy) {
      debugPrint(
        '[EmbeddedSchematicViewer] Hierarchy changed but did not '
        'trigger synthesis (schematic JSON present)',
      );
      // Rebuild instance→moduleKey mapping with the new hierarchy
      if (widget.netlistJsonMap != null) {
        final modules =
            widget.netlistJsonMap!['modules'] as Map<String, dynamic>?;
        if (modules != null) {
          _buildInstanceToModuleKeyMapping(modules);
        }
      }
    }

    // Handle selected module changes from parent
    // When a submodule is selected, synthesize its schematic from hierarchy
    // This works even when netlistJsonMap is provided (ROHD format)
    if (widget.selectedModule != oldWidget.selectedModule &&
        widget.externalHierarchy != null) {
      if (widget.isVisible && !_initialLoadInProgress) {
        debugPrint(
          '[EmbeddedSchematicViewer] Selected module changed, updating',
        );
        _selectModule(widget.selectedModule);
      } else {
        // Defer expensive layout computation until the tab is visible
        // AND the initial load is complete. This prevents:
        // 1. Blocking the UI while the user is on another tab
        // 2. Race condition where _selectModule runs before _loadFromJsonMap
        //    has populated the cache, causing _extractAndComputeFromJson to
        //    overwrite the expanded schematic with a collapsed single block
        final loadState = _initialLoadInProgress
            ? 'initial load still in progress'
            : 'tab is hidden';
        debugPrint(
          '[EmbeddedSchematicViewer] Selected module changed but '
          '$loadState, '
          'deferring',
        );
        _pendingModule = widget.selectedModule;
        _hasPendingModule = true;
      }
    }

    // When the schematic tab becomes visible, run any deferred work.
    if (widget.isVisible && !oldWidget.isVisible) {
      // If the initial schematic load was deferred because the tab was
      // hidden on first mount, run it now.
      if (_initialLoadDeferred) {
        debugPrint(
          '[EmbeddedSchematicViewer] Tab became visible — running '
          'deferred initial schematic load',
        );
        _initialLoadDeferred = false;
        unawaited(loadInitialSchematic());
        // loadInitialSchematic will process any pending module selection
        // via the _hasPendingModule mechanism once the initial load
        // completes, so we return early here.
        return;
      }

      // Process any pending module selection that was deferred while the
      // tab was hidden.
      if (_hasPendingModule && !_initialLoadInProgress) {
        debugPrint(
          '[EmbeddedSchematicViewer] Tab became visible, processing '
          'pending module: ${_pendingModule?.path()}',
        );
        _hasPendingModule = false;
        _selectModule(_pendingModule);
        _pendingModule = null;
      }
    }

    // Reload if the JSON changed
    if (widget.schematicJson != oldWidget.schematicJson &&
        widget.schematicJson != null) {
      debugPrint('[EmbeddedSchematicViewer] Schematic JSON changed, reloading');
      unawaited(_loadFromJson(widget.schematicJson!));
    }
  }

  /// Synthesize a basic schematic layout directly from hierarchy data.
  ///
  /// This "light synthesis" path generates a quick-to-compute grid-based layout
  /// without needing the JavaScript layout engine. It's much faster than the
  /// full JS-based synthesis and works well for initial visualization.
  Future<void> _synthesizeFromHierarchyLight({
    Set<String>? expandedNodesOverride,
  }) async {
    if (widget.externalHierarchy == null) {
      debugPrint(
        '[EmbeddedSchematicViewer] externalHierarchy is null, '
        'skipping light synthesis',
      );
      return;
    }

    setLoading(loading: true);
    try {
      debugPrint(
        '[EmbeddedSchematicViewer] Starting light hierarchy synthesis '
        '(direct grid layout)...',
      );

      // Create the light synthesizer
      final synthesizer = HierarchySchematicSynthesizer(
        widget.externalHierarchy!,
      );

      // Get the target node (root or selected module)
      final targetNode = _currentModuleId != null
          ? _resolveNode(widget.externalHierarchy!, _currentModuleId!)
          : widget.externalHierarchy!.root;

      // Determine which nodes to show expanded.
      // If an override is provided (from a user toggle), use it directly.
      // On the first call for a scope, auto-expand immediate children so the
      // user immediately sees the next level without having to click.
      late final Set<String> expandedNodes;
      if (expandedNodesOverride != null) {
        expandedNodes = expandedNodesOverride;
        // Persist so subsequent toggles start from the current state.
        _lightSynthExpandedNodes[_currentModuleId] = Set<String>.from(
          expandedNodes,
        );
      } else if (_lightSynthExpandedNodes.containsKey(_currentModuleId)) {
        // Re-entering this scope (e.g. cache miss after navigation) —
        // restore the previously-persisted expansion state.
        expandedNodes = Set<String>.from(
          _lightSynthExpandedNodes[_currentModuleId]!,
        );
      } else {
        // First visit: auto-expand immediate children.
        expandedNodes = <String>{};
        if (targetNode != null && targetNode.children.isNotEmpty) {
          for (final child in targetNode.children) {
            expandedNodes.add(child.path());
          }
        }
        // Persist the auto-expanded state for this scope.
        _lightSynthExpandedNodes[_currentModuleId] = Set<String>.from(
          expandedNodes,
        );
        if (expandedNodes.isNotEmpty) {
          debugPrint(
            '[EmbeddedSchematicViewer] Expanding ${expandedNodes.length} '
            'child modules in schematic',
          );
        }
      }

      // Generate basic schematic layout from hierarchy with expanded children
      debugPrint(
        '[EmbeddedSchematicViewer] Generating grid-based layout '
        'from hierarchy...',
      );
      final layout = synthesizer.synthesize(
        moduleId: _currentModuleId,
        expandedNodes: expandedNodes,
      );

      debugPrint(
        '[EmbeddedSchematicViewer] Light layout generated: '
        '${layout.instances.length} instances, '
        '${layout.ports.length} ports, '
        '${layout.width.toStringAsFixed(0)}'
        'x${layout.height.toStringAsFixed(0)}',
      );

      // Cache the generated layout
      final cacheKey = _currentModuleId ?? 'root';
      if (layout.instances.isNotEmpty) {
        _moduleCache[cacheKey] = _CachedModule(
          layout,
          '', // No JSON string for light synthesis
          ExpansionSnapshot(
            fullyExpanded: Set<String>.from(expandedNodes),
            partials: const <String,
                ({Set<String> childIds, Set<String> edgeIds})>{},
          ),
        );
        debugPrint(
          '[EmbeddedSchematicViewer] Cached light-synthesized layout for: '
          '$cacheKey',
        );
      }

      // Display the layout by triggering a rebuild
      if (!mounted) {
        return;
      }
      setState(() {
        this.layout = layout;
        schematicJson = '';
        schematicAdapter = null;
        error = null;
        isLoading = false;
      });
    } on Exception catch (e, stackTrace) {
      debugPrint('[EmbeddedSchematicViewer] Error in light synthesis: $e');
      debugPrint('[EmbeddedSchematicViewer] Stack trace: $stackTrace');
      setLoading(
        loading: false,
        errorMessage: 'Failed to synthesize schematic: $e',
      );
    }
  }

  /// Override toggle handling for light-synthesis mode.
  ///
  /// When the viewer is operating in "light synthesis" mode (no schematic JSON,
  /// no `schematicAdapter`), the base-class toggle logic cannot work because
  /// there is no ELK graph to mutate.  Instead we track expansion state
  /// ourselves and re-run `_synthesizeFromHierarchyLight` with the updated
  /// expanded-node set so the canvas immediately reflects the change.
  @override
  Future<SchematicLayoutResult?> handleNodeToggle(String nodeId) async {
    if (schematicAdapter != null || widget.externalHierarchy == null) {
      // Normal ELK-adapter path.
      final layout = await super.handleNodeToggle(nodeId);
      return layout;
    }

    // Light synthesis toggle path.
    if (isToggling) {
      return null;
    }

    setState(() {
      isToggling = true;
    });

    // Yield a frame so any spinner starts before the re-synthesis work.
    final frameCompleter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => frameCompleter.complete(),
    );
    await frameCompleter.future;

    try {
      // Get the persisted expanded set for the current scope (initialised to
      // auto-expand of immediate children on first visit by
      // _synthesizeFromHierarchyLight), then toggle the clicked node.
      final currentExpanded =
          _lightSynthExpandedNodes[_currentModuleId] ?? <String>{};
      final newExpanded = Set<String>.from(currentExpanded);
      if (newExpanded.contains(nodeId)) {
        newExpanded.remove(nodeId);
      } else {
        newExpanded.add(nodeId);
      }
      debugPrint(
        '[LightSynth] Toggle $nodeId: '
        '${currentExpanded.contains(nodeId) ? "collapse" : "expand"} '
        '(expanded count: ${newExpanded.length})',
      );

      await _synthesizeFromHierarchyLight(expandedNodesOverride: newExpanded);
    } on Exception catch (e) {
      debugPrint('[LightSynth] Toggle error: $e');
    } finally {
      if (mounted) {
        setState(() {
          isToggling = false;
        });
      }
    }
    return layout;
  }

  /// Fetch connectivity for every potentially traversed module before a
  /// recursive port expansion.
  @override
  Future<SchematicLayoutResult?> handlePortExpandThrough(
    String nodeId,
    String portId,
  ) async {
    if (schematicAdapter != null) {
      await _ensureAllModuleConnectivity();
    }
    final layout = await super.handlePortExpandThrough(nodeId, portId);
    return layout;
  }

  /// Override recursive toggle to fetch connectivity for ALL slim modules
  /// before expanding.
  ///
  /// Unlike single-node toggle (which only needs the target module's
  /// connectivity), recursive toggle will expand all descendant submodules
  /// and needs full edge data for all of them.
  @override
  Future<SchematicLayoutResult?> handleNodeToggleRecursive(
    String nodeId,
  ) async {
    if (schematicAdapter != null) {
      await _ensureAllModuleConnectivity();
    }
    final layout = await super.handleNodeToggleRecursive(nodeId);
    return layout;
  }

  /// Override recursive non-primitive expansion to fetch connectivity first.
  @override
  Future<SchematicLayoutResult?> handleExpandNonPrimitivesRecursive(
    String nodeId,
  ) async {
    if (schematicAdapter != null) {
      await _ensureAllModuleConnectivity();
    }
    final layout = await super.handleExpandNonPrimitivesRecursive(nodeId);
    return layout;
  }

  /// Fetch full connectivity for ALL slim modules in sharedModules.
  ///
  /// Used before recursive operations (SHIFT+click expand) that will
  /// expose all descendant submodules at once.  Since all modules will
  /// become visible, we fetch every slim module rather than trying to
  /// predict which specific ones the recursive toggle will need.
  Future<bool> _ensureAllModuleConnectivity() async {
    final sharedModules = _sharedModulesOrNull;
    if (sharedModules == null) {
      return false;
    }

    // Collect all slim module keys.
    final toFetch = <String>{};
    for (final entry in sharedModules.entries) {
      final mod = entry.value;
      if (mod is Map<String, dynamic> && _needsUpgrade(mod)) {
        toFetch.add(entry.key);
      }
    }

    if (toFetch.isEmpty) {
      debugPrint(
        '[INCREMENTAL] _ensureAllModuleConnectivity: '
        'no slim modules — skipping',
      );
      return false;
    }

    debugPrint(
      '[INCREMENTAL] _ensureAllModuleConnectivity: '
      'fetching ${toFetch.length} slim module(s): $toFetch',
    );

    final rebuilt = await _fetchModulesAndRebuild(toFetch, sharedModules);
    return rebuilt;
  }

  /// Fetch real netlist JSON from the server for the current module,
  /// then compute layout. Falls back to light synthesis when no server
  /// callback is available or the fetch returns null.
  ///
  /// This replaces the old `_synthesizeFromHierarchy` which used
  /// `HierarchyToNetlistConverter` to fabricate lossy JSON from the
  /// hierarchy tree. The server always has the real netlist (slim or full)
  /// which renders correctly in either case.
  Future<void> _fetchOrSynthesizeModule() async {
    if (widget.externalHierarchy == null) {
      debugPrint(
        '[EmbeddedSchematicViewer] externalHierarchy is null, '
        'skipping',
      );
      return;
    }

    // Determine the definition (type) name for the current module.
    final HierarchyOccurrence targetNode;
    if (_currentModuleId != null) {
      targetNode = _resolveNode(widget.externalHierarchy!, _currentModuleId!) ??
          widget.externalHierarchy!.root;
    } else {
      targetNode = widget.externalHierarchy!.root;
    }
    // The definition name is the module definition (class name), not the
    // instance path.  Fall back to the node name for the root.
    final definitionName = targetNode.definition ?? targetNode.name;

    // Try fetching real netlist from the server.
    if (widget.fetchModuleNetlist != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] Fetching netlist for '
        '"$definitionName" from server',
      );
      try {
        final fullData = await widget.fetchModuleNetlist!(definitionName);
        if (fullData != null && fullData.isNotEmpty) {
          debugPrint(
            '[EmbeddedSchematicViewer] Server returned netlist for '
            '"$definitionName" (${fullData.length} module(s))',
          );

          // Build a modules map suitable for _extractAndComputeFromJson.
          // The server may return just {DefinitionName: {...}} or a full
          // Yosys JSON with multiple modules.  Ensure the target module
          // has attributes.top = 1.
          final modules = <String, dynamic>{};
          for (final entry in fullData.entries) {
            if (entry.key == definitionName) {
              final mod = entry.value as Map<String, dynamic>;
              modules[entry.key] = {
                ...mod,
                'attributes': {
                  ...(mod['attributes'] as Map<String, dynamic>? ?? {}),
                  'top': 1,
                },
              };
            } else {
              modules[entry.key] = entry.value;
            }
          }

          await _extractAndComputeFromJson(definitionName, modules);
          return;
        }
        debugPrint(
          '[EmbeddedSchematicViewer] Server returned null for '
          '"$definitionName", falling back to light synthesis',
        );
      } on Exception catch (e) {
        debugPrint(
          '[EmbeddedSchematicViewer] Fetch failed for '
          '"$definitionName": $e — falling back to light synthesis',
        );
      }
    } else {
      debugPrint(
        '[EmbeddedSchematicViewer] No fetchModuleNetlist callback, '
        'using light synthesis',
      );
    }

    // Fallback: light synthesis (grid layout from hierarchy, no edges).
    await _synthesizeFromHierarchyLight();
  }

  /// Select a module from the parent's selection.
  /// Priority:
  /// 1. Check cache (by module key) - if found, display immediately
  /// 2. Check netlistJsonMap (by module key) - compute and cache layout
  /// 3. Fetch real netlist from server, or light-synthesize
  void _selectModule(HierarchyOccurrence? module) {
    if (module == null) {
      _currentModuleId = null;
      return;
    }

    // Resolve the module key for this instance.
    // Hierarchy uses instance paths (e.g., 'dut') but the netlist JSON and
    // cache use class names (e.g., 'FilterBank').
    final moduleKey = _instanceIdToModuleKey[module.path()];

    debugPrint(
      '[EmbeddedSchematicViewer] _selectModule called for: '
      '${module.path()} (moduleKey: $moduleKey)',
    );
    debugPrint(
      '[EmbeddedSchematicViewer] Cache keys: '
      '${_moduleCache.keys.toList()}',
    );

    // Query the extension for available source formats for this module.
    // This updates _moduleInfo (via the listener) so the go-to menu items
    // are shown/hidden correctly for the new selection.
    final client = widget.extensionClient;
    if (client != null) {
      final queryName = moduleKey ?? module.definition ?? module.path();
      debugPrint(
        '[EmbeddedSchematicViewer] _selectModule queryModule: '
        '"$queryName" (instancePath=${module.path()}, moduleKey=$moduleKey)',
      );
      unawaited(
        client.queryModule(queryName, instancePath: module.path().split('/')),
      );
    }

    // Save expansion state for the OLD module
    // (before updating _currentModuleId)
    _saveCurrentExpansionState();

    // NOW switch to the new module
    _currentModuleId = module.path();

    // Replay any incoming signals that were buffered while
    // _currentModuleId was null (cross-probe arrived before load).
    _replayPendingIncomingSignals();

    // Check 1: Try cache by instance ID (unique per instance)
    if (_moduleCache.containsKey(module.path())) {
      if (_cachingEnabled) {
        debugPrint(
          '[EmbeddedSchematicViewer] Cache hit by instance ID: '
          '${module.path()}',
        );
        _restoreFromCache(_moduleCache[module.path()]!);
        return;
      } else {
        debugPrint(
          '[EmbeddedSchematicViewer] CACHE DISABLED – skipping '
          'cache hit by instance ID: ${module.path()}',
        );
      }
    }

    // Check 1b: Try module type key as a *template* for a fresh instance.
    // Instances of the same type share the initial unexpanded layout
    // but each instance gets its own independent cache entry so that
    // expansion state and view position are not shared.
    if (moduleKey != null && _moduleCache.containsKey(moduleKey)) {
      if (_cachingEnabled) {
        debugPrint(
          '[EmbeddedSchematicViewer] Template hit for: $moduleKey '
          '→ creating instance cache for ${module.path()}',
        );
        final template = _moduleCache[moduleKey]!;
        // Clone the template into an instance-specific cache entry.
        // Use the template's expansion snapshot (the default first-level
        // expansion from fromJson) so that _restoreFromCache rebuilds the
        // adapter into a consistent state.  An empty snapshot would collapse
        // everything, making the adapter and cached layout out of sync and
        // causing subsequent toggleNode / ensureConnectivity to produce
        // empty ELK results.
        final instanceCopy = _CachedModule(
          template.layout,
          template.jsonString,
          template.expansionSnapshot,
        );
        _moduleCache[module.path()] = instanceCopy;
        _restoreFromCache(instanceCopy);
        return;
      } else {
        debugPrint(
          '[EmbeddedSchematicViewer] CACHE DISABLED – skipping '
          'template hit for: $moduleKey (instance: ${module.path()})',
        );
      }
    }

    // Check 2: Try to extract from netlistJsonMap (on-demand)
    if (widget.netlistJsonMap != null) {
      final modules =
          widget.netlistJsonMap!['modules'] as Map<String, dynamic>?;
      if (modules != null) {
        // Look up by module key (class name), not instance ID.
        // If the instance→moduleKey mapping didn't cover this node (e.g.
        // because the parent was a slim module with no cells), fall back
        // to the node's `definition` (the module/class name).
        final lookupKey = moduleKey ?? module.definition ?? module.path();
        if (modules.containsKey(lookupKey)) {
          // Backfill the mapping so future visits are instant cache lookups.
          if (moduleKey == null && lookupKey != module.path()) {
            _instanceIdToModuleKey[module.path()] = lookupKey;
          }
          debugPrint(
            '[EmbeddedSchematicViewer] *** _selectModule taking '
            '_extractAndComputeFromJson path for: $lookupKey '
            '(instance: ${module.path()}). This will call computeLayout '
            'and may OVERWRITE the current expanded layout! ***',
          );
          unawaited(_extractAndComputeFromJson(lookupKey, modules));
          return;
        }
      }
    }

    // Check 3: Fetch real netlist from server, or light-synthesize
    if (widget.externalHierarchy != null) {
      debugPrint(
        '[EmbeddedSchematicViewer] Module not in cache or JSON, '
        'fetching or light-synthesizing: ${module.path()}',
      );
      unawaited(_fetchOrSynthesizeModule());
    } else {
      debugPrint(
        '[EmbeddedSchematicViewer] Module ${module.path()} not cached, '
        'not in JSON, and no hierarchy available',
      );
      setLoading(
        loading: false,
        errorMessage: 'Module schematic not available: ${module.path()}',
      );
    }
  }

  /// Save the current adapter's expansion state back into the cache entry
  /// for the module we're navigating away from.
  void _saveCurrentExpansionState() {
    if (schematicAdapter == null || _currentModuleId == null) {
      return;
    }

    // Always save by instance ID so each instance keeps its own
    // expansion state and view position independently.
    final cacheKey = _currentModuleId!;
    final existing = _moduleCache[cacheKey];

    // If there's no instance-specific cache entry yet, try to seed
    // from the module-key template so we have a jsonString to save.
    final fallbackJsonString = existing?.jsonString ??
        (() {
          final moduleKey = _instanceIdToModuleKey[_currentModuleId!];
          return moduleKey != null ? _moduleCache[moduleKey]?.jsonString : null;
        })() ??
        '';

    // Snapshot the current view position from the canvas
    final canvasState = _canvasKey.currentState;
    final viewOffset = canvasState?.currentOffset;
    final viewScale = canvasState?.currentScale;
    // Update the expansion state and view position snapshot
    _moduleCache[cacheKey] = _CachedModule(
      layout ?? existing?.layout ?? SchematicLayoutResult.empty(),
      fallbackJsonString,
      schematicAdapter!.schematic.expansionSnapshot(),
      viewOffset: viewOffset ?? existing?.viewOffset,
      viewScale: viewScale ?? existing?.viewScale,
    );
    debugPrint(
      '[EmbeddedSchematicViewer] Saved expansion state for '
      '$cacheKey: full expansion snapshot, '
      'view: offset=$viewOffset, scale=$viewScale',
    );
  }

  /// Restore from cache: show the cached layout instantly, then rebuild
  /// the adapter from cached JSON and replay the saved expansion state.
  void _restoreFromCache(_CachedModule cached) {
    try {
      // Check if this is a light synthesis result (empty jsonString)
      final isLightSynthesis = cached.jsonString.isEmpty;

      // Enrich the cached JSON with any modules that are now full in
      // sharedModules but were still slim when this cache entry was built.
      // This happens when the user navigated to sub-views that fetched
      // individual modules, then navigated back here.  Without this sync the
      // restored adapter is built from stale slim data and has 0 hyperedges.
      var effectiveJsonString = cached.jsonString;
      if (!isLightSynthesis && widget.netlistJsonMap != null) {
        final sharedMods =
            widget.netlistJsonMap!['modules'] as Map<String, dynamic>?;
        if (sharedMods != null) {
          final localJson =
              jsonDecode(cached.jsonString) as Map<String, dynamic>;
          final localMods = localJson['modules'] as Map<String, dynamic>? ?? {};
          var enriched = false;
          for (final key in localMods.keys.toList()) {
            final localMod = localMods[key] as Map<String, dynamic>;
            final sharedMod = sharedMods[key] as Map<String, dynamic>?;
            if (sharedMod != null &&
                _moduleDataLevel(localMod) < _moduleDataLevel(sharedMod)) {
              localMods[key] = sharedMod;
              enriched = true;
            }
          }
          if (enriched) {
            effectiveJsonString = jsonEncode(localJson);
            debugPrint(
              '[EmbeddedSchematicViewer] Cache restore: enriched '
              'JSON with previously-fetched full modules',
            );
          }
        }
      }

      if (!isLightSynthesis) {
        // 1. Rebuild adapter from (enriched) cached JSON (synchronous, no ELK)
        //    The fresh adapter already has some nodes expanded
        //    (the builder calls expandNonPrimitives on the top module).
        schematicAdapter = NetlistSchematicAdapter.fromJson(
          effectiveJsonString,
        );

        // 2. Reconcile expansion state: the fresh adapter may already
        //    have nodes expanded that differ from the cached state.
        //    We must collapse extras and expand missing ones rather than
        //    blindly toggling, which would invert already-correct state.
        schematicAdapter!.schematic.restoreExpansionSnapshot(
          cached.expansionSnapshot,
        );
      } else {
        debugPrint(
          '[EmbeddedSchematicViewer] Restoring light synthesis '
          'result (no adapter)',
        );
        schematicAdapter = null;
        // Sync the per-scope expansion tracking so that subsequent toggles
        // (via handleNodeToggle override) start from the correct state.
        if (!_lightSynthExpandedNodes.containsKey(_currentModuleId)) {
          _lightSynthExpandedNodes[_currentModuleId] = Set<String>.from(
            cached.expansionSnapshot.fullyExpanded,
          );
        }
      }

      // 3. Update schematicJson (used by canvas for netlist index)
      schematicJson = effectiveJsonString;

      // 4. Show cached layout — create a new layout object so the canvas
      //    detects the change (SchematicLayoutResult uses identity equality,
      //    and the old widget may still hold the same cached object).
      debugPrint('[EmbeddedSchematicViewer] Restoring cached layout');
      final restoredLayout = SchematicLayoutResult(
        instances: cached.layout.instances,
        ports: cached.layout.ports,
        edges: cached.layout.edges,
        width: cached.layout.width,
        height: cached.layout.height,
        exteriorHiddenPortIds: cached.layout.exteriorHiddenPortIds,
        interiorHiddenPortIds: cached.layout.interiorHiddenPortIds,
        unconnectedPortIds: cached.layout.unconnectedPortIds,
        interiorUnconnectedPortIds: cached.layout.interiorUnconnectedPortIds,
      );
      if (!mounted) {
        return;
      }

      // 5. Restore the cached pan/zoom position BEFORE setState so that
      //    _pendingAutoFitSkips is already incremented when didUpdateWidget
      //    fires during the rebuild.  This prevents the auto-fit from
      //    overwriting the restored view position.
      if (cached.viewOffset != null && cached.viewScale != null) {
        _canvasKey.currentState?.setView(
          offset: cached.viewOffset!,
          scale: cached.viewScale!,
        );
      }

      setState(() {
        layout = restoredLayout;
        error = null;
        isLoading = false;
      });
    } on Exception catch (e) {
      debugPrint('[EmbeddedSchematicViewer] Cache restore failed: $e');
      // Fall back to full recomputation
      unawaited(computeLayout(cached.jsonString));
    }
  }

  /// Extract a module subset from the full netlist JSON, cache the JSON
  /// string, and compute layout. Recursively includes the target module
  /// and all transitively referenced cell types so that deeply nested
  /// children remain expandable.
  Future<void> _extractAndComputeFromJson(
    String moduleId,
    Map<String, dynamic> modules,
  ) async {
    setLoading(loading: true);
    try {
      // ── Incremental fetch: ensure the target module has connectivity ──
      // Slim modules (from hierarchySlimJson) have empty netnames and
      // cells without connections. When the fetchModuleNetlist callback
      // is available, request full data before computing layout.
      debugPrint(
        '[INCREMENTAL] _extractAndComputeFromJson: '
        'preparing module "$moduleId" for layout',
      );
      await _ensureModuleConnectivity(moduleId, modules);

      // Collect all transitively needed module keys via BFS, then
      // build neededModules by reading from `modules` at encode time.
      // This avoids capturing stale slim-module references — if a module
      // was fetched full between BFS traversal and encode, we get the
      // full version.
      final neededModules = <String, dynamic>{};

      // BFS queue of module keys whose cell types we still need to visit.
      // IMPORTANT: read module data from `modules` (sharedModules) at
      // encode time, not at BFS traversal time.  Early assignment
      // like `neededModules`cellType` = modules`cellType`` would capture
      // the reference at that moment, which may be a slim placeholder if
      // this BFS runs before `ensureConnectivity` has replaced it.
      // By recording only the keys here and re-reading below, we always
      // get the most-current (possibly full) version.
      final neededKeys = <String>{moduleId};
      final queue = <String>[moduleId];
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        final mod = modules[current] as Map<String, dynamic>?;
        if (mod == null) {
          continue;
        }
        final cells = mod['cells'] as Map<String, dynamic>?;
        if (cells == null) {
          continue;
        }
        for (final cellEntry in cells.values) {
          final cellData = cellEntry as Map<String, dynamic>;
          final cellType = cellData['type'] as String?;
          if (cellType != null &&
              modules.containsKey(cellType) &&
              !neededKeys.contains(cellType)) {
            neededKeys.add(cellType);
            queue.add(cellType);
          }
        }
      }

      // Build neededModules by reading from `modules` fresh (not from
      // the BFS traversal snapshot) so we pick up any full data that
      // was fetched and stored in sharedModules between BFS traversal
      // and encode time.
      for (final key in neededKeys) {
        final modData = modules[key] as Map<String, dynamic>;
        if (key == moduleId) {
          neededModules[key] = {
            ...modData,
            'attributes': {
              ...(modData['attributes'] as Map<String, dynamic>? ?? {}),
              'top': 1,
            },
          };
        } else {
          neededModules[key] = modData;
        }
      }

      final incompleteList = neededModules.entries
          .where((e) => _needsUpgrade(e.value as Map<String, dynamic>))
          .map((e) => e.key)
          .join(', ');
      debugPrint(
        '[EmbeddedSchematicViewer] Computing layout for $moduleId '
        'with ${neededModules.length} modules '
        '(of ${modules.length} total): '
        'incomplete=[$incompleteList]',
      );

      final submoduleJson = {
        'creator': 'EmbeddedSchematicViewer',
        'modules': neededModules,
      };

      final subJsonString = jsonEncode(submoduleJson);

      await computeLayout(subJsonString);

      // Cache the result by instance ID (unique per instance).
      // Also cache by module key as a template for same-type
      // instances that haven't been visited yet.
      if (layout != null) {
        final entry = _CachedModule(
          layout!,
          subJsonString,
          schematicAdapter?.schematic.expansionSnapshot() ??
              const ExpansionSnapshot(
                fullyExpanded: <String>{},
                partials: <String,
                    ({Set<String> childIds, Set<String> edgeIds})>{},
              ),
        );
        if (_currentModuleId != null) {
          _moduleCache[_currentModuleId!] = entry;
        }
        // Also store as type template if not yet present
        if (!_moduleCache.containsKey(moduleId)) {
          _moduleCache[moduleId] = entry;
        }
      }

      debugPrint(
        '[EmbeddedSchematicViewer] Computed and cached layout for: '
        '$moduleId (instance: $_currentModuleId, '
        'cache size: ${_moduleCache.length})',
      );
      // Invalidate the address mapping: computeLayout replaced schematicJson
      // and schematicAdapter with data scoped to this module's sub-JSON.
      // The old mapping (from the previous module's adapter) would contain
      // addresses relative to the previous module hierarchy and must not be
      // used for this view's ensureConnectivity calls.
      _nodeAddrToModuleKey = null;
      setLoading(loading: false);
    } on Exception catch (e, stackTrace) {
      debugPrint('[EmbeddedSchematicViewer] Error computing layout: $e');
      debugPrint('[EmbeddedSchematicViewer] Stack trace: $stackTrace');
      setLoading(loading: false, errorMessage: 'Failed to compute layout: $e');
    }
  }

  /// Fetch full connectivity data for `moduleId` only.
  /// Child modules remain slim until the user drills into them —
  /// they appear as black-box cells and don't need their own internal
  /// connectivity for the parent's schematic layout.
  Future<void> _ensureModuleConnectivity(
    String moduleId,
    Map<String, dynamic> modules,
  ) async {
    if (widget.fetchModuleNetlist == null) {
      debugPrint(
        '[INCREMENTAL] _ensureModuleConnectivity: '
        'no callback — skipping (using full JSON path)',
      );
      return;
    }

    final mod = modules[moduleId] as Map<String, dynamic>?;
    if (mod == null) {
      return;
    }

    if (!_needsUpgrade(mod)) {
      debugPrint('[INCREMENTAL] $moduleId already has full data — skipping');
      return;
    }

    debugPrint('[INCREMENTAL] Fetching full data for slim module: $moduleId');
    final stopwatch = Stopwatch()..start();

    final fullData = await widget.fetchModuleNetlist!(moduleId);
    stopwatch.stop();

    if (fullData != null && fullData.containsKey(moduleId)) {
      final moduleBytes = jsonEncode(fullData[moduleId]).length;
      modules[moduleId] = fullData[moduleId];
      // Also absorb any sibling module definitions returned by the fetch
      // (fetchModuleNetlist may return a full Yosys JSON with multiple
      // module keys).  Adding them to sharedModules (modules) makes them
      // visible to subsequent BFS traversals and address-mapping walks,
      // ensuring that cells referencing these types are properly tracked.
      for (final entry in fullData.entries) {
        if (entry.key != moduleId && !modules.containsKey(entry.key)) {
          modules[entry.key] = entry.value;
        }
      }
      debugPrint(
        '[INCREMENTAL]   ✓ $moduleId: '
        '${(moduleBytes / 1024).toStringAsFixed(1)} KB fetched '
        'in ${stopwatch.elapsedMilliseconds} ms',
      );
    } else {
      debugPrint('[INCREMENTAL]   ✗ $moduleId: fetch returned null');
    }
  }

  /// Determine the data level of a module entry from the JSON.
  ///
  /// Reads the `netlistJsonMode` attribute (tree/slim/full) if present.
  /// Falls back to a heuristic: if cells exist but none have `connections`,
  /// it's slim; if cells exist with connections, it's full; if no cells or
  /// cells are empty stubs, it's tree.
  ///
  /// Returns 0 for tree, 1 for slim, 2 for full.  Higher = more data.
  static int _moduleDataLevel(Map<String, dynamic> moduleData) {
    // Prefer the explicit attribute.
    final attrs = moduleData['attributes'] as Map<String, dynamic>? ?? const {};
    final mode = attrs['netlistJsonMode'] as String?;
    if (mode != null) {
      switch (mode) {
        case 'tree':
          return 0;
        case 'slim':
          return 1;
        case 'full':
          return 2;
      }
    }

    // Heuristic fallback for JSON produced before the attribute was added.
    final cells = moduleData['cells'] as Map<String, dynamic>? ?? {};
    if (cells.isEmpty) {
      // No cells at all — could be tree or a leaf module with no sub-modules.
      // Check if ports/netnames exist to distinguish.
      final ports = moduleData['ports'] as Map<String, dynamic>? ?? {};
      final netnames = moduleData['netnames'] as Map<String, dynamic>? ?? {};
      if (ports.isEmpty && netnames.isEmpty) {
        return 0; // tree
      }
      return 2; // full (leaf module — nothing more to fetch)
    }
    for (final cellEntry in cells.values) {
      final cell = cellEntry as Map<String, dynamic>;
      if (cell.containsKey('connections')) {
        return 2; // full
      }
    }
    return 1; // slim (cells exist but lack connections)
  }

  /// Data level constants for readability.
  static const int _levelTree = 0;
  static const int _levelSlim = 1;
  static const int _levelFull = 2;

  /// Whether a module needs connectivity data for wire-level operations.
  ///
  /// Returns `true` if the module's data level is below `_levelFull`.
  static bool _needsUpgrade(Map<String, dynamic> moduleData) =>
      _moduleDataLevel(moduleData) < _levelFull;

  // ── Incremental connectivity support ───────────────────────────────
  //
  // Lazily built mapping: adapter node address ("0.1.3") → Yosys module key
  // (e.g. "FloatingPointAdderDualPath_E8M23"). Mirrors the address
  // assignment in _SchematicGraphBuilder._fillChildren so we can look up
  // which module key is needed for any node the user interacts with.
  Map<String, String>? _nodeAddrToModuleKey;

  /// Walk the adapter JSON's module hierarchy in the same cell-iteration
  /// order as the adapter builder to produce address → module-key pairs.
  ///
  /// Uses `sharedModules` (the full 129-module global map) to recognise
  /// module instances whose data has not yet been fetched into the local
  /// extracted JSON.  Those cells are mapped to their type but not
  /// recursed into (no local data to walk), which lets `ensureConnectivity`
  /// resolve them and fetch on demand.
  void _rebuildNodeAddrMapping() {
    if (schematicJson == null) {
      _nodeAddrToModuleKey = null;
      return;
    }
    final json = jsonDecode(schematicJson!) as Map<String, dynamic>;
    final localModules = json['modules'] as Map<String, dynamic>?;
    if (localModules == null) {
      _nodeAddrToModuleKey = null;
      return;
    }

    // All known module types (including slim/unfetched ones).
    final allModules =
        widget.netlistJsonMap?['modules'] as Map<String, dynamic>? ??
            localModules;

    final mapping = <String, String>{};

    // Find the top module key.
    String? topKey;
    for (final entry in localModules.entries) {
      final attrs = (entry.value as Map<String, dynamic>)['attributes']
          as Map<String, dynamic>?;
      if (attrs?['top'] == 1) {
        topKey = entry.key;
        break;
      }
    }
    topKey ??= localModules.keys.first;

    void walk(String moduleKey, String addr) {
      mapping[addr] = moduleKey;
      // Look up the module data in localModules first, then allModules.
      // Using allModules for recursion ensures we map deep-nested addresses
      // even when their parent module hasn't been fetched into the local
      // (per-view) JSON yet.  The child cells' ordering in the global JSON
      // matches the adapter's _fillChildren iteration order.
      final mod = (localModules[moduleKey] ?? allModules[moduleKey])
          as Map<String, dynamic>?;
      if (mod == null) {
        return;
      }
      final cells = mod['cells'] as Map<String, dynamic>? ?? {};
      // Iterate cells in natural insertion order — must match
      // NetlistSchematicAdapter._fillChildren (no sorting).
      var childIdx = 0;
      for (final cellEntry in cells.entries) {
        final cellName = cellEntry.key;
        final cellData = cellEntry.value as Map<String, dynamic>;
        final cellType = cellData['type'] as String?;
        final childAddr = '$addr.$childIdx';
        // Include cells whose type is in allModules OR in localModules.
        // A cell may be in localModules (neededModules) but temporarily
        // absent from allModules if sharedModules was not yet updated
        // (e.g., from a fetchModuleNetlist response that returned extra
        // module types not present in the initial 129-module slim JSON).
        final inAll = cellType != null && allModules.containsKey(cellType);
        final inLocal = cellType != null && localModules.containsKey(cellType);
        if (inAll || inLocal) {
          // Also map by instance name as a fallback.  With address-based ELK
          // node IDs the canvas now sends addresses (e.g. "0.0.0") to
          // ensureConnectivity, so the primary lookup is the address key set
          // by walk().  The instance-name key here lets legacy / test paths
          // still resolve "sum" → Sum_1_W4 when only a name is available.
          // Note: instance names are NOT globally unique (two modules at
          // different depths may both have a cell named "sum"), so the address
          // key is always preferred.
          mapping[cellName] = cellType;
          // Recurse: walk() already looks up in allModules, so we map
          // deep-nested addresses even for globally-known-but-not-yet-
          // locally-fetched modules.
          walk(cellType, childAddr);
        } else if (kDebugMode && cellType != null) {
          // Log unmapped cells around the failing addresses so we can
          // diagnose discrepancies between the mapping walk and the adapter.
          final node = schematicAdapter?.schematic.nodeMap[childAddr];
          if (node != null && node.isExpandable) {
            debugPrint(
              '[AddrMap] UNMAPPED EXPANDABLE cell: '
              '$childAddr type=$cellType '
              'instanceName=${node.hwMeta.name}',
            );
          }
        }
        childIdx++;
      }
    }

    // Also map the top module's definition name to itself.  When the top
    // block is clicked in the canvas its node ID equals the module definition
    // name (e.g. "Counter_L1_"), not the dot-separated address "0".
    mapping[topKey] = topKey;
    walk(topKey, '0');
    _nodeAddrToModuleKey = mapping;
  }

  @override
  bool needsConnectivity(String nodeId) {
    final sharedModules = _sharedModulesOrNull;
    if (sharedModules == null) {
      return false;
    }
    if (_nodeAddrToModuleKey == null) {
      _rebuildNodeAddrMapping();
    }
    final moduleKey = _nodeAddrToModuleKey?[nodeId];
    if (moduleKey == null) {
      return false;
    }
    final mod = sharedModules[moduleKey];
    if (mod != null && _needsUpgrade(mod as Map<String, dynamic>)) {
      return true;
    }
    // Also check the current view's top module — if it is slim the user
    // will see 0 edges until it is fetched, so show the spinner.
    final viewModuleKey = _instanceIdToModuleKey[_currentModuleId];
    if (viewModuleKey != null) {
      final viewMod = sharedModules[viewModuleKey];
      if (viewMod != null && _needsUpgrade(viewMod as Map<String, dynamic>)) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<bool> ensureConnectivity(String nodeId) async {
    final sharedModules = _sharedModulesOrNull;
    if (sharedModules == null) {
      debugPrint(
        '[INCREMENTAL] ensureConnectivity($nodeId): '
        'prerequisites not met — skipping',
      );
      return false;
    }

    // Build address → moduleKey mapping lazily.
    if (_nodeAddrToModuleKey == null) {
      _rebuildNodeAddrMapping();
    }
    if (_nodeAddrToModuleKey == null) {
      debugPrint(
        '[INCREMENTAL] ensureConnectivity($nodeId): '
        'address mapping is null after rebuild — skipping',
      );
      return false;
    }

    // Determine which module key the user is interacting with.
    final moduleKey = _nodeAddrToModuleKey![nodeId];
    if (moduleKey == null) {
      // Fallback: look up the node in the adapter graph to get its type.
      // Address mismatches can occur when the mapping was built from JSON
      // whose cell ordering differs from the adapter's node IDs (e.g.
      // after module navigations that rebuild the adapter from a sub-JSON).
      final graphNode = schematicAdapter?.schematic.nodeMap[nodeId];
      if (graphNode != null) {
        final hid = graphNode.hierarchyNodeId;
        if (hid != null) {
          // Try to resolve the type from the hierarchy node's path.
          final typeName = _resolveModuleKeyFromHierarchy(hid);
          if (typeName != null && sharedModules.containsKey(typeName)) {
            debugPrint(
              '[INCREMENTAL] ensureConnectivity($nodeId): '
              'address not in mapping, but resolved type=$typeName '
              'via hierarchy fallback',
            );
            // Proceed with the resolved type as module key.
            final connected = await _ensureConnectivityForKey(
              nodeId,
              typeName,
              sharedModules,
            );
            return connected;
          }
        }
      }
      debugPrint(
        '[INCREMENTAL] ensureConnectivity($nodeId): '
        'no moduleKey for nodeId. '
        'Known addresses: ${_nodeAddrToModuleKey!.keys.toList()}',
      );
      return false;
    }

    final connected = await _ensureConnectivityForKey(
      nodeId,
      moduleKey,
      sharedModules,
    );
    return connected;
  }

  /// Resolve a hierarchy path (e.g. "TopModule/sub0/x")
  /// to its module type name using the external hierarchy service.
  String? _resolveModuleKeyFromHierarchy(String hierarchyPath) {
    final hierarchy = widget.externalHierarchy;
    if (hierarchy == null) {
      return null;
    }
    final segments = hierarchyPath.split('/');
    HierarchyOccurrence? current = hierarchy.root;
    // Walk the hierarchy tree following the path segments.
    for (var i = 1; i < segments.length && current != null; i++) {
      final seg = segments[i];
      HierarchyOccurrence? next;
      for (final child in current.children) {
        if (child.name == seg || child.path().endsWith('/$seg')) {
          next = child;
          break;
        }
      }
      current = next;
    }
    return current?.definition;
  }

  /// Shared connectivity-fetch logic used by both the address-map path
  /// and the hierarchy-fallback path.
  Future<bool> _ensureConnectivityForKey(
    String nodeId,
    String moduleKey,
    Map<String, dynamic> sharedModules,
  ) async {
    // Fetch the child module being expanded so its internal edges appear.
    // Also fetch the current view's top-level module if it is still slim:
    // its netnames define connections between its direct children, so it
    // must be full before any inter-cell edge can appear in this view.
    final toFetch = <String>{};
    if (sharedModules.containsKey(moduleKey) &&
        _needsUpgrade(sharedModules[moduleKey] as Map<String, dynamic>)) {
      toFetch.add(moduleKey);
    }
    // Top/current module check.
    final viewModuleKey = _instanceIdToModuleKey[_currentModuleId];
    if (viewModuleKey != null &&
        viewModuleKey != moduleKey &&
        sharedModules.containsKey(viewModuleKey) &&
        _needsUpgrade(sharedModules[viewModuleKey] as Map<String, dynamic>)) {
      toFetch.add(viewModuleKey);
    }

    if (toFetch.isEmpty) {
      // sharedModules is current, but the adapter JSON may be stale
      // (built when these modules were still slim). Detect and force a
      // rebuild using the already-full data in sharedModules.
      if (schematicJson != null) {
        final currentJson = jsonDecode(schematicJson!) as Map<String, dynamic>;
        final currentModules = currentJson['modules'] as Map<String, dynamic>?;
        if (currentModules != null) {
          final staleInAdapter = <String>{};
          if (currentModules.containsKey(moduleKey) &&
              _needsUpgrade(
                currentModules[moduleKey] as Map<String, dynamic>,
              )) {
            staleInAdapter.add(moduleKey);
          }
          if (viewModuleKey != null &&
              viewModuleKey != moduleKey &&
              currentModules.containsKey(viewModuleKey) &&
              _needsUpgrade(
                currentModules[viewModuleKey] as Map<String, dynamic>,
              )) {
            staleInAdapter.add(viewModuleKey);
          }
          if (staleInAdapter.isNotEmpty) {
            debugPrint(
              '[INCREMENTAL] ensureConnectivity($nodeId): '
              'adapter JSON stale for $staleInAdapter '
              '— rebuilding from sharedModules (no fetch)',
            );
            final rebuilt = await _fetchModulesAndRebuild(
              staleInAdapter,
              sharedModules,
            );
            return rebuilt;
          }
        }
      }
      debugPrint(
        '[INCREMENTAL] ensureConnectivity($nodeId): '
        'moduleKey=$moduleKey, viewModuleKey=$viewModuleKey '
        '— both full in sharedModules, nothing to fetch',
      );
      return false;
    }

    debugPrint(
      '[INCREMENTAL] ensureConnectivity($nodeId): '
      'fetching ${toFetch.length} slim module(s): $toFetch',
    );

    final rebuilt = await _fetchModulesAndRebuild(toFetch, sharedModules);
    return rebuilt;
  }

  // ── Shared incremental-fetch infrastructure ────────────────────────

  /// Return the shared modules map when all prerequisites for incremental
  /// fetching are met, or `null` when fetching should be skipped.
  Map<String, dynamic>? get _sharedModulesOrNull {
    if (widget.fetchModuleNetlist == null ||
        widget.netlistJsonMap == null ||
        schematicJson == null) {
      return null;
    }
    return widget.netlistJsonMap!['modules'] as Map<String, dynamic>?;
  }

  /// Fetch full connectivity for the modules in `toFetch`, merge results
  /// into `sharedModules` and the current adapter JSON, BFS-walk
  /// transitively referenced types, then rebuild the adapter preserving
  /// the current expansion state.
  ///
  /// This is the shared back-end used by both `ensureConnectivity`
  /// (single-node) and `_ensureAllModuleConnectivity` (recursive).
  Future<bool> _fetchModulesAndRebuild(
    Set<String> toFetch,
    Map<String, dynamic> sharedModules,
  ) async {
    // Fetch each needed module, skipping any that are already full in
    // sharedModules (e.g. stale-adapter rebuilds triggered from the
    // toFetch.isEmpty branch above).
    for (final key in toFetch) {
      if (sharedModules.containsKey(key) &&
          !_needsUpgrade(sharedModules[key] as Map<String, dynamic>)) {
        debugPrint(
          '[INCREMENTAL]   ↩ $key already full in sharedModules, '
          'skipping fetch',
        );
        continue;
      }
      final fullData = await widget.fetchModuleNetlist!(key);
      if (fullData != null && fullData.containsKey(key)) {
        sharedModules[key] = fullData[key];
        // Absorb any sibling module definitions in the response into
        // sharedModules so that the address mapping and BFS can find them.
        for (final entry in fullData.entries) {
          if (entry.key != key && !sharedModules.containsKey(entry.key)) {
            sharedModules[entry.key] = entry.value;
          }
        }
        debugPrint('[INCREMENTAL]   ✓ $key fetched');
      } else {
        debugPrint('[INCREMENTAL]   ✗ $key: fetch returned null');
      }
    }

    // Replace slim module entries with full connectivity data in the
    // current adapter JSON.  Full-mode synthesis may produce extra cells
    // (constant generators, passthrough buffers) that reference module
    // types not yet present in the extracted JSON.
    final currentJson = jsonDecode(schematicJson!) as Map<String, dynamic>;
    final currentModules = currentJson['modules'] as Map<String, dynamic>;
    for (final key in toFetch) {
      if (sharedModules.containsKey(key)) {
        currentModules[key] = sharedModules[key];
      }
    }

    // BFS: ensure all transitively referenced module types are present
    // so the adapter can build them and the address mapping can walk
    // into them.
    final bfsQueue = <String>[...toFetch];
    final visited = <String>{...currentModules.keys};
    while (bfsQueue.isNotEmpty) {
      final current = bfsQueue.removeAt(0);
      final mod = currentModules[current] as Map<String, dynamic>?;
      if (mod == null) {
        continue;
      }
      final cells = mod['cells'] as Map<String, dynamic>? ?? {};
      for (final cellEntry in cells.values) {
        final cellData = cellEntry as Map<String, dynamic>;
        final cellType = cellData['type'] as String?;
        if (cellType != null &&
            !visited.contains(cellType) &&
            sharedModules.containsKey(cellType)) {
          currentModules[cellType] = sharedModules[cellType];
          visited.add(cellType);
          bfsQueue.add(cellType);
          debugPrint('[INCREMENTAL]   + added referenced module: $cellType');
        }
      }
    }

    final enrichedJson = jsonEncode(currentJson);

    // Rebuild the adapter from enriched JSON, preserving expansion state.
    final snapshot = schematicAdapter?.schematic.expansionSnapshot();
    debugPrint(
      '[INCREMENTAL] Rebuilding adapter from enriched JSON '
      '(${enrichedJson.length} chars)',
    );
    schematicAdapter = NetlistSchematicAdapter.fromJson(enrichedJson);
    schematicJson = enrichedJson;

    if (snapshot != null) {
      schematicAdapter!.schematic.restoreExpansionSnapshot(snapshot);
    }

    // Invalidate the address mapping so it's rebuilt from the enriched JSON.
    _nodeAddrToModuleKey = null;

    debugPrint('[INCREMENTAL] Adapter rebuilt with connectivity');

    // Notify parent so it can re-create evaluators with full connectivity.
    widget.onNetlistEnriched?.call(currentJson);

    return true;
  }

  @override
  // Use memoized theme cubit to prevent recreation on every rebuild
  Widget build(BuildContext context) =>
      BlocProvider.value(value: _themeCubit, child: _buildBody());

  Widget _buildBody() {
    debugPrint(
      '[_buildBody] isLoading=$isLoading, error=$error, '
      'layout=${layout != null}, '
      'instances=${layout?.instances.length ?? -1}, '
      'edges=${layout?.edges.length ?? -1}, '
      'isToggling=$isToggling, '
      'currentModuleId=$_currentModuleId',
    );

    if (isLoading) {
      return buildLoadingIndicator();
    }

    if (error != null) {
      return buildErrorDisplay();
    }

    if (layout == null ||
        (layout!.instances.isEmpty && layout!.edges.isEmpty)) {
      debugPrint('[_buildBody] *** EMPTY STATE HIT ***');
      debugPrint('[_buildBody]   layout == null: ${layout == null}');
      if (layout != null) {
        debugPrint(
          '[_buildBody]   instances.isEmpty: '
          '${layout!.instances.isEmpty}',
        );
        debugPrint('[_buildBody]   edges.isEmpty: ${layout!.edges.isEmpty}');
      }
      debugPrint(
        '[_buildBody]   externalHierarchy != null: '
        '${widget.externalHierarchy != null}',
      );
      debugPrint('[_buildBody]   Stack trace:');
      debugPrint(StackTrace.current.toString());
      // When using external hierarchy, show appropriate message
      if (widget.externalHierarchy != null) {
        return buildEmptyState(
          title: 'Using shared hierarchy',
          subtitle: 'Waiting for schematic data.',
        );
      }
      return buildEmptyState(
        title: 'No schematic data',
        subtitle: 'Could not load schematic.',
      );
    }

    return buildSchematicCanvas(canvasKey: _canvasKey);
  }
}
