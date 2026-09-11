// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// url_strategy.dart
// Configure URL strategy for web platform compatibility.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/platform/url_strategy_stub.dart'
    if (dart.library.html) 'url_strategy_web.dart';

/// Configure URL strategy only on web to avoid History API issues in VS Code
/// webviews.
void configureUrlStrategyIfWeb() {
  configureUrlStrategy();
}
