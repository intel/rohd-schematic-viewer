# Developer Notes

## Dependency configuration

The release [`pubspec.yaml`](../pubspec.yaml) is the source of truth for
current dependency constraints. Its ROHD-related hosted packages are:

- `rohd`
- `rohd_devtools_widgets`
- `rohd_hierarchy`
- `rohd_source_navigator`

The release manifest contains no dependency overrides. Development-only Git
and local sources are configured through
[`scripts/schematic_dev_mode.sh`](../scripts/schematic_dev_mode.sh) and the
ignored `pubspec_overrides.yaml`.

Dependency sources are selected independently because larger applications may
depend on several viewers or tools. For example, an application can use local
viewer packages while retaining hosted ROHD packages without defining every
possible combination as a separate mode.

### Default: hosted packages

The release dependencies in [`pubspec.yaml`](../pubspec.yaml) are hosted on
pub.dev. If `pubspec_overrides.yaml` does not exist, `flutter pub get` uses
those manifest dependencies. This is the default and requires no setup.

To return to this default from the command line, disable the generated
override. The file is moved aside rather than deleted so local edits can be
recovered:

```bash
./scripts/schematic_dev_mode.sh manifest
flutter pub get
```

The backup is named `pubspec_overrides.yaml.disabled` (with a numeric suffix
if needed) and is ignored by Git.

### Configure sources from VS Code

The VS Code tasks provide one task per dependency group with a central source
selection:

- **Configure ROHD Dependency** controls `rohd`.
- **Configure Package Dependency** controls `rohd_hierarchy` and
  `rohd_source_navigator`.
- **Configure Widget Dependency** controls all three companion packages:
  `rohd_hierarchy`, `rohd_source_navigator`, and `rohd_devtools_widgets`.
- **Configure All Dependencies** updates every ROHD-related package at once.

Each task first shows a central `hosted`/`git`/`local` Quick Pick:

- `hosted` completes without a second prompt and uses the versions declared in
  `pubspec.yaml`.
- `git` opens an editable terminal prompt for `repository:ref`. The prompt
  uses the current saved setting or defaults to
  `github.com/intel/rohd:main`. GitHub shorthand is normalized to an HTTPS
  URL. The repository and ref are shared by every Git-backed group.
- `local` opens an editable terminal prompt for the ROHD checkout. The prompt
  uses the current saved path or defaults to `~/release/rohd`. The checkout
  root is shared by every Local-backed group.

Hosted packages are not written to the override file.

Each task preserves the other dependency groups' `hosted`/`git`/`local`
selections, generates an ignored `pubspec_overrides.yaml` containing only
non-hosted packages, and runs `flutter pub get`. Changing the shared Git
repository/ref or Local checkout root updates every existing group that uses
that source.

The generated override file is also a starting point for custom development
configurations. You may edit it manually after a task generates it. Before
any later dependency-settings task replaces the file, the previous file is
saved as `pubspec_overrides.yaml.disabled` (with a numeric suffix when
needed), so manual changes are preserved and can be recovered. Source and
override updates are installed only after the complete configuration
validates, so an invalid Git or Local selection leaves the working files
unchanged.

The build and run tasks do not prompt. They use the configuration selected by
the configure task, or the hosted manifest when no override exists.

### Assumed local development directories

Local dependency mode assumes that the ROHD monorepo is checked out at:

```text
~/release/rohd
```

This checkout should contain the ROHD package at its root and the companion
packages under `packages/`. The path is used by
[`scripts/schematic_dev_mode.sh`](../scripts/schematic_dev_mode.sh) when a
package is configured as `local`.

If the checkout is elsewhere, set `ROHD_LOCAL_PATH` before configuring local
dependencies:

```bash
ROHD_LOCAL_PATH=/path/to/rohd \
  ./scripts/schematic_dev_mode.sh configure rohd local
```

The path is not required when using hosted or Git sources.

### Selecting group sources

The VS Code tasks persist independent group source selections plus the shared
Git repository/ref and Local checkout root in the ignored
`.schematic_dependency_sources` file. The equivalent command-line interface
for configuring individual packages remains available:

```bash
./scripts/schematic_dev_mode.sh configure \
  rohd local \
  rohd_hierarchy local \
  rohd_devtools_widgets git
flutter pub get
```

Supported sources are:

- `hosted`: use the package's pub.dev constraint.
- `git`: use `github.com/intel/rohd:main` by default. Set `ROHD_GIT_URL` and
  `ROHD_GIT_REF`, or set `ROHD_SOURCE_VALUE=repository:ref` with
  `configure-group`, to change the shared repository, branch, or release tag
  for every Git-backed group.
- `local`: use the checkout selected by `ROHD_LOCAL_PATH`, or
  `~/release/rohd` by default. This checkout root is shared by every
  Local-backed group.

Only the listed packages are overridden. Unlisted packages continue to use
the dependencies in `pubspec.yaml`. This makes the same command shape
usable for larger applications with more component dependencies.

The run tasks then use the selected configuration without prompting:

- **ROHD Schematic Viewer: Web Debug**
- **ROHD Schematic Viewer: Web Release WASM**
- **ROHD Schematic Viewer: Linux Debug**
- **ROHD Schematic Viewer: Linux Release**

The generated `pubspec_overrides.yaml` and
`.schematic_dependency_sources` files are ignored and must not be committed.
