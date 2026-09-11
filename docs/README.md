# ROHD Schematic Viewer Docs

This directory intentionally stays small. The repository root [README](../README.md) is the user-facing overview; this file is the developer-facing map for the checked-in documentation.

## What This Project Does

ROHD Schematic Viewer is a Flutter app for inspecting Yosys JSON netlists as interactive schematics. It can be delivered as a web app, Linux desktop app, or VS Code extension. The viewer supports hierarchical expansion, wire search, wire highlighting, and source/hierarchy metadata when the input JSON includes it.

The main implementation areas are:

- `extension.js` and `package.json` for the VS Code extension entry point and contribution metadata.
- `lib/` for the Flutter viewer, schematic model, layout integration, and UI.
- `assets/js/` and `js_bridge/` for the ELK layout JavaScript used by web and native builds.
- `scripts/` and `Makefile` for dependency-mode switching, build, packaging, and install workflows.
- `test/` for adapter, hierarchy, expansion, layout extraction, search, and miter tests.

## Supported Inputs

The primary input is Yosys JSON netlist data. ROHD-generated metadata and FLC data are supported when present, but the viewer should still load plain Yosys JSON netlists.

## Documentation Split

- [BUILD.md](BUILD.md) covers setup, dependency modes, VS Code tasks, build targets, packaging, and troubleshooting.
- This file covers orientation only.

Keep build commands and dependency-mode details in [BUILD.md](BUILD.md) so the two docs do not drift or overlap.
