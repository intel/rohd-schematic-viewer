// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// main.dart
// Example of embedding the ROHD Schematic Viewer in a Flutter application.
//
// 2026 September
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

/// Example of embedding the ROHD Schematic Viewer in a Flutter application.
library;

import 'package:material_ui/material_ui.dart';
import 'package:rohd_schematic_viewer/schematic_viewer.dart';

const _exampleNetlist = r'''
{
  "creator": "rohd_schematic_viewer example",
  "modules": {
    "ExampleTop": {
      "attributes": {
        "top": 1
      },
      "ports": {
        "a": {
          "direction": "input",
          "bits": [1]
        },
        "b": {
          "direction": "input",
          "bits": [2]
        },
        "y": {
          "direction": "output",
          "bits": [3]
        }
      },
      "cells": {
        "and_gate": {
          "type": "$_AND_",
          "port_directions": {
            "A": "input",
            "B": "input",
            "Y": "output"
          },
          "connections": {
            "A": [1],
            "B": [2],
            "Y": [3]
          }
        }
      },
      "netnames": {
        "a": {
          "bits": [1]
        },
        "b": {
          "bits": [2]
        },
        "y": {
          "bits": [3]
        }
      }
    }
  }
}
''';

/// Runs an application containing an embedded schematic viewer.
void main() => runApp(const _ExampleApp());

class _ExampleApp extends StatelessWidget {
  const _ExampleApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Embedded ROHD Schematic Viewer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(title: const Text('Embedded Schematic')),
          body: const EmbeddedSchematicViewer.fromJson(
            schematicJson: _exampleNetlist,
          ),
        ),
      );
}
