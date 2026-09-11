// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_viewer.dart
// Library exports for shared schematic viewer components.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Schematic canvas and painter components.
library;

/// Shared widgets (help, overlay, PNG export).
/// Re-exported from rohd_devtools_widgets.
export 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';

/// Hierarchy services (source-agnostic).
/// Re-exported from rohd_hierarchy.
export 'package:rohd_hierarchy/rohd_hierarchy.dart';

/// Source-navigation data models and services.
///
/// The cross-probe widget library's `GoToSourceCallback` remains public.
export 'package:rohd_source_navigator/rohd_source_navigator.dart'
    hide GoToSourceCallback;

export 'src/cubit/schematic_theme_cubit.dart';
export 'src/schematic/netlist_schematic_adapter.dart';
export 'src/schematic/schematic_canvas.dart';

/// Layout services.
export 'src/services/schematic_layout_engine.dart';
export 'src/services/schematic_layout_models.dart';

/// UI pages for embedding schematic viewers.
export 'src/ui/base_schematic_viewer_page.dart';
export 'src/ui/embedded_schematic_viewer.dart';
export 'src/ui/schematic_app_bar.dart';
export 'src/ui/schematic_expansion_mode.dart';
export 'src/ui/schematic_help_button.dart';
export 'src/ui/schematic_icon.dart';
export 'src/ui/standalone_schematic_viewer_page.dart';
