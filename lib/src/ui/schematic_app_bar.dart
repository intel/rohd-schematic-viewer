// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_app_bar.dart
// Shared AppBar widget for all schematic viewer pages.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';
import 'package:rohd_schematic_viewer/src/cubit/schematic_theme_cubit.dart';
import 'package:rohd_schematic_viewer/src/platform/platform_emoji.dart'
    as platform_emoji;
import 'package:rohd_schematic_viewer/src/ui/layout_dock_icon.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_help_button.dart';
import 'package:rohd_schematic_viewer/src/ui/schematic_icon.dart';

/// A shared AppBar for all schematic viewer page variants.
///
/// Provides a consistent look across desktop, web, and embedded pages:
/// - Title with schematic icon + "ROHD Schematic Viewer"
/// - Optional file-name badge
/// - Optional platform badge (e.g. "WEB")
/// - Optional [leadingActions] (stats, file picker, reload, …)
/// - Help button (❓) with keybinding tooltip + help dialog
/// - Theme toggle (🌞/🌙)
///
/// Usage:
/// ```dart
/// SchematicAppBar(
///   fileName: 'counter.json',
///   leadingActions: [myReloadButton],
/// )
/// ```
class SchematicAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// File name shown as a badge next to the title, or `null` to hide.
  final String? fileName;

  /// Extra action widgets rendered **before** the help and theme buttons.
  ///
  /// A vertical divider is inserted automatically between these actions and
  /// the trailing help/theme group when this list is non-empty.
  final List<Widget> leadingActions;

  /// Optional [CrossProbeService] — when non-null a [CrossProbeButton] is
  /// shown in the action bar so the user can toggle cross-probing.
  final CrossProbeService? crossProbeService;

  /// Optional bottom widget (e.g. a `TabBar`).
  final PreferredSizeWidget? bottom;

  /// Whether the top AppBar is pinned open.
  final bool? appBarPinned;

  /// Callback used to pin or unpin the top AppBar.
  final ValueChanged<bool>? onAppBarPinnedChanged;

  /// Create a [SchematicAppBar].
  const SchematicAppBar({
    this.fileName,
    this.leadingActions = const [],
    this.crossProbeService,
    this.bottom,
    this.appBarPinned,
    this.onAppBarPinnedChanged,
    super.key,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight((bottom?.preferredSize.height ?? 0) + kToolbarHeight);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('fileName', fileName))
      ..add(IntProperty('leadingActions', leadingActions.length))
      ..add(DiagnosticsProperty<PreferredSizeWidget?>('bottom', bottom))
      ..add(FlagProperty('appBarPinned', value: appBarPinned, ifTrue: 'pinned'))
      ..add(
        ObjectFlagProperty<ValueChanged<bool>?>.has(
          'onAppBarPinnedChanged',
          onAppBarPinnedChanged,
        ),
      )
      ..add(
        DiagnosticsProperty<CrossProbeService?>(
          'crossProbeService',
          crossProbeService,
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SchematicThemeCubit, SchematicThemeMode>(
        builder: (context, themeMode) {
          final themeCubit = context.read<SchematicThemeCubit>();
          final isDark = themeMode == SchematicThemeMode.dark;
          final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
          final fgColor = isDark ? Colors.white : Colors.black;
          final dividerColor = isDark ? Colors.white24 : Colors.black12;

          return AppBar(
            backgroundColor: bgColor,
            foregroundColor: fgColor,
            leadingWidth: onAppBarPinnedChanged != null ? 40 : null,
            leading: onAppBarPinnedChanged != null && appBarPinned != null
                ? Tooltip(
                    message: appBarPinned! ? 'Unpin top bar' : 'Pin top bar',
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: LayoutDockIcon(
                        edge: LayoutDockEdge.top,
                        locked: appBarPinned!,
                        color: appBarPinned!
                            ? Theme.of(context).colorScheme.primary
                            : isDark
                                ? Colors.white54
                                : Colors.black54,
                      ),
                      onPressed: () {
                        onAppBarPinnedChanged?.call(!appBarPinned!);
                      },
                    ),
                  )
                : null,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SchematicIcon(
                  brightness: isDark ? Brightness.dark : Brightness.light,
                ),
                const SizedBox(width: 12),
                Text('ROHD Schematic Viewer', style: TextStyle(color: fgColor)),
                if (fileName != null) ...[
                  const SizedBox(width: 16),
                  _fileNameBadge(isDark),
                ],
              ],
            ),
            actions: [
              ...leadingActions,
              if (crossProbeService != null)
                CrossProbeButton(service: crossProbeService!),
              if (leadingActions.isNotEmpty || crossProbeService != null)
                VerticalDivider(width: 1, color: dividerColor),
              // ❓ Help – always present
              SchematicHelpButton(isDark: isDark, isEmbedded: false),
              // 🌞/🌙 Theme toggle – always present
              _themeToggle(isDark, themeCubit),
              const SizedBox(width: 8),
            ],
            bottom: bottom,
          );
        },
      );

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Widget _fileNameBadge(bool isDark) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE8E8E8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          fileName!,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      );

  Widget _themeToggle(bool isDark, SchematicThemeCubit themeCubit) {
    final useEmoji = platform_emoji.hasEmojiFonts();
    return Tooltip(
      message: isDark ? 'Switch to light theme' : 'Switch to dark theme',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: themeCubit.toggleTheme,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: useEmoji
                ? Text(
                    isDark ? '🌞' : '🌙',
                    style: const TextStyle(fontSize: 20, inherit: false),
                  )
                : Icon(
                    isDark ? Icons.light_mode : Icons.dark_mode,
                    size: 20,
                    color: isDark ? Colors.white : Colors.black,
                  ),
          ),
        ),
      ),
    );
  }
}
