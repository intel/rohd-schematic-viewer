// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_dev_mode_test.dart
// Dependency-source configuration regression tests.
//
// 2026 September 29
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group selections share and expose the Git repository and ref',
      () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'schematic_dev_mode_test.',
    );
    addTearDown(() => sandbox.delete(recursive: true));

    final scriptsDirectory = Directory('${sandbox.path}/scripts');
    await scriptsDirectory.create();
    final script = await File('scripts/schematic_dev_mode.sh').copy(
      '${scriptsDirectory.path}/schematic_dev_mode.sh',
    );
    await File('${sandbox.path}/pubspec.yaml').writeAsString('''
name: schematic_dev_mode_fixture
dependencies:
  rohd: ^0.6.11
  rohd_hierarchy: ^0.1.0
  rohd_devtools_widgets: ^0.1.1
  rohd_source_navigator: ^0.1.0
''');

    Future<ProcessResult> configure(
      String group,
      String repositoryAndRef,
    ) =>
        Process.run(
          'bash',
          [script.path, 'configure-group', group, 'git'],
          workingDirectory: sandbox.path,
          includeParentEnvironment: false,
          environment: {
            'HOME': sandbox.path,
            'PATH': Platform.environment['PATH']!,
            'ROHD_SOURCE_VALUE': repositoryAndRef,
          },
        );

    final rohdResult = await configure(
      'rohd',
      'github.com/intel/rohd:ref-a',
    );
    expect(rohdResult.exitCode, 0, reason: rohdResult.stderr.toString());
    expect(
      await File('${sandbox.path}/pubspec_overrides.yaml').readAsString(),
      contains('ref: ref-a'),
    );

    final widgetResult = await configure(
      'widget',
      'github.com/intel/rohd:ref-b',
    );
    expect(widgetResult.exitCode, 0, reason: widgetResult.stderr.toString());
    expect(
      widgetResult.stdout.toString(),
      contains(
        'Git repository/ref is shared by all Git-backed dependency groups.',
      ),
    );

    final state = await File(
      '${sandbox.path}/.schematic_dependency_sources',
    ).readAsString();
    expect(state, contains('rohd=git\n'));
    expect(state, contains('rohd_hierarchy=git\n'));
    expect(state, contains('rohd_devtools_widgets=git\n'));
    expect(state, contains('rohd_source_navigator=git\n'));
    expect(state, contains('git_ref=ref-b\n'));

    final overrides = await File(
      '${sandbox.path}/pubspec_overrides.yaml',
    ).readAsString();
    expect(overrides, isNot(contains('ref: ref-a')));
    expect(
      RegExp(r'^\s+ref: ref-b$', multiLine: true).allMatches(overrides),
      hasLength(4),
    );
  });

  test('legacy local mode replaces stale persisted group state', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'schematic_dev_mode_legacy_test.',
    );
    addTearDown(() => sandbox.delete(recursive: true));

    final scriptsDirectory = Directory('${sandbox.path}/scripts');
    await scriptsDirectory.create();
    final script = await File('scripts/schematic_dev_mode.sh').copy(
      '${scriptsDirectory.path}/schematic_dev_mode.sh',
    );
    await File('${sandbox.path}/pubspec.yaml').writeAsString('''
name: schematic_dev_mode_fixture
dependencies:
  rohd: ^0.6.11
  rohd_hierarchy: ^0.1.0
  rohd_devtools_widgets: ^0.1.1
  rohd_source_navigator: ^0.1.0
''');

    final rohdCheckout = Directory('${sandbox.path}/release/rohd');
    Future<void> writePackage(String relativePath, String name) async {
      final packageDirectory = Directory(
        '${rohdCheckout.path}/$relativePath',
      );
      await packageDirectory.create(recursive: true);
      await File('${packageDirectory.path}/pubspec.yaml').writeAsString(
        'name: $name\n',
      );
    }

    await writePackage('.', 'rohd');
    await writePackage('packages/rohd_hierarchy', 'rohd_hierarchy');
    await writePackage(
      'packages/rohd_devtools_widgets',
      'rohd_devtools_widgets',
    );
    await writePackage(
      'packages/rohd_source_navigator',
      'rohd_source_navigator',
    );

    Future<ProcessResult> run(
      List<String> arguments, {
      String? sourceValue,
    }) =>
        Process.run(
          'bash',
          [script.path, ...arguments],
          workingDirectory: sandbox.path,
          includeParentEnvironment: false,
          environment: {
            'HOME': sandbox.path,
            'PATH': Platform.environment['PATH']!,
            if (sourceValue != null) 'ROHD_SOURCE_VALUE': sourceValue,
          },
        );

    var result = await run(
      ['configure-group', 'rohd', 'git'],
      sourceValue: 'github.com/intel/rohd:stale-ref',
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());

    result = await run(['local-all']);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    result = await run(['configure-group', 'widget', 'hosted']);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final state = await File(
      '${sandbox.path}/.schematic_dependency_sources',
    ).readAsString();
    expect(state, contains('rohd=local\n'));
    expect(state, contains('rohd_hierarchy=hosted\n'));
    expect(state, contains('rohd_devtools_widgets=hosted\n'));
    expect(state, contains('rohd_source_navigator=hosted\n'));

    final overrides = await File(
      '${sandbox.path}/pubspec_overrides.yaml',
    ).readAsString();
    expect(overrides, isNot(contains('git:')));
    expect(
      overrides,
      contains('  rohd:\n    path: ${rohdCheckout.path}\n'),
    );
    expect(overrides, isNot(contains('  rohd_hierarchy:')));

    const expectedSourcesByMode = {
      'local-rohd': {
        'rohd': 'local',
        'rohd_hierarchy': 'local',
        'rohd_devtools_widgets': 'hosted',
        'rohd_source_navigator': 'hosted',
      },
      'local-extension': {
        'rohd': 'hosted',
        'rohd_hierarchy': 'local',
        'rohd_devtools_widgets': 'local',
        'rohd_source_navigator': 'local',
      },
      'local-all': {
        'rohd': 'local',
        'rohd_hierarchy': 'local',
        'rohd_devtools_widgets': 'local',
        'rohd_source_navigator': 'local',
      },
    };
    for (final entry in expectedSourcesByMode.entries) {
      result = await run([entry.key]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final modeState = await File(
        '${sandbox.path}/.schematic_dependency_sources',
      ).readAsString();
      for (final source in entry.value.entries) {
        expect(modeState, contains('${source.key}=${source.value}\n'));
      }
      if (entry.value['rohd_devtools_widgets'] == 'local') {
        final modeOverrides = await File(
          '${sandbox.path}/pubspec_overrides.yaml',
        ).readAsString();
        expect(
          modeOverrides,
          contains(
            '  rohd_devtools_widgets:\n'
            '    path: ${rohdCheckout.path}/packages/rohd_devtools_widgets\n',
          ),
        );
        expect(
          modeOverrides,
          isNot(
            contains(
              'rohd_devtools_extension/packages/rohd_devtools_widgets',
            ),
          ),
        );
      }
    }

    result = await run(['manifest']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File('${sandbox.path}/.schematic_dependency_sources').existsSync(),
      isFalse,
    );
  });
}
