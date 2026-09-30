// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_host.dart
// Optional standalone and extension host widgets.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Public host-shell API for standalone and extension schematic viewers.
library;

export 'schematic_layout.dart';
export 'src/ui/flutter_schematic_viewer_page.dart'
    show FlutterSchematicExtensionHost, FlutterSchematicViewerPage;
export 'src/ui/standalone_schematic_viewer_page.dart'
    show StandaloneSchematicViewerPage;
