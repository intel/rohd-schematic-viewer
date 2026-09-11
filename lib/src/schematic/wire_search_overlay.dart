// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// wire_search_overlay.dart
// Search overlay for finding blocks and wires in the schematic.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_hierarchy/rohd_hierarchy.dart';
import 'package:rohd_schematic_viewer/src/services/services.dart';
import 'package:rohd_schematic_viewer/src/ui/base_schematic_viewer_page.dart';

/// A combined search result that can be either a module or a signal.
///
/// Modules are listed before signals so that block matches appear first.
class _SearchResult {
  /// The underlying module result, if this is a module match.
  final OccurrenceSearchResult? module;

  /// The underlying signal result, if this is a signal match.
  final SignalSearchResult? signal;

  _SearchResult.fromModule(OccurrenceSearchResult this.module) : signal = null;
  _SearchResult.fromSignal(SignalSearchResult this.signal) : module = null;

  /// Whether this result represents a module/block.
  bool get isModule => module != null;

  /// Display path (top-level module stripped).
  String get displayPath =>
      isModule ? module!.displayPath : signal!.displayPath;

  /// Display segments (top-level module stripped).
  List<String> get displaySegments =>
      isModule ? module!.displaySegments : signal!.displaySegments;
}

/// Search overlay widget that appears when user presses CTRL-F.
///
/// Searches both blocks (modules) and wires (signals), with blocks
/// listed first in the results.
class WireSearchOverlay extends StatefulWidget {
  /// Schematic layout data to search within.
  final SchematicLayoutResult layout;

  /// Callback when the overlay should be closed.
  final VoidCallback onClose;

  /// Callback when a wire is selected from the search results.
  final void Function(String wireId, List<String> pathInstanceNames)
      onWireSelected;

  /// Callback when a module/block is selected from the search results.
  ///
  /// `moduleId` is the full hierarchical path (e.g. "Top/CPU/ALU").
  /// `pathInstanceNames` are the instance names to expand to reach it.
  final void Function(String moduleId, List<String> pathInstanceNames)?
      onModuleSelected;

  /// Optional hierarchy service for searching.
  final HierarchyService? hierarchy;

  /// Constructor for `WireSearchOverlay`.
  const WireSearchOverlay({
    required this.layout,
    required this.onClose,
    required this.onWireSelected,
    super.key,
    this.onModuleSelected,
    this.hierarchy,
  });

  @override
  State<WireSearchOverlay> createState() => _WireSearchOverlayState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<SchematicLayoutResult>('layout', layout))
      ..add(ObjectFlagProperty<VoidCallback>.has('onClose', onClose))
      ..add(
        ObjectFlagProperty<void Function(String, List<String>)>.has(
          'onWireSelected',
          onWireSelected,
        ),
      )
      ..add(
        ObjectFlagProperty<void Function(String, List<String>)?>.has(
          'onModuleSelected',
          onModuleSelected,
        ),
      )
      ..add(DiagnosticsProperty<HierarchyService?>('hierarchy', hierarchy));
  }
}

class _WireSearchOverlayState extends State<WireSearchOverlay> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  final _textScrollController = ScrollController();

  /// Combined search results (modules first, then signals).
  List<_SearchResult> _results = [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    _textController.addListener(_onSearchChanged);
  }

  @override
  void didUpdateWidget(covariant WireSearchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hierarchy != widget.hierarchy) {
      _onSearchChanged(); // re-run with new hierarchy
    }
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onSearchChanged)
      ..dispose();
    _focusNode.dispose();
    _textScrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      final query = _textController.text;
      if (query.isEmpty) {
        _results = [];
        _selectedIndex = 0;
        return;
      }

      final hierarchy = widget.hierarchy;
      if (hierarchy == null) {
        _results = [];
        _selectedIndex = 0;
        return;
      }

      // When the query contains glob/regex metacharacters, skip the
      // dot → slash normalisation so that `.` keeps its regex meaning
      // (e.g. `.*` stays `.*` instead of becoming `/*`).
      final normalized = HierarchyService.hasRegexChars(query)
          ? query
          : query.replaceAll('.', '/');

      // Search both modules and signals; modules come first.
      final modules = hierarchy.searchOccurrences(normalized);
      final signals = hierarchy.searchSignals(normalized);

      _results = [
        for (final m in modules) _SearchResult.fromModule(m),
        for (final s in signals) _SearchResult.fromSignal(s),
      ];
      _selectedIndex = 0;
    });
  }

  bool get _hasResults => _results.isNotEmpty;

  String get _counterText =>
      _hasResults ? '${_selectedIndex + 1}/${_results.length}' : '';

  _SearchResult? get _currentSelection =>
      _results.isEmpty ? null : _results[_selectedIndex];

  void _selectCurrent() {
    final result = _currentSelection;
    if (result == null) {
      return;
    }

    if (result.isModule) {
      final mod = result.module!;
      // Instance names to expand: all segments between root and the module.
      // For "Top/CPU/ALU" the display segments are `"CPU", "ALU"`;
      // we need to expand all of them to navigate into the block.
      final pathInstanceNames = mod.displaySegments.toList();
      widget.onModuleSelected?.call(mod.occurrenceId, pathInstanceNames);
    } else {
      final sig = result.signal!;
      widget.onWireSelected(sig.signalId, sig.intermediateOccurrenceNames);
    }
    widget.onClose();
  }

  void _selectNext() {
    if (_results.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _results.length;
    });
  }

  void _selectPrevious() {
    if (_results.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = (_selectedIndex - 1 + _results.length) % _results.length;
    });
  }

  /// Compute the longest common prefix among all current result display paths.
  ///
  /// Delegates the core prefix computation to `HierarchyService` and checks
  /// that the expansion is strictly longer than the current query.
  String? _longestCommonPrefix() {
    if (_results.isEmpty) {
      return null;
    }

    // Use displayPath (top-level module stripped) since that matches what
    // the user types in the search field.
    final paths = _results.map((r) => r.displayPath).toList();
    final prefix = HierarchyService.longestCommonPrefix(paths);
    if (prefix == null) {
      return null;
    }

    // Only useful if this is strictly longer than the current query text.
    final currentQuery = _textController.text;
    final normalizedQuery = HierarchyService.hasRegexChars(currentQuery)
        ? currentQuery
        : currentQuery.replaceAll('.', '/');
    if (prefix.length <= normalizedQuery.length) {
      return null;
    }
    return prefix;
  }

  /// Expand the text field to the longest common prefix of all results.
  ///
  /// Called when the user presses Tab.  First tries hierarchical path
  /// completion via `HierarchyService.autocompletePaths` for module
  /// navigation, then falls back to the longest common prefix of the
  /// current search results.
  void _tabComplete() {
    final currentQuery = _textController.text;
    if (currentQuery.isEmpty) {
      return;
    }

    // 1) Try hierarchical path completion (module navigation).
    final hierarchy = widget.hierarchy;
    if (hierarchy != null) {
      final suggestions = hierarchy.autocompletePaths(currentQuery);
      if (suggestions.isNotEmpty) {
        final expanded = HierarchyService.longestCommonPrefix(suggestions);
        if (expanded != null && expanded.length > currentQuery.length) {
          _textController
            ..text = expanded
            ..selection = TextSelection.collapsed(offset: expanded.length);
          _scrollTextToEnd();
          return;
        }
      }
    }

    // 2) Fall back to result-based common prefix.
    final prefix = _longestCommonPrefix();
    if (prefix == null) {
      return;
    }
    _textController
      ..text = prefix
      ..selection = TextSelection.collapsed(offset: prefix.length);
    _scrollTextToEnd();
  }

  void _scrollTextToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textScrollController.hasClients) {
        _textScrollController.jumpTo(
          _textScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  /// Build the close icon using platformIcon helper for proper fallback
  Widget _buildCloseIcon(ColorScheme colors) {
    final hasEmojiFonts = BaseSchematicViewerState.hasEmojiFonts();

    if (hasEmojiFonts) {
      return const Tooltip(
        message: '[X]',
        child: Text('❌', style: TextStyle(fontSize: 18)),
      );
    } else {
      return Tooltip(
        message: '[X]',
        child: Icon(
          Icons.close,
          size: 18,
          color: colors.onSurface.withValues(alpha: 0.7),
        ),
      );
    }
  }

  /// Build the search icon using emoji if available, native icon otherwise
  Widget _buildSearchIcon(ColorScheme colors) {
    final hasEmojiFonts = BaseSchematicViewerState.hasEmojiFonts();

    if (hasEmojiFonts) {
      return Tooltip(
        message: '[?]',
        child: Text(
          '🔍',
          style: TextStyle(
            color: colors.onSurface.withValues(alpha: 0.7),
            fontSize: 20,
          ),
        ),
      );
    } else {
      return Tooltip(
        message: '[?]',
        child: Icon(
          Icons.search,
          color: colors.onSurface.withValues(alpha: 0.7),
          size: 20,
        ),
      );
    }
  }

  /// Icon to distinguish module results from signal results.
  Widget _buildResultIcon(_SearchResult result) {
    if (result.isModule) {
      return const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Icon(Icons.memory, size: 14, color: Colors.amber),
      );
    }
    return const Padding(
      padding: EdgeInsets.only(right: 6),
      child: Icon(Icons.timeline, size: 14, color: Colors.lightBlueAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    const overlayWidth = 400.0;
    const overlayMaxHeight = 400.0;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final onSurface = colors.onSurface;
    final dimColor = onSurface.withValues(alpha: 0.5);
    final subtleColor = onSurface.withValues(alpha: 0.6);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: colors.surfaceContainer,
      child: Container(
        width: overlayWidth,
        constraints: const BoxConstraints(maxHeight: overlayMaxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search input
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: colors.outlineVariant),
                ),
              ),
              child: KeyboardListener(
                focusNode: FocusNode(),
                onKeyEvent: (event) {
                  if (event is KeyDownEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      widget.onClose();
                    } else if (event.logicalKey == LogicalKeyboardKey.tab) {
                      _tabComplete();
                    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                      _selectCurrent();
                    } else if (event.logicalKey ==
                        LogicalKeyboardKey.arrowDown) {
                      _selectNext();
                    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _selectPrevious();
                    }
                  }
                },
                child: Row(
                  children: [
                    _buildSearchIcon(colors),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        scrollController: _textScrollController,
                        style: TextStyle(color: onSurface, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Search blocks and wires',
                          hintStyle: TextStyle(color: dimColor, fontSize: 14),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => _selectCurrent(),
                      ),
                    ),
                    if (_hasResults)
                      Text(
                        _counterText,
                        style: TextStyle(color: subtleColor, fontSize: 12),
                      ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _buildCloseIcon(colors),
                      color: onSurface.withValues(alpha: 0.7),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
            ),

            // Results list
            if (_hasResults)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final result = _results[index];
                    final isSelected = index == _selectedIndex;

                    return InkWell(
                      onTap: () {
                        setState(() => _selectedIndex = index);
                        _selectCurrent();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        color: isSelected
                            ? colors.primary.withValues(alpha: 0.2)
                            : null,
                        child: Row(
                          children: [
                            _buildResultIcon(result),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    result.displayPath,
                                    style: TextStyle(
                                      color: onSurface,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    result.isModule
                                        ? 'block'
                                        : result.displaySegments.join('/'),
                                    style: TextStyle(
                                      color: subtleColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

            // Help text when no query
            if (_textController.text.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Type to search for blocks and wires.\n'
                  'Use slashes for hierarchy: block1/block2/wire\n'
                  'Press Tab to expand the common prefix of matches',
                  style: TextStyle(color: dimColor, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),

            // No results message
            if (_textController.text.isNotEmpty && !_hasResults)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No blocks or wires found matching '
                  '"${_textController.text}"',
                  style: TextStyle(color: dimColor, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
