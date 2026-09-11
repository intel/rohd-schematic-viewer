// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// vscode_extension_client.dart
// Platform-conditional factory for the VS Code extension client.
//
// Selects the correct implementation at compile time:
//   • Web (JS interop)  — VscodeSchematicExtensionClient via _vscodeApi
//   • Native / stub     — NullExtensionClient (no VS Code host)
//
// 2026 May
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

export 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show
        NullExtensionClient,
        RohdExtensionClient,
        RohdFormatInfo,
        RohdModuleInfo,
        RohdSourceFormat;

export 'vscode_extension_client_stub.dart'
    if (dart.library.js_interop) 'vscode_extension_client_web.dart'
    show createVscodeExtensionClient;
