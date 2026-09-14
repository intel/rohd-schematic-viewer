#!/usr/bin/env python3

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# Patches Flutter's generated web bootstrap for VS Code webviews.

import os
import re
import sys


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILD_BOOTSTRAP = os.path.join(
    SCRIPT_DIR, '..', 'build', 'web', 'flutter_bootstrap.js')

if not os.path.exists(BUILD_BOOTSTRAP):
    print(
        f'Warning: {BUILD_BOOTSTRAP} not found. Has the Flutter web build '
        'completed?',
        file=sys.stderr,
    )
    sys.exit(0)

with open(BUILD_BOOTSTRAP, encoding='utf-8') as bootstrap_file:
    content = bootstrap_file.read()

# Keep CanvasKit local so the webview does not need to fetch the renderer from
# Google's CDN.
content = content.replace(
    '"engineRevision":',
    '"useLocalCanvasKit":true,"engineRevision":',
    1,
)

# Service workers are not usable in the extension webview and can prevent the
# WASM bootstrap from resolving its local assets.
content = re.sub(
    r'_flutter\.loader\.load\(\{[^}]+serviceWorkerSettings:[^}]+\}[^}]*\}\);',
    '_flutter.loader.load({});',
    content,
    flags=re.DOTALL,
)

with open(BUILD_BOOTSTRAP, 'w', encoding='utf-8') as bootstrap_file:
    bootstrap_file.write(content)

print('Done')
