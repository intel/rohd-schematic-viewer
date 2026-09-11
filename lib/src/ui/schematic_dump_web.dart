// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_dump_web.dart
// Web implementation: stores schematic JSON on window._rohdSchematicDump.
//
// 2026 July
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:js_interop';

@JS('window._rohdSchematicDump')
external set _rohdSchematicDump(JSString? value);

/// Store [value] on `window._rohdSchematicDump` so it can be extracted
/// from the browser console with `copy(window._rohdSchematicDump)`.
void setRohdSchematicDump(String value) {
  _rohdSchematicDump = value.toJS;
}
