# Pubspec Notes

This file documents non-obvious dependency choices in [pubspec.yaml](pubspec.yaml).

## ROHD Dependencies

The baseline dependency mode uses the ROHD `v0.6.10` release tag for the core
package and companion packages from `https://github.com/intel/rohd.git`.
Until the popup menu fix is released, the temporary `dependency_overrides`
block in `pubspec.yaml` replaces all of them with the named branch
`fix/devtools-popup-menu-material-ui` from
`https://github.com/desmonddak/rohd.git`.

`pubspec.yaml` depends on several ROHD packages from the GitHub monorepo:

- `rohd_devtools_widgets`
- `rohd_hierarchy`
- `rohd_source_navigator`

The packages are all resolved from the same Git repository and branch so that
their APIs remain compatible.

## Local Dependency Modes

Local modes are handled outside `pubspec.yaml` by `scripts/schematic_dev_mode.sh`, which writes an ignored `pubspec_overrides.yaml` file.

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
