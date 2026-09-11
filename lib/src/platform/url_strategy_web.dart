// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// url_strategy_web.dart
// Web-only: Disables URL strategy to prevent History API errors in webview.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:flutter_web_plugins/url_strategy.dart';

/// Disables URL strategy for webview compatibility.
void configureUrlStrategy() {
  setUrlStrategy(null);
}
