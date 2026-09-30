# Build And Development

This document is the source of truth for building, running, packaging, and switching dependency sources for ROHD Schematic Viewer.

## Prerequisites

- Flutter SDK compatible with `environment.sdk` in `pubspec.yaml`.
- `bash`, `make`, `git`, and `node` on `PATH`.
- Linux desktop builds also need CMake, Ninja, `pkg-config`, GTK development files, and a C++ compiler. On Ubuntu/Debian:

```bash
sudo apt-get install cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

Clang is Flutter's preferred Linux compiler. When `clang` and `clang++` are not available but `gcc` and `g++` are, the Make targets automatically provide the compiler command names Flutter expects and build with GCC instead. This avoids installing Clang solely to satisfy Flutter's name-based toolchain check.

The Linux build uses CMake and `pkg-config`, and [linux/CMakeLists.txt](../linux/CMakeLists.txt) requires `gtk+-3.0`. `scripts/stage_linux_assets.sh` validates bundled assets for Linux builds; it does not install system dependencies.

Check your local Flutter installation with:

```bash
flutter doctor
```

## Dependency Modes

By default, the repository uses the hosted dependencies declared in
`pubspec.yaml`. Git and local overrides are opt-in. Git selection defaults to
`github.com/intel/rohd:main`, while the default local checkout is
`~/release/rohd`. Dependency groups retain independent `hosted`/`git`/`local`
selections, but all Git-backed groups share one repository and ref, and all
Local-backed groups share one checkout root. Changing a shared setting updates
every group currently using that source.

The command-line script still supports these convenience modes:

| Mode | Meaning |
| --- | --- |
| `manifest` | Use the dependency sources in `pubspec.yaml` |
| `local-rohd` | Local ROHD and hierarchy; hosted extension packages |
| `local-extension` | Hosted ROHD; local hierarchy and extension packages |
| `local-all` | Local ROHD, hierarchy, and DevTools-extension packages |

Each convenience mode also replaces the persisted group-source state, so a
later configuration task preserves the mode that was actually installed.

The default local checkout is `~/release/rohd`. Configure all ROHD package
sources from it with:

```bash
bash scripts/schematic_dev_mode.sh local-all
flutter pub get
```

Set `ROHD_LOCAL_PATH=/path/to/rohd` to use a different checkout. The generated,
ignored `pubspec_overrides.yaml` points directly to the external checkout; no
repository-local symlink is created.

To return to the manifest dependencies:

```bash
bash scripts/schematic_dev_mode.sh manifest
flutter pub get
```

To inspect the current generated override file:

```bash
bash scripts/schematic_dev_mode.sh show
```

## VS Code Tasks

Use the central source selection in each task:

- `Configure ROHD Dependency`
- `Configure Package Dependency`
- `Configure Widget Dependency`
- `Configure All Dependencies`

Hosted completes immediately after the source selection. Git opens a terminal
prompt for the shared repository/ref, prefilled with the current setting or
`github.com/intel/rohd:main`; enter the repository and branch/tag together as
`repository:ref`. Local opens a terminal prompt for the shared checkout root,
prefilled with the current path or `~/release/rohd`. Changing either setting
rewrites every override currently using that source while preserving each
group's source selection. The run tasks use the resulting configuration.

## Make Targets

Common targets:

| Target | Purpose |
| --- | --- |
| `make test` | Run `flutter test` |
| `make coverage` | Run all Flutter tests and generate Dart LCOV/HTML coverage reports |
| `make coverage-view` | Serve `coverage/html` on port `8000` |
| `make stage-js` | Stage the ELK layout wrapper from `js_bridge/` into `assets/` |
| `make web` | Build Flutter web output in release mode |
| `make web-debug` | Force a debug web build |
| `make web-release` | Force a release web build |
| `make web-run` | Run Flutter web server on port `9199` |
| `make web-serve` | Serve existing `build/web/` on port `9199` |
| `make linux` / `make linux-debug` | Build the Linux debug app |
| `make linux-release` | Build the Linux release app |
| `make linux-run-debug` | Run Linux app in debug mode |
| `make linux-run-profile` | Run Linux app in profile mode |
| `make linux-run-release` | Run Linux app in release mode |
| `make build` / `make extension` | Build the packaged VS Code extension zip |
| `make install-local` | Install the extension zip into local VS Code |
| `make install-remote` / `make install` | Install the extension zip into VS Code Server |
| `make clean` | Remove extension, web, and Linux build artifacts |
| `make real-clean` | Run `make clean`, `flutter clean`, remove Node dependencies, dependency-source task state, and staged generated assets |

Use `make help` for the current target list.

### Dart Coverage

Run `make coverage` to create `coverage/lcov.info` and an HTML report at
`coverage/html/index.html`. Set `COVERAGE_TEST_ARGS` to pass additional Flutter
test arguments, for example `COVERAGE_TEST_ARGS='test/widget_test.dart' make coverage`.

This report measures Dart exercised by Flutter tests. It intentionally excludes
the unmodified third-party `assets/js/elk.bundled.js` and the small local JS
layout wrapper because this project does not have a JavaScript test runner.

### GitHub Pages App

Run the same release build used by the `App` workflow with:

```bash
tool/gh_actions/build_app.sh /rohd-schematic-viewer/
```

The optional argument is the deployment base href and must start and end with
`/`. When omitted in GitHub Actions, the script derives the project-site path
from `GITHUB_REPOSITORY`. Local builds default to `/rohd-schematic-viewer/`.
The validated static bundle is written to `build/web/`.

The `.github/workflows/app.yml` workflow uploads this directory as a GitHub
Pages artifact and deploys it on pushes to `main` or manual dispatch. Configure
the repository's Pages source as **GitHub Actions** before the first deployment.
The Pages build disables Flutter's deprecated generated service worker so
deployments do not retain stale application bundles.

## Direct Run Commands

Web debug run:

```bash
bash scripts/schematic_run.sh manifest web-debug
```

When the web run is ready, open <http://localhost:9199> in a browser. Both `web-debug` and `web-release` bind Flutter's web server to `localhost` on port `9199`; `make web-run` and `make web-serve` use the same URL.

For reference, the debug web path in `scripts/schematic_run.sh` stages the JavaScript assets and then runs:

```bash
flutter run -d web-server --web-port=9199 --web-hostname=localhost
```

Linux debug run:

```bash
bash scripts/schematic_run.sh manifest linux-debug
```

The script accepts either a mode token, such as `local-all`, or the expanded VS Code picker label. The legacy `hr-he`, `lr-he`, `hr-le`, and `lr-le` aliases remain supported.

## Packaging

Build the extension package:

```bash
make build
```

The package is written under `build/` as a slim zip named from `package.json` and the version in `pubspec.yaml`. `make build` stages JS assets, builds Flutter web output when needed, syncs the extension version, and calls `scripts/build_extension.sh`.

Install into the current VS Code Server environment:

```bash
make install
```

Install into local VS Code instead:

```bash
make install-local
```

## Assets

- `js_bridge/elk_layout_only.js` is the editable source for the layout wrapper.
- `assets/elk_layout_only.js` is staged/generated by `make stage-js`.
- `assets/js/elk.bundled.js` is the vendored ELK layout engine.
- `assets/js/LICENSE` and `assets/js/README.md` are colocated with
  `elk.bundled.js` so every install location (Linux bundle, web build, VS
  Code extension package) carries the ELK license text and a pointer to
  where the vendored file can be re-downloaded. `make verify-elk-distribution`
  checks that these stay in sync everywhere `elk.bundled.js` is copied.
- Flutter web builds copy the required JS files into `build/web/assets/`.

The Flutter asset list in `pubspec.yaml` is intentionally narrow; files in `assets/` are not automatically bundled unless listed there.

## Troubleshooting

If local dependency mode fails, verify that `ROHD_LOCAL_PATH` points at a ROHD checkout whose root `pubspec.yaml` has `name: rohd` and contains the expected package paths. When it is unset, the scripts use `~/release/rohd`.

If web rendering fails after editing JS bridge files, run:

```bash
make stage-js
```

If package output seems stale, run:

```bash
make clean
make build
```

If Flutter dependencies or generated files look stale, run:

```bash
flutter clean
flutter pub get
```
