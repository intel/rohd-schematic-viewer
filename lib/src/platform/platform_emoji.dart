// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// platform_emoji.dart
// Shared emoji-font detection utility for Linux native builds.
//
// Result is cached after the first call so that build methods can call
// hasEmojiFonts() freely without repeatedly launching fc-list.
//
// 2026 March
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Cached result of emoji-font detection.
bool? _emojiSupport;

/// Returns `true` if the current platform is likely to render emoji glyphs.
///
/// * Web: always `true` (browser handles it).
/// * Non-Linux desktop/mobile: always `true`.
/// * Linux: runs `fc-list` once and checks for known emoji font names;
///   falls back to probing common NotoColorEmoji file paths.
///   Returns `false` only when both checks fail — in that case
///   callers should use Material icon fallbacks instead of emoji `Text`.
///
/// The result is cached for the lifetime of the process.
bool hasEmojiFonts() => _emojiSupport ??= _detectEmojiSupport();

bool _detectEmojiSupport() {
  if (kIsWeb) {
    return true;
  }
  if (!Platform.isLinux) {
    return true;
  }

  // Try fontconfig (fc-list) — the standard way on GTK desktops.
  try {
    final result = Process.runSync('fc-list', [':']);
    if (result.exitCode == 0) {
      final fontList = result.stdout.toString().toLowerCase();
      if (fontList.contains('noto color emoji') ||
          fontList.contains('noto emoji') ||
          fontList.contains('emojione') ||
          fontList.contains('segoe color emoji')) {
        return true;
      }
    }
  } on Exception {
    // fc-list unavailable — try well-known file paths.
    try {
      const knownPaths = [
        '/usr/share/fonts/opentype/noto/NotoColorEmoji.ttf',
        '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
        '/usr/share/fonts/opentype/noto-emoji/NotoColorEmoji.ttf',
      ];
      for (final path in knownPaths) {
        if (File(path).existsSync()) {
          return true;
        }
      }
    } on Exception {
      // If we still can't check, assume no emoji support on Linux.
    }
  }

  return false;
}
