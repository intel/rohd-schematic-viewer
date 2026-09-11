// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_theme_cubit.dart
// Manages theme state for the schematic viewer (light/dark mode).
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_bloc/flutter_bloc.dart';

/// Theme mode options.
enum SchematicThemeMode {
  /// Light theme.
  light,

  /// Dark theme.
  dark,
}

/// Cubit to manage schematic viewer theme state.
class SchematicThemeCubit extends Cubit<SchematicThemeMode> {
  /// Constructor for [SchematicThemeCubit].
  /// Optionally accepts an initial state to start with.
  SchematicThemeCubit([super.initialState = SchematicThemeMode.dark]);

  /// Toggle between light and dark theme.
  void toggleTheme() {
    emit(
      state == SchematicThemeMode.light
          ? SchematicThemeMode.dark
          : SchematicThemeMode.light,
    );
  }

  /// Set specific theme mode.
  void setTheme(SchematicThemeMode mode) {
    emit(mode);
  }

  /// Check if current theme is dark.
  bool get isDark => state == SchematicThemeMode.dark;
}
