# Indexed Netlist Loading

This document describes the implementation and development workflows for
loading large netlist files. The user-facing overview is in the root
[README](../README.md#loading-large-netlist-files).

## Loading model

Standalone file-picker and VS Code custom-editor loads index the file directly
from disk using bounded byte ranges. The initial pass scans the JSON and
retains a slim hierarchy representation: module and signal names, pins,
widths, attributes, and source metadata. It does not retain the complete JSON
text or cell connection arrays. This follows ROHD's slim-netlist and
per-module-connectivity split.

The initial layout displays child modules as blocks without loading
connectivity, including at the root. Operations that need wires read and
decode only the relevant module's byte range; recursive wire expansion loads
the required descendants. Blocks-only expansion skips connectivity loading,
and already loaded module definitions are reused. VS Code requests bounded
ranges from its extension host rather than embedding the complete file as
base64 in the webview.

Opaque module instances with empty or missing definitions remain visible as
blocks. Only modules with internal cells in the file can be expanded further;
an undefined module cannot expose hierarchy that is not present in the file.
Primitive constants and selects remain hidden until requested.

The index is session-local. Reloading rescans the file. If the file changes
while it is being viewed, further reads fail rather than using stale offsets.
VS Code requires a filesystem-backed file, including remote workspace files
served by the remote extension host.

## Progress, bounded reads, and errors

Startup reports bytes scanned and modules indexed, then reports hierarchy
construction, frame waits, and initial-layout phases. Console messages
prefixed with `[FileLoad]` include a load ID and elapsed time for each
checkpoint. A five-second heartbeat repeats the current phase while an
asynchronous step is pending; messages omit design names and JSON contents.

The UI reports scanned MB against the total and shows hierarchy building as a
separate phase. Opening file-backed blocks reports connectivity reads,
decoding, and attaching connectivity before layout. The viewer updates each
occurrence of the loaded definition without rebuilding unrelated instances
or replaying expansion state. Text progress supplements
the spinner during synchronous conversion. Frame waits, metadata reads, and
byte reads time out with visible errors. Native read cancellation has a
separate deadline so stalled cleanup cannot hide the original read timeout.

Browser files use verified Blob-URL range requests, avoiding `XFile`'s
whole-Blob retrieval before slicing. Browser reads are capped at 1 MiB per
read to amortize request overhead; native reads are capped at 64 KiB per
read. These are per-read chunk sizes, not maximum supported file sizes.

The startup marker `[bounded-reader-v2]` identifies the current loader, and
heartbeats include its active I/O phase and byte range. After updating the
loader, start a fresh file load: hot reload cannot replace an already-pending
asynchronous read.

## Testing and profiling

Before comparing solver timings, verify that both results still route the
expected wires. See [Cross-checking ELK layouts with xchkr](LAYOUT_CROSS_CHECK.md).

The file-backed startup and on-demand expansion journeys run without a
browser:

```bash
flutter test test/indexed_file_viewer_test.dart
```

To profile a local netlist without adding it as a test fixture, set
`NETLIST_TEST_FILE` and run the hierarchy-only startup test. This exercises
the real file-backed startup entry point while substituting only the layout
engine, and verifies that startup completes without connectivity reads:

```bash
NETLIST_TEST_FILE=/absolute/path/to/netlist.json \
  flutter test test/indexed_file_viewer_test.dart \
  --plain-name="disk startup completes hierarchy-only before calling layout"
```

The browser byte source and indexer can be tested independently using
synthetic Blob files:

```bash
flutter test --platform chrome --wasm \
  test/browser_indexed_netlist_loader_test.dart
```

Omit `--wasm` to test the JavaScript build. These
tests cover bounded range reads and on-demand connectivity.

## Scope and limitations

The first scan traverses the entire file, and the complete slim hierarchy and
named-signal metadata remain in memory. Loading the hierarchy incrementally
by depth is not implemented.

This file-backed path does not change explicit JSON string/map inputs, bundled
assets, or the debugger's existing hierarchy and connectivity callbacks.
