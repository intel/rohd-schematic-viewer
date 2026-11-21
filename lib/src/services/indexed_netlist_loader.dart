// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// indexed_netlist_loader.dart
// Streaming hierarchy indexing and on-demand netlist connectivity loading.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;

import 'package:rohd_schematic_viewer/src/services/netlist_file_read_stub.dart'
    if (dart.library.js_interop) 'package:rohd_schematic_viewer/src/services/netlist_file_read_web.dart'
    as file_reads;

/// A reopenable byte source. End offsets are exclusive.
///
/// Implementations must read ranges without buffering the entire source.
abstract class NetlistByteSource {
  /// Creates a byte source.
  const NetlistByteSource();

  /// Current I/O phase, without file names or contents, for startup heartbeats.
  String get readStatus => 'Waiting for source bytes';

  /// Total source size, when known without reading the source contents.
  int? get totalBytes => null;

  /// Reads a range, or streams the source to EOF when [end] is null.
  Stream<List<int>> openRead([int start = 0, int? end]);
}

/// A disk file (or browser-selected Blob), never read using `readAsString`.
class FileNetlistByteSource extends NetlistByteSource {
  /// Creates a source for a selected file.
  FileNetlistByteSource(this.file);

  /// The selected file.
  final XFile file;
  (int, DateTime)? _revision;
  String _readStatus = 'Waiting for file metadata';

  @override
  String get readStatus => _readStatus;

  @override
  int? get totalBytes => _revision?.$1;

  Future<(int, DateTime)> _readRevision() async {
    _readStatus = 'Checking file size';
    final length = await file.length().timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw const FormatException(
              'Timed out reading netlist file size'),
        );
    _readStatus = 'Checking file timestamp';
    final modified = await file.lastModified().timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw const FormatException(
              'Timed out reading netlist file timestamp'),
        );
    return (length, modified);
  }

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    final revision = await _readRevision();
    _revision ??= revision;
    if (revision != _revision) {
      throw const FormatException('Netlist changed on disk; reload the file');
    }
    final limit = end ?? revision.$1;
    if (start < 0 || limit < start || limit > revision.$1) {
      throw RangeError('Invalid netlist byte range $start:$limit');
    }
    for (var offset = start;
        offset < limit;
        offset += file_reads.maxReadBytes) {
      final rangeEnd = (offset + file_reads.maxReadBytes).clamp(0, limit);
      _readStatus = 'Reading bytes $offset:$rangeEnd';
      final bytes = await file_reads
          .readFileRange(
            file,
            offset,
            rangeEnd,
            revision.$1,
          )
          .timeout(
            const Duration(seconds: 32),
            onTimeout: () => throw FormatException(
                'Timed out reading netlist bytes $offset:$rangeEnd'),
          );
      if (bytes.length != rangeEnd - offset) {
        throw const FormatException(
            'Netlist range was truncated; reload the file');
      }
      _readStatus = 'Processing bytes $offset:$rangeEnd';
      yield bytes;
      _readStatus = 'Finishing read $offset:$rangeEnd';
    }
    if (await _readRevision() != _revision) {
      throw const FormatException('Netlist changed while reading; reload');
    }
    _readStatus = 'Read complete';
  }
}

/// Indexes a netlist in one streaming pass, without decoding its connections.
///
/// [hierarchyJson] follows ROHD's slim netlist contract: ports, named signals,
/// cell types, directions, widths and source metadata are retained, but cell
/// connection arrays are not. Only requested module ranges are decoded later.
///
/// The source must remain unchanged for the lifetime of this loader. Hosts
/// should create a new loader on reload and reject reads of changed files.
class IndexedNetlistLoader {
  IndexedNetlistLoader._(this._source, this.hierarchyJson, this._modules);

  final NetlistByteSource _source;
  final Map<String, (int, int)> _modules;
  final Map<String, Future<Map<String, dynamic>>> _pending = {};

  /// Mutable slim document, suitable for enrichment by the schematic host.
  final Map<String, dynamic> hierarchyJson;

  /// Builds the byte index and slim hierarchy using bounded input chunks.
  static Future<IndexedNetlistLoader> index(
    NetlistByteSource source, {
    bool Function()? shouldContinue,
    void Function(int bytesRead, int modulesIndexed)? onProgress,
  }) async {
    final reader = _JsonIndexReader(
      source.openRead(),
      shouldContinue: shouldContinue,
      onProgress: onProgress,
    );
    try {
      final document = await reader.read();
      // JSON property order is arbitrary. If cells preceded ports, revisit
      // just those indexed arrays after the port-bit index becomes available.
      for (final module in reader.deferredPorts) {
        for (final range in module.deferredConnections) {
          final bits = _JsonIndexReader(
            source.openRead(range.$1, range.$2),
            retainRoot: false,
            onScalar: module.markConnected,
            shouldContinue: shouldContinue,
          );
          try {
            await bits.scan();
          } finally {
            await bits.close();
          }
        }
      }
      return IndexedNetlistLoader._(source, document, reader.modules);
    } finally {
      await reader.close();
    }
  }

  /// Definition names available for on-demand connectivity requests.
  Iterable<String> get moduleNames => _modules.keys;

  /// Reads and decodes only [definitionName], in the debugger callback shape.
  ///
  /// Concurrent requests are coalesced. Completed results are not retained
  /// here; the viewer owns its enriched module cache.
  /// [onProgress] reports bytes read against the module's indexed length.
  /// [beforeDecode] lets the caller paint its decoding phase before the
  /// synchronous JSON conversion. Callbacks belong to the initiating request.
  Future<Map<String, dynamic>> fetchModuleNetlist(
    String definitionName, {
    void Function(int bytesRead, int totalBytes)? onProgress,
    Future<void> Function()? beforeDecode,
  }) {
    final range = _modules[definitionName];
    if (range == null) {
      throw ArgumentError.value(
          definitionName, 'definitionName', 'Not indexed');
    }
    return _pending.putIfAbsent(definitionName, () async {
      try {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in _source.openRead(range.$1, range.$2)) {
          bytes.add(chunk);
          onProgress?.call(bytes.length, range.$2 - range.$1);
        }
        if (bytes.length != range.$2 - range.$1) {
          throw const FormatException(
              'Netlist changed or was truncated; reload');
        }
        await beforeDecode?.call();
        final module = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (module is! Map<String, dynamic>) {
          throw const FormatException('Indexed module is not an object');
        }
        return {definitionName: module};
      } finally {
        unawaited(_pending.remove(definitionName));
      }
    });
  }
}

/// A streaming JSON reader with byte offsets and a selective object builder.
///
/// Unlike a reviver, discarded arrays are never constructed. JSON is still
/// validated, including skipped values and UTF-8 spanning chunk boundaries.
class _JsonIndexReader {
  _JsonIndexReader(
    Stream<List<int>> stream, {
    this.retainRoot = true,
    this.onScalar,
    this.shouldContinue,
    this.onProgress,
  }) : _chunks = StreamIterator(stream);

  final StreamIterator<List<int>> _chunks;
  final bool retainRoot;
  final void Function(Object?)? onScalar;
  final bool Function()? shouldContinue;
  final void Function(int bytesRead, int modulesIndexed)? onProgress;
  int _offset = 0;
  final Map<String, (int, int)> modules = {};
  final List<_JsonFrame> deferredPorts = [];
  final List<_JsonFrame> _stack = [];
  final List<int> _token = [];
  bool _quoted = false;
  bool _escaped = false;
  bool _plainString = false;
  Object? _root;
  bool _hasRoot = false;
  bool _streamFinished = false;

  Future<void> close() async {
    if (!_streamFinished) {
      await _chunks.cancel();
    }
  }

  FormatException _error(String message) =>
      FormatException('$message at byte $_offset');

  Future<bool> _moveNext() async {
    var hasNext = false;
    try {
      return hasNext = await _chunks.moveNext();
    } finally {
      // StreamIterator has already detached on EOF or a stream error.
      if (!hasNext) {
        _streamFinished = true;
      }
    }
  }

  Future<void> scan() async {
    final progressClock = onProgress == null ? null : (Stopwatch()..start());
    onProgress?.call(0, 0);
    while (await _moveNext()) {
      if (!(shouldContinue?.call() ?? true)) {
        throw const _IndexCancelled();
      }
      _scanChunk(_chunks.current);
      if (progressClock != null && progressClock.elapsedMilliseconds >= 100) {
        onProgress!(_offset, modules.length);
        progressClock.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (_quoted) {
      throw _error('Unterminated string');
    }
    if (_token.isNotEmpty) {
      _finishToken();
    }
    if (_stack.isNotEmpty || !_hasRoot) {
      throw _error('Incomplete JSON document');
    }
    onProgress?.call(_offset, modules.length);
  }

  Future<Map<String, dynamic>> read() async {
    await scan();
    final value = _root;
    if (value is! Map<String, dynamic>) {
      throw _error('Expected a netlist object');
    }
    final document = value['netlist'] ?? value;
    if (document is! Map<String, dynamic>) {
      throw _error('Expected a netlist object');
    }
    final definitions = document['modules'];
    if (definitions is! Map<String, dynamic> ||
        definitions.isEmpty ||
        definitions.keys.any((key) => !modules.containsKey(key))) {
      throw _error('Netlist contained no modules');
    }
    return document;
  }

  static bool _space(int c) => c == 32 || c == 10 || c == 13 || c == 9;

  static bool _punctuation(int c) =>
      c == 123 || c == 125 || c == 91 || c == 93 || c == 44 || c == 58;

  void _scanChunk(List<int> bytes) {
    var index = 0;
    while (index < bytes.length) {
      final byte = bytes[index];
      if (!_quoted && _token.isEmpty) {
        if (_space(byte)) {
          final start = index++;
          while (index < bytes.length && _space(bytes[index])) {
            index++;
          }
          _offset += index - start;
          continue;
        }
        if (byte >= 48 && byte <= 57) {
          var end = index + 1;
          var value = byte - 48;
          while (end < bytes.length && end - index < 15) {
            final digit = bytes[end];
            if (digit < 48 || digit > 57) {
              break;
            }
            value = value * 10 + digit - 48;
            end++;
          }
          if (end < bytes.length &&
              (byte != 48 || end == index + 1) &&
              (_space(bytes[end]) || _punctuation(bytes[end]))) {
            _offset += end - index;
            _acceptToken(value);
            index = end;
            continue;
          }
        }
      }
      _byte(byte);
      _offset++;
      index++;
    }
  }

  void _byte(int c) {
    if (_quoted) {
      _token.add(c);
      if (c == 34 && !_escaped) {
        _quoted = false;
        _finishToken();
      } else {
        if (c == 92 || c < 32) {
          _plainString = false;
        }
        _escaped = !_escaped && c == 92;
      }
      return;
    }
    if (_token.isNotEmpty) {
      if (!_space(c) && !_punctuation(c)) {
        _token.add(c);
        return;
      }
      _finishToken();
    }
    if (_space(c)) {
      return;
    }
    if (c == 123 || c == 91) {
      final path = _valuePath();
      if (_stack.length >= 256) {
        throw _error('JSON nesting limit exceeded');
      }
      final connections = path.length == 5 &&
          path.first == 'modules' &&
          path[2] == 'cells' &&
          path.last == 'connections';
      if (connections && c != 123) {
        throw _error('Connections must be an object');
      }
      final keep =
          (_stack.isEmpty ? retainRoot : _stack.last.keep) && !connections;
      final frame = _JsonFrame(
        path: path,
        start: _offset,
        object: c == 123,
        keep: keep,
        connections: connections,
      );
      frame.module = path.length == 2 && path.first == 'modules'
          ? frame
          : _stack.lastOrNull?.module;
      _stack.add(frame);
    } else if (c == 125 || c == 93) {
      _end(c == 125);
    } else if (c == 58) {
      if (_stack.isEmpty || _stack.last.state != _JsonState.colon) {
        throw _error('Unexpected colon');
      }
      _stack.last.state = _JsonState.value;
    } else if (c == 44) {
      if (_stack.isEmpty || _stack.last.state != _JsonState.separator) {
        throw _error('Unexpected comma');
      }
      _stack.last.state =
          _stack.last.object ? _JsonState.key : _JsonState.value;
    } else {
      _token.add(c);
      _quoted = c == 34;
      _escaped = false;
      _plainString = _quoted;
    }
  }

  List<String> _valuePath() {
    if (_stack.isEmpty) {
      if (_hasRoot) {
        throw _error('Unexpected trailing value');
      }
      return const [];
    }
    final parent = _stack.last;
    if (parent.state != _JsonState.value &&
        parent.state != _JsonState.emptyArray) {
      throw _error('Expected a key or separator');
    }
    if (!parent.object) {
      return parent.elementPath;
    }
    // Normalize the optional ROHD transport envelope.
    return _stack.length == 1 && parent.key == 'netlist'
        ? const []
        : [...parent.path, parent.key!];
  }

  void _finishToken() {
    final value = _decodeToken();
    _token.clear();
    _acceptToken(value);
  }

  void _acceptToken(Object? value) {
    if (_stack.isNotEmpty &&
        (_stack.last.state == _JsonState.key ||
            _stack.last.state == _JsonState.emptyObject)) {
      if (value is! String) {
        throw _error('Expected an object key');
      }
      _stack.last
        ..key = value
        ..state = _JsonState.colon;
      return;
    }
    final path = _valuePath();
    if (path.length == 2 && path.first == 'modules') {
      throw _error('Module ${path.last} is not an object');
    }
    if (path.length == 5 &&
        path.first == 'modules' &&
        path[2] == 'cells' &&
        path.last == 'connections') {
      throw _error('Connections must be an object');
    }
    onScalar?.call(value);
    if (_stack.isNotEmpty) {
      final parent = _stack.last;
      if (!parent.keep &&
          parent.path.length == 6 &&
          parent.path[4] == 'connections') {
        parent.module?.markConnected(value);
      }
    }
    _accept(value);
  }

  Object? _decodeToken() {
    if (_plainString) {
      return utf8.decoder.convert(_token, 1, _token.length - 1);
    }
    // Net IDs dominate large connection arrays. Avoid a UTF-8 string and a
    // separate JSON decoder for each ordinary, exactly representable integer.
    if (_token.length <= 15 && (_token.length == 1 || _token.first != 48)) {
      var value = 0;
      var integer = true;
      for (final byte in _token) {
        if (byte < 48 || byte > 57) {
          integer = false;
          break;
        }
        value = value * 10 + byte - 48;
      }
      if (integer) {
        return value;
      }
    }
    return jsonDecode(utf8.decode(_token));
  }

  void _end(bool object) {
    if (_stack.isEmpty) {
      throw _error('Unexpected closing delimiter');
    }
    final frame = _stack.removeLast();
    if (frame.object != object ||
        (frame.state != _JsonState.separator &&
            frame.state != _JsonState.emptyObject &&
            frame.state != _JsonState.emptyArray)) {
      throw _error('Incomplete object or array');
    }
    if (frame.path.length == 2 && frame.path.first == 'modules') {
      if (!object) {
        throw _error('Module ${frame.path.last} is not an object');
      }
      modules[frame.path.last] = (frame.start, _offset + 1);
      if (frame.deferredConnections.isNotEmpty) {
        deferredPorts.add(frame);
      }
    }
    if (!object &&
        frame.path.length == 6 &&
        frame.path[4] == 'connections' &&
        frame.module?.portBits == null) {
      frame.module?.deferredConnections.add((frame.start, _offset + 1));
    }
    final Object? value;
    if (frame.connections) {
      value = _ConnectionWidths(frame.widths);
    } else if (object) {
      final map = frame.map;
      if (map != null && frame.widths.isNotEmpty) {
        map['port_widths'] = {
          ...?map['port_widths'] as Map<String, dynamic>?,
          ...frame.widths,
        };
      }
      value = map;
    } else {
      value = frame.list ?? _ArrayLength(frame.count);
    }
    _accept(value);
  }

  void _accept(Object? value) {
    if (_stack.isEmpty) {
      _root = value;
      _hasRoot = true;
      return;
    }
    final parent = _stack.last;
    if (parent.module == parent &&
        parent.key == 'ports' &&
        value is Map<String, dynamic>) {
      parent.indexPorts(value);
    }
    if (parent.connections) {
      if (value is! _ArrayLength) {
        throw _error('Connection bits must be an array');
      }
      parent.widths[parent.key!] = value.length;
    } else if (value is _ConnectionWidths) {
      parent.widths.addAll(value.widths);
    } else if (parent.object) {
      parent.map?[parent.key!] = value;
    } else {
      parent.list?.add(value);
    }
    parent.count++;
    parent.state = _JsonState.separator;
  }
}

enum _JsonState { emptyObject, emptyArray, key, colon, value, separator }

class _JsonFrame {
  _JsonFrame({
    required this.path,
    required this.start,
    required this.object,
    required this.keep,
    required this.connections,
  })  : state = object ? _JsonState.emptyObject : _JsonState.emptyArray,
        map = keep && object ? <String, dynamic>{} : null,
        list = keep && !object ? <dynamic>[] : null;

  final List<String> path;
  late final List<String> elementPath = [...path, '[]'];
  final int start;
  final bool object;
  final bool keep;
  final bool connections;
  final Map<String, dynamic>? map;
  final List<dynamic>? list;
  final Map<String, int> widths = {};
  _JsonState state;
  String? key;
  int count = 0;
  _JsonFrame? module;
  Map<int, List<Map<String, dynamic>>>? portBits;
  final List<(int, int)> deferredConnections = [];

  void indexPorts(Map<String, dynamic> ports) {
    final index = <int, List<Map<String, dynamic>>>{};
    for (final rawPort in ports.values) {
      if (rawPort is! Map<String, dynamic>) {
        continue;
      }
      final bits = rawPort['bits'];
      if (bits is List) {
        for (final bit in bits.whereType<int>()) {
          index.putIfAbsent(bit, () => []).add(rawPort);
        }
      }
    }
    portBits = index;
  }

  void markConnected(Object? bit) {
    if (bit is int) {
      for (final port in portBits?[bit] ?? const <Map<String, dynamic>>[]) {
        port['connected'] = true;
      }
    }
  }
}

class _ConnectionWidths {
  const _ConnectionWidths(this.widths);
  final Map<String, int> widths;
}

class _ArrayLength {
  const _ArrayLength(this.length);
  final int length;
}

class _IndexCancelled implements Exception {
  const _IndexCancelled();

  @override
  String toString() => 'Netlist indexing was cancelled';
}
