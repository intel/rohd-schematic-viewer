// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// vscode_extension_client_stub.dart
// Native stub for the VS Code webview extension client.
//
// The VS Code webview interop is only available on web. On native platforms
// (Linux, macOS, Windows) this stub is used, and all queries return
// "not available" since there is no VS Code host.
//
// 2026 May
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart';

/// Creates the platform-appropriate [RohdExtensionClient] for VS Code webview
/// mode.  On native platforms this always returns a [NullExtensionClient].
RohdExtensionClient createVscodeExtensionClient() => NullExtensionClient();
