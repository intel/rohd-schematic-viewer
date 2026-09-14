// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// flutter_schematic_viewer_page.dart
// Minimal page for VS Code extension: renders Flutter CustomPaint only.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show
        DiagnosticPropertiesBuilder,
        DiagnosticsProperty,
        StringProperty,
        kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';
import 'package:rohd_schematic_viewer/src/schematic/netlist_schematic_adapter.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_engine.dart';
import 'package:rohd_schematic_viewer/src/services/vscode_extension_client.dart'
    show RohdExtensionClient, RohdModuleInfo, createVscodeExtensionClient;
import 'package:rohd_schematic_viewer/src/services/vscode_webview_interop_stub.dart'
    if (dart.library.js_interop) '../services/vscode_webview_interop_web.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';
import 'package:rohd_source_navigator/flc_data.dart';

/// VS Code webview operations used by [FlutterSchematicViewerPage].
///
/// The default implementation delegates to browser interop. Specialized hosts
/// and widget tests can provide the same lifecycle without browser globals.
class FlutterSchematicExtensionHost {
  /// Whether the page is hosted in a VS Code webview.
  final bool isWebview;

  /// Requests that the extension reload the schematic from disk.
  final bool Function() requestReload;

  /// Registers callbacks for extension-pushed webview messages.
  final void Function({
    required void Function(String jsonData) onReload,
    void Function(String error)? onError,
    void Function({required bool canSendSignals})? onSignalViewerAvailability,
    void Function(List<String> signalPaths)? onIncomingSignals,
  }) listenForMessages;

  /// Announces that this webview can participate in signal cross-probing.
  final bool Function() notifySignalViewerReady;

  /// Sends selected signal paths through the VS Code signal-viewer bus.
  final bool Function({required List<String> signalPaths}) sendSignals;

  /// Creates a VS Code webview host boundary.
  const FlutterSchematicExtensionHost({
    required this.isWebview,
    required this.requestReload,
    required this.listenForMessages,
    this.notifySignalViewerReady = postSignalViewerReady,
    this.sendSignals = postSendSignals,
  });
}

final _defaultExtensionHost = FlutterSchematicExtensionHost(
  isWebview: kIsWeb && isVscodeWebview(),
  requestReload: requestReloadFromDisk,
  listenForMessages: listenForExtensionMessages,
);

/// Minimal page for the VS Code extension environment.
/// - No tabs
/// - No file picker
/// - Uses injected JSON from the webview
class FlutterSchematicViewerPage extends StatefulWidget {
  /// Constructor for [FlutterSchematicViewerPage].
  const FlutterSchematicViewerPage({
    this.initialSchematicJson,
    this.layoutEngine,
    this.extensionHost,
    this.extensionClient,
    super.key,
  });

  /// Optional injected netlist JSON for specialized hosts and widget tests.
  final String? initialSchematicJson;

  /// Optional layout engine override for specialized hosts and widget tests.
  final SchematicLayoutEngine? layoutEngine;

  /// Optional VS Code webview host boundary for specialized hosts and tests.
  final FlutterSchematicExtensionHost? extensionHost;

  /// Optional extension client override for specialized hosts and tests.
  final RohdExtensionClient? extensionClient;

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
      )
      ..add(
        DiagnosticsProperty<FlutterSchematicExtensionHost?>(
          'extensionHost',
          extensionHost,
        ),
      )
      ..add(
        DiagnosticsProperty<RohdExtensionClient?>(
          'extensionClient',
          extensionClient,
        ),
      );
  }

  @override
  State<FlutterSchematicViewerPage> createState() =>
      _FlutterSchematicViewerPageState();
}

class _FlutterSchematicViewerPageState
    extends BaseSchematicViewerState<FlutterSchematicViewerPage> {
  /// Extension client created in [initState] when running in VS Code webview.
  RohdExtensionClient? _extensionClient;

  bool _appBarPinned = true;
  final _canvasKey = GlobalKey<SchematicCanvasState>();
  final _incomingSignals = ValueNotifier<List<String>?>(null);
  var _canSendSignals = false;

  /// Latest module info from the extension (null until first query).
  RohdModuleInfo? _moduleInfo;

  FlutterSchematicExtensionHost get _extensionHost =>
      widget.extensionHost ?? _defaultExtensionHost;

  @override
  SchematicLayoutEngine createLayoutEngine() =>
      widget.layoutEngine ?? super.createLayoutEngine();

  @override
  void initState() {
    super.initState();
    if (_extensionHost.isWebview) {
      _extensionClient =
          widget.extensionClient ?? createVscodeExtensionClient();
      unawaited(_extensionClient!.ping());
      _extensionClient!.currentModuleInfo.addListener(_onModuleInfoChanged);
    }
  }

  @override
  void dispose() {
    _extensionClient?.currentModuleInfo.removeListener(_onModuleInfoChanged);
    _extensionClient?.dispose();
    _extensionClient = null;
    _incomingSignals.dispose();
    super.dispose();
  }

  void _onModuleInfoChanged() {
    final info = _extensionClient?.currentModuleInfo.value;
    debugPrint(
      '[FlutterSchematicViewerPage] _moduleInfo changed: '
      'hasRohd=${info?.hasRohd}, hasSv=${info?.hasSv}',
    );
    if (mounted) {
      setState(() => _moduleInfo = info);
    }
  }

  @override
  GoToSourceCallback? get onGoToSource {
    if (!_extensionHost.isWebview) {
      return null;
    }
    return (format, paths) => _handleGoToSource(paths, format: format.name);
  }

  @override
  AvailableSourceFormats? get availableSourceFormats {
    if (_extensionClient == null &&
        (schematicAdapter?.embeddedFlcData.isEmpty ?? true)) {
      return null;
    }
    return () {
      final extensionFormats = resolveNavigableFormats(_moduleInfo);
      if (extensionFormats.isNotEmpty) {
        return extensionFormats;
      }
      return _embeddedSourceFormats();
    };
  }

  List<RohdSourceFormat> _embeddedSourceFormats() {
    final data = schematicAdapter?.embeddedFlcData;
    if (data == null || data.isEmpty) {
      return const [];
    }
    final moduleName = _topModuleName(schematicAdapter!);
    final formats = <String>{};
    for (final signalName in data.signalNamesFor(moduleName)) {
      for (final frame
          in data.lookupSignal(moduleName, signalName) ?? const <FlcFrame>[]) {
        formats.add(frame.type);
      }
    }
    for (final instanceName in data.instanceNamesFor(moduleName)) {
      for (final frame in data.lookupInstance(moduleName, instanceName) ??
          const <FlcFrame>[]) {
        formats.add(frame.type);
      }
    }
    return [
      if (formats.contains('rohd')) RohdSourceFormat.rohd,
      if (formats.contains('sv')) RohdSourceFormat.sv,
    ];
  }

  @override
  void Function(List<String> signalPaths)? get onSendSignals {
    if (!_extensionHost.isWebview || !_canSendSignals) {
      return null;
    }
    return (signalPaths) {
      _extensionHost.sendSignals(signalPaths: signalPaths);
    };
  }

  @override
  bool get hasExternalSignalListeners =>
      _extensionHost.isWebview && _canSendSignals;

  @override
  ValueNotifier<List<String>?>? get incomingSignalPaths =>
      _extensionHost.isWebview ? _incomingSignals : null;

  void _handleGoToSource(List<String> signalPaths, {String? format}) {
    // Parse wire paths into (module, signal) pairs.
    // Path format: "ModuleName/signalName" or just "signalName".
    final signals = <Map<String, String>>[];
    for (final path in signalPaths) {
      final parts = path.split('/');
      final signalName = parts.last;
      if (parts.length >= 2) {
        final moduleName = parts[parts.length - 2];
        signals.add({'module': moduleName, 'name': signalName});
      } else {
        signals.add({'module': '', 'name': signalName});
      }
    }

    if (signals.isEmpty) {
      return;
    }

    final client = _extensionClient;
    if (client == null) {
      return;
    }

    // Prefer the extension result (which can include waveform/FLC formats).
    // If no sidecar is available, use the source locations embedded in the
    // parsed netlist instead.
    unawaited(
      client.lookupSignalFrames(signals: signals, format: format).then((
        frames,
      ) {
        if (!mounted) {
          return;
        }
        if (frames.isEmpty) {
          frames = _lookupEmbeddedFrames(signals, format);
        }
        if (frames.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No source locations found'),
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }

        if (frames.length == 1) {
          // Single frame — navigate directly.
          final f = frames.first;
          client.openSourceLocation(
            file: f['file'] as String? ?? '',
            line: f['line'] as int? ?? 0,
            col: f['col'] as int? ?? 0,
          );
        } else {
          // Multiple frames — show selection popup.
          _showFrameSelectionPopup(frames);
        }
      }),
    );
  }

  List<Map<String, dynamic>> _lookupEmbeddedFrames(
    List<Map<String, String>> signals,
    String? format,
  ) {
    final data = schematicAdapter?.embeddedFlcData;
    if (data == null) {
      return const [];
    }
    final frames = <Map<String, dynamic>>[];
    for (final signal in signals) {
      final requestedModule = signal['module'] ?? '';
      final name = signal['name'] ?? '';
      final modules = requestedModule.isEmpty
          ? data.moduleNames
          : <String>{requestedModule};
      for (final module in modules) {
        final entry = data.lookupSignalEntry(module, name) ??
            data.lookupInstanceEntry(module, name);
        if (entry == null) {
          continue;
        }
        var foundForSignal = false;
        for (final frame in entry.allFrames) {
          if (format != null && frame.type != format) {
            continue;
          }
          frames.add(_embeddedFrameJson(frame, name));
          foundForSignal = true;
        }
        if (foundForSignal) {
          break;
        }
      }
    }
    return frames;
  }

  Map<String, dynamic> _embeddedFrameJson(FlcFrame frame, String name) => {
        'file': frame.file,
        'line': frame.line,
        'col': frame.column,
        'desc': '$name [ROHD]',
        'type': frame.type,
      };

  /// Show a popup menu listing available source frames for user selection.
  void _showFrameSelectionPopup(List<Map<String, dynamic>> frames) {
    // Build menu items with file:line labels.
    final items = <PopupMenuEntry<int>>[];
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final file = (f['file'] as String? ?? '').split('/').last;
      final line = f['line'] as int? ?? 0;
      final desc = f['desc'] as String? ?? '';
      final type = f['type'] as String? ?? '';
      final label = desc.isNotEmpty
          ? '$file:$line  $desc'
          : '$file:$line${type.isNotEmpty ? '  [$type]' : ''}';
      items.add(
        PopupMenuItem<int>(
          value: i,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    // Use the center of the screen as a fallback position.
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final size = overlay.size;
    final rect = RelativeRect.fromLTRB(
      size.width / 3,
      size.height / 3,
      size.width / 3,
      size.height / 3,
    );

    unawaited(
      showMenu<int>(context: context, position: rect, items: items).then((idx) {
        if (idx == null) {
          return;
        }
        final f = frames[idx];
        _extensionClient?.openSourceLocation(
          file: f['file'] as String? ?? '',
          line: f['line'] as int? ?? 0,
          col: f['col'] as int? ?? 0,
        );
      }),
    );
  }

  @override
  Future<void> loadInitialSchematic() async {
    // Set up message listener so the VS Code extension can push fresh data
    if (_extensionHost.isWebview) {
      _extensionHost.listenForMessages(
        onReload: (jsonData) async {
          if (!mounted) {
            return;
          }
          await computeLayout(jsonData);
          _queryCurrentModule();
        },
        onError: (err) {
          if (!mounted) {
            return;
          }
          setLoading(loading: false, errorMessage: 'Reload failed: $err');
        },
        onSignalViewerAvailability: ({required canSendSignals}) {
          if (mounted) {
            setState(() => _canSendSignals = canSendSignals);
          }
        },
        onIncomingSignals: (signalPaths) {
          if (mounted) {
            _incomingSignals.value = signalPaths;
          }
        },
      );
      _extensionHost.notifySignalViewerReady();
    }
    await _loadInjectedSchematic();
  }

  /// Returns the real top module name (first child of the synthetic root
  /// wrapper), which matches the FLC module keys.
  String _topModuleName(NetlistSchematicAdapter adapter) {
    final root = adapter.schematic.root;
    if (root.children.isNotEmpty) {
      return root.children.first.hwMeta.name;
    }
    return root.hwMeta.name;
  }

  /// Queries the extension for format availability of the currently loaded
  /// module. Called after each successful layout computation so [_moduleInfo]
  /// stays current.
  void _queryCurrentModule() {
    final adapter = schematicAdapter;
    if (adapter == null || _extensionClient == null) {
      debugPrint(
        '[FlutterSchematicViewerPage] _queryCurrentModule: '
        'adapter=${adapter != null}, client=${_extensionClient != null}',
      );
      return;
    }
    final moduleName = _topModuleName(adapter);
    debugPrint(
      '[FlutterSchematicViewerPage] _queryCurrentModule: '
      'querying "$moduleName"',
    );
    unawaited(
      _extensionClient!.queryModule(moduleName).then((info) {
        debugPrint(
          '[FlutterSchematicViewerPage] _queryCurrentModule result: '
          'hasRohd=${info.hasRohd}, hasSv=${info.hasSv}, error=${info.error}',
        );
        if (!mounted) {
          return;
        }
        setState(() => _moduleInfo = info);
        // If the query errored (e.g. rohd extension not yet activated),
        // retry once after a short delay to handle the race condition.
        if (info.error != null) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              _queryCurrentModule();
            }
          });
        }
      }),
    );
  }

  @override
  void handleReload() {
    // In VS Code webview, ask the extension to re-read the file from disk
    if (_extensionHost.isWebview && _extensionHost.requestReload()) {
      setLoading(loading: true);
      return;
    }
    // Fallback: re-process the in-memory JSON
    super.handleReload();
  }

  Future<void> _loadInjectedSchematic() async {
    setLoading(loading: true);

    try {
      final initialJson = widget.initialSchematicJson;
      if (initialJson != null) {
        setFileName('Provided schematic');
        await computeLayout(initialJson);
        _queryCurrentModule();
        return;
      }

      if (!kIsWeb) {
        setLoading(
          loading: false,
          errorMessage: 'VS Code webview not detected',
        );
        return;
      }

      final injectedJson = getInjectedSchematicJson();
      if (injectedJson == null || injectedJson.isEmpty) {
        setLoading(
          loading: false,
          errorMessage: 'No schematic injected by extension',
        );
        return;
      }

      await computeLayout(injectedJson);
      _queryCurrentModule();
    } on Exception catch (e) {
      setLoading(loading: false, errorMessage: 'Failed to load schematic: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: AppBarOverlay(
          autoHide: !_appBarPinned && layout != null,
          appBar: buildAppBar(
            context: context,
            appBarPinned: _appBarPinned,
            onAppBarPinnedChanged: _setAppBarPinned,
          ),
          body: _buildBody(),
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
        title: 'No schematic loaded',
        subtitle: 'Extension did not inject JSON.',
      );
    }

    return buildSchematicCanvas(canvasKey: _canvasKey);
  }
}
