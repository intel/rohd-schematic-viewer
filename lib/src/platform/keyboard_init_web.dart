// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// keyboard_init_web.dart
// Web-specific keyboard initialization to override browser defaults.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Initialize keyboard event handling for web.
/// Prevents browser's default Ctrl+F/Cmd+F behavior and suppresses the
/// browser's native context menu so Flutter can handle right-clicks.
void initializeKeyboardHandling() {
  web.document.addEventListener(
    'keydown',
    ((web.Event event) {
      final keyEvent = event as web.KeyboardEvent;

      // Check for Ctrl+F or Cmd+F
      if (keyEvent.key == 'f' || keyEvent.key == 'F') {
        if (keyEvent.ctrlKey || keyEvent.metaKey) {
          // Prevent browser's default find dialog
          keyEvent
            ..preventDefault()
            ..stopPropagation();
        }
      }
    }).toJS,
  );

  // Suppress the browser's native context menu so right-clicks are handled
  // by Flutter's custom wire/signal context menu instead.
  web.document.addEventListener(
    'contextmenu',
    ((web.Event event) {
      event.preventDefault();
    }).toJS,
  );
}
