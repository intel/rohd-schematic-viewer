
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
