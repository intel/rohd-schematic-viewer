## 0.3.0

- Breaking: Require ROHD `^0.7.0`.
- Migrate gate catalog generation to `concat`.

## 0.2.5

- Fix Go to Source in the VS Code Wasm renderer by accepting numeric FLC line and column values in both direct navigation and the frame-selection popup.
- Add hierarchy-first indexed loading for standalone and VS Code netlist files, using bounded reads instead of buffering the whole file and fetching connectivity on demand. Start with child blocks only, preserve opaque blocks and expansion controls, and leave debugger loading unchanged.
- Show MB loaded/total and explicit loading, hierarchy-building, and connectivity stages. Improve scan performance, detect file changes, and bound read and cancellation waits to avoid indefinite loading. Cover native, Wasm, and JavaScript loading with regression tests.
- Broaden the hierarchy dependency constraint to accept 0.1.x and 0.2.x and the DevTools widgets constraint to accept 0.1.1 through 0.2.x without requiring the new widgets release first.
- Accept ROHD 0.6.11 and 0.7.x.
- Narrow the ROHD import to `LogicValue` so analysis also accepts ROHD versions without the deprecated `Port` alias.
- Retain flexible Material UI 1.x constraints, allowing both the published widgets' older UI stack and Material UI 1.7.0 with widgets 0.2.0 without increasing the Dart or Flutter lower bounds.

## 0.2.4

- Use a PNG coverage badge in the shared README so Marketplace packaging accepts the badge while GitHub continues to display it.

## 0.2.3

- Changed the VS Code Marketplace publisher ID to `intel-corporation`.

## 0.2.2

- Fixed Wasm startup in VS Code by disabling browser history for both web compilers before widget initialization.

- Restored missing COMBINATIONAL and SEQUENTIAL input/output port labels, drawing them in white over the original solid blue fill.

- Added standard Intel VSIX packaging with Wasm and JavaScript fallback, packaged-runtime smoke tests, and verified GitHub artifacts for manual Marketplace publication.

## 0.2.1

- Added an App Bar settings menu with a **Display widths** control for showing or hiding blue multi-bit signal-width overlays without recomputing the schematic layout.

- Prevented large PNG exports from clipping the visible schematic by reducing output raster resolution as needed while preserving the complete current viewport.

## 0.2.0

### Added

- Added a runnable example of embedding the viewer in a Flutter application.
- Added controlled `themeMode` and `expansionMode` properties while retaining the initial-value parameters for uncontrolled embeddings.
- Added explicit `EmbeddedSchematicViewer.fromJson`, `EmbeddedSchematicViewer.fromNetlistMap`, `EmbeddedSchematicViewer.fromHierarchy`, and `EmbeddedSchematicViewer.fromAsset` constructors.
- Added dedicated `schematic_host.dart`, `schematic_layout.dart`, and `schematic_connectivity.dart` entry points.
- Added an immutable read-only connectivity facade with optional transparent primitive traversal.

### Changed

- Narrowed `schematic_viewer.dart` to the supported embedded-widget API.
- Dependency-owned hierarchy, cross-probing, source-navigation, and shared widget contracts must now be imported from their owning packages.
- Replaced the layout-backed connectivity API with `NetlistSchematicConnectivity` and immutable `SchematicPortOccurrence` values.
- Applied initial and controlled expansion modes to hierarchy-only viewer layouts.
- Updated dependency configuration tasks to prompt only for Git or Local details, prefill the current repository/ref or checkout path, and preserve working configuration files when a new selection fails validation.

### Deprecated

- Deprecated the unnamed `EmbeddedSchematicViewer(...)` constructor because its nullable `assetPath`, `schematicJson`, `netlistJsonMap`, and `externalHierarchy` parameters allowed ambiguous input combinations. Use  `EmbeddedSchematicViewer.fromAsset`, `.fromJson`, `.fromNetlistMap`, or `.fromHierarchy`, respectively.

### Removed from the supported public API

- The main entry point no longer exports dependency packages, theme Cubit implementation details, canvas and painter internals, mutable netlist adapters, base page state, standalone host pages, or concrete layout implementation types.
- The connectivity entry point no longer exports `NetlistSchematicAdapter`, `SchematicGraph`, `LayoutNode`, `LayoutHyperedge`, or `ElkPort`, and no longer extends `SignalOccurrence` with graph-backed traversal methods.

## 0.1.0

- Initial release of the ROHD Schematic Viewer.
