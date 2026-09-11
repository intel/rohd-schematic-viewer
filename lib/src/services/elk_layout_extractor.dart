// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// elk_layout_extractor.dart
// Converts hierarchical ELK layout results to flat SchematicLayoutResult.
//
// Migrated from JavaScript layout bridge:
//   convertToAbsoluteCoordinates, extractLayoutData, extractEdge
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

/// Extracts flat [SchematicLayoutResult] from hierarchical ELK layout output.
///
/// After ELK computes layout, all coordinates are relative to parent nodes.
/// This class converts them to absolute coordinates and flattens the tree
/// into lists of instances, ports, and edges that the schematic canvas renders.
///
/// This replaces the equivalent JavaScript layout extraction functions,
/// keeping only the ELK `.layout()` call in JS.
class ElkLayoutExtractor {
  /// Convert an ELK layout result (hierarchical, relative coords) into a
  /// flat [SchematicLayoutResult] (absolute coords).
  static SchematicLayoutResult extract(Map<String, dynamic> elkResult) {
    // Phase 1: convert relative coords → absolute
    convertToAbsoluteCoordinates(elkResult, 0, 0);

    // Phase 2: flatten the tree
    final instances = <SchematicInstanceData>[];
    final ports = <SchematicPortData>[];
    final edges = <SchematicEdgeData>[];

    // Track scope-aware port connectivity for marker decisions.
    final exteriorVisible = <String>{};
    final exteriorHidden = <String>{};
    final interiorVisible = <String>{};
    final interiorHidden = <String>{};
    // Ports on visible children of expanded nodes (candidates for markers).
    final allChildPorts = <String>{};
    // Ports on expanded scope-nodes themselves (candidates for interior
    // unconnected detection — a port IS a signal, so even an unused port
    // has itself; we detect truly unconnected by absence from interior sets).
    final allScopePorts = <String>{};

    _extractNode(
      elkResult,
      instances: instances,
      ports: ports,
      edges: edges,
      exteriorVisible: exteriorVisible,
      exteriorHidden: exteriorHidden,
      interiorVisible: interiorVisible,
      interiorHidden: interiorHidden,
      allChildPorts: allChildPorts,
      allScopePorts: allScopePorts,
      isRoot: true,
      offsetX: 0,
      offsetY: 0,
    );

    final exteriorHiddenFinal = exteriorHidden.difference(exteriorVisible);
    final interiorHiddenFinal = interiorHidden.difference(interiorVisible);
    // Unconnected: child ports that no edge at their parent scope references.
    // Only exterior sets track parent-scope connectivity.  Interior sets
    // track connectivity *inside* the port's own module and must be excluded
    // so that a port with internal wiring but no external wire is correctly
    // detected as unconnected at the parent scope.
    final exteriorConnected = <String>{}
      ..addAll(exteriorVisible)
      ..addAll(exteriorHidden);
    final unconnected = allChildPorts.difference(exteriorConnected);

    // Scope-node ports on expanded modules that have no interior
    // connectivity at all (no edge or hidden edge references them).
    // A port is itself a signal, so even unused ports exist in the
    // port list.  Detect truly unconnected by absence from interior
    // sets.
    final interiorConnected = <String>{}
      ..addAll(interiorVisible)
      ..addAll(interiorHidden);
    final scopeUnconnected = allScopePorts.difference(interiorConnected);

    return SchematicLayoutResult(
      instances: instances,
      ports: ports,
      edges: edges,
      width: _double(elkResult['width'], 800),
      height: _double(elkResult['height'], 600),
      exteriorHiddenPortIds: exteriorHiddenFinal,
      interiorHiddenPortIds: interiorHiddenFinal,
      unconnectedPortIds: unconnected,
      interiorUnconnectedPortIds: scopeUnconnected,
    );
  }

  // -----------------------------------------------------------------------
  // Phase 1 – Coordinate conversion (matches JS convertToAbsoluteCoordinates)
  // -----------------------------------------------------------------------

  /// Recursively convert ELK relative positions to absolute positions.
  ///
  /// This matches the `toAbsolutePositions` behaviour:
  /// - Node position += parent offset
  /// - Port position += node's absolute position
  /// - Edge waypoints += node's absolute position
  /// - Child offset includes node padding
  static void convertToAbsoluteCoordinates(
    Map<String, dynamic> node,
    double parentX,
    double parentY,
  ) {
    // Accumulate absolute position
    final nodeX = _double(node['x']) + parentX;
    final nodeY = _double(node['y']) + parentY;
    node['x'] = nodeX;
    node['y'] = nodeY;

    // Ports: relative to node → absolute
    final nodePorts = node['ports'];
    if (nodePorts is List) {
      for (final port in nodePorts) {
        if (port is Map<String, dynamic>) {
          port['x'] = _double(port['x']) + nodeX;
          port['y'] = _double(port['y']) + nodeY;
        }
      }
    }

    // Edge sections: relative to node → absolute
    final nodeEdges = node['edges'];
    if (nodeEdges is List) {
      for (final edge in nodeEdges) {
        if (edge is Map<String, dynamic>) {
          _offsetEdgeSections(edge, nodeX, nodeY);
        }
      }
    }

    // Child offset includes padding (matches ELK layout conventions)
    var childX = nodeX;
    var childY = nodeY;
    final padding = node['padding'];
    if (padding is Map) {
      childX += _double(padding['left']);
      childY += _double(padding['top']);
    }

    // Recurse into visible children
    final children = node['children'];
    if (children is List) {
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          convertToAbsoluteCoordinates(child, childX, childY);
        }
      }
    }
  }

  /// Offset all section points of an edge by (dx, dy).
  static void _offsetEdgeSections(
    Map<String, dynamic> edge,
    double dx,
    double dy,
  ) {
    final sections = edge['sections'];
    if (sections is! List) {
      return;
    }
    for (final section in sections) {
      if (section is! Map<String, dynamic>) {
        continue;
      }
      _offsetPoint(section['startPoint'], dx, dy);
      _offsetPoint(section['endPoint'], dx, dy);
      final bps = section['bendPoints'];
      if (bps is List) {
        for (final bp in bps) {
          _offsetPoint(bp, dx, dy);
        }
      }
    }
  }

  static void _offsetPoint(dynamic pt, double dx, double dy) {
    if (pt is Map<String, dynamic>) {
      pt['x'] = _double(pt['x']) + dx;
      pt['y'] = _double(pt['y']) + dy;
    }
  }

  // -----------------------------------------------------------------------
  // Phase 2 – Flatten hierarchy (matches JS extractLayoutData + extractEdge)
  // -----------------------------------------------------------------------

  /// Recursively extract flat lists from the ELK tree.
  ///
  /// The root node is skipped (it's a viewport container) but its position
  /// becomes the viewport offset subtracted from all child coordinates.
  static void _extractNode(
    Map<String, dynamic> elkNode, {
    required List<SchematicInstanceData> instances,
    required List<SchematicPortData> ports,
    required List<SchematicEdgeData> edges,
    required Set<String> exteriorVisible,
    required Set<String> exteriorHidden,
    required Set<String> interiorVisible,
    required Set<String> interiorHidden,
    required Set<String> allChildPorts,
    required Set<String> allScopePorts,
    required bool isRoot,
    required double offsetX,
    required double offsetY,
  }) {
    final hasId = elkNode['id'] != null;
    final skipThisNode = isRoot && hasId;

    // Root position becomes the viewport offset
    var rootOffsetX = offsetX;
    var rootOffsetY = offsetY;
    if (skipThisNode) {
      rootOffsetX = _double(elkNode['x']);
      rootOffsetY = _double(elkNode['y']);
    }

    if (hasId && !skipThisNode) {
      // --- Instance ---
      final visibleChildren = _isList(elkNode['children']);
      final hiddenChildren = _isList(elkNode['_children']);
      final hwMeta = _map(elkNode['hwMeta']);
      final nodeId = elkNode['id'].toString();

      final childIds = <String>[];

      // Recurse visible children
      final children = elkNode['children'];
      if (children is List) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            // Skip dummy passthrough nodes (inserted for ELK routing of
            // self-referencing edges).  Their edges are merged below.
            final childHwMeta = child['hwMeta'];
            if (childHwMeta is Map<String, dynamic> &&
                childHwMeta['_passthrough'] == true) {
              continue;
            }
            _extractNode(
              child,
              instances: instances,
              ports: ports,
              edges: edges,
              exteriorVisible: exteriorVisible,
              exteriorHidden: exteriorHidden,
              interiorVisible: interiorVisible,
              interiorHidden: interiorHidden,
              allChildPorts: allChildPorts,
              allScopePorts: allScopePorts,
              isRoot: false,
              offsetX: rootOffsetX,
              offsetY: rootOffsetY,
            );
            if (child['id'] != null) {
              childIds.add(child['id'].toString());
              // Track ports of visible children for unconnected detection.
              final childPorts = child['ports'];
              if (childPorts is List) {
                for (final p in childPorts) {
                  if (p is Map<String, dynamic>) {
                    final portId = p['id']?.toString();
                    if (portId != null) {
                      allChildPorts.add(portId);
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Track scope-node ports so we can detect ports with no interior
      // connectivity (truly unconnected inside).  Track for any compound
      // node — one with visible children, hidden children, or slim
      // _connectedPorts data.  Leaf nodes (primitives) have none of
      // these and their ports are not tracked.
      if (_isList(elkNode['children']) ||
          _isList(elkNode['_children']) ||
          elkNode['_connectedPorts'] is List) {
        final ownPorts = elkNode['ports'];
        if (ownPorts is List) {
          for (final p in ownPorts) {
            if (p is Map<String, dynamic>) {
              final portId = p['id']?.toString();
              if (portId != null) {
                allScopePorts.add(portId);
              }
            }
          }
        }
      }

      // Check if any hidden child is non-primitive (has children itself).
      var hasHiddenNonPrimitive = false;
      var hasAnyNonPrimitive = false;
      final hiddenList = elkNode['_children'];
      if (hiddenList is List) {
        for (final hc in hiddenList) {
          if (hc is Map<String, dynamic>) {
            if (_isList(hc['children']) || _isList(hc['_children'])) {
              hasHiddenNonPrimitive = true;
              hasAnyNonPrimitive = true;
              break;
            }
          }
        }
      }
      // Also check visible children for non-primitive ones.
      if (!hasAnyNonPrimitive) {
        final visList = elkNode['children'];
        if (visList is List) {
          for (final vc in visList) {
            if (vc is Map<String, dynamic>) {
              if (_isList(vc['children']) || _isList(vc['_children'])) {
                hasAnyNonPrimitive = true;
                break;
              }
            }
          }
        }
      }

      instances.add(
        SchematicInstanceData(
          id: nodeId,
          x: _double(elkNode['x']) - rootOffsetX,
          y: _double(elkNode['y']) - rootOffsetY,
          width: _double(elkNode['width'], 50),
          height: _double(elkNode['height'], 30),
          name: (hwMeta['name'] ?? elkNode['id']).toString(),
          instanceName: hwMeta['instanceName']?.toString(),
          cls: (hwMeta['cls'] ?? '').toString(),
          bodyText: _bodyText(hwMeta['bodyText']),
          isExternalPort: hwMeta['isExternalPort'] == true,
          cssClass: (hwMeta['cssClass'] ?? '').toString(),
          children: childIds,
          hasChildren: visibleChildren || hiddenChildren,
          isExpanded: visibleChildren,
          isPartiallyExpanded: elkNode['isPartiallyExpanded'] == true,
          hasHiddenNonPrimitiveChildren: hasHiddenNonPrimitive,
          hasNonPrimitiveChildren: hasAnyNonPrimitive,
          hierarchyPath: elkNode['hierarchyNodeId']?.toString(),
          definitionName: hwMeta['definitionName']?.toString(),
        ),
      );

      // --- Ports of this instance ---
      final nodePorts = elkNode['ports'];
      if (nodePorts is List) {
        for (final p in nodePorts) {
          if (p is Map<String, dynamic>) {
            final portMeta = _map(p['hwMeta']);
            final props = _map(p['properties']);
            ports.add(
              SchematicPortData(
                id: (p['id'] ?? '').toString(),
                instanceId: nodeId,
                x: _double(p['x']) - rootOffsetX,
                y: _double(p['y']) - rootOffsetY,
                width: _double(p['width'], 10),
                height: _double(p['height'], 10),
                name: (portMeta['name'] ?? p['id'] ?? '').toString(),
                direction: (p['direction'] ?? 'INOUT').toString(),
                side: (props['side'] ?? 'EAST').toString(),
                signalWidth: _int(portMeta['signalWidth'], 1),
              ),
            );
          }
        }
      }

      // --- Edges owned by this instance ---
      _extractEdges(
        elkNode,
        edges: edges,
        offsetX: rootOffsetX,
        offsetY: rootOffsetY,
        scopeHierarchyPath: elkNode['hierarchyNodeId']?.toString(),
      );

      // --- Categorize port connectivity for marker decisions ---
      _categorizeEdgePorts(
        elkNode['edges'],
        nodeId,
        exteriorVisible,
        interiorVisible,
      );
      _categorizeEdgePorts(
        elkNode['_edges'],
        nodeId,
        exteriorHidden,
        interiorHidden,
      );

      // --- Slim-connected ports: interior markers from slim attribute ---
      // Slim modules carry a _connectedPorts list indicating which ports
      // have internal connectivity.  These ports get interior markers so
      // the user knows the module has wiring on that port, even before
      // full edge data is fetched.
      final connectedPorts = elkNode['_connectedPorts'];
      if (connectedPorts is List) {
        for (final portId in connectedPorts) {
          if (portId is String) {
            interiorHidden.add(portId);
          }
        }
      }

      // --- Slim-JSON fallback: assume all child ports are connected ---
      // When a node has visible children but zero edge data (loaded from
      // slim JSON without connectivity), neither edges nor _edges exist.
      // Without markers the user has no way to trigger incremental
      // connectivity fetch, so we optimistically mark every child port as
      // having a hidden exterior connection (parent-scope wire that hasn't
      // been fetched).  Children with hidden sub-modules also get interior
      // markers so the user can drill in.
      //
      // This applies to both partially expanded (blocks-only) and fully
      // expanded nodes.  When a module's only children are primitives,
      // expandNonPrimitives returns false and toggleNode fully expands
      // it — isPartiallyExpanded is false, but the children still need
      // port markers.
      //
      // Once real connectivity is fetched and the adapter rebuilt, the
      // real edge data populates these sets and the difference logic
      // (exteriorHidden - exteriorVisible) naturally suppresses markers
      // for ports whose wires are already visible.
      if (!_isList(elkNode['edges']) && !_isList(elkNode['_edges'])) {
        final visChildren = elkNode['children'];
        if (visChildren is List) {
          for (final child in visChildren) {
            if (child is Map<String, dynamic>) {
              final childPorts = child['ports'];
              if (childPorts is List) {
                for (final p in childPorts) {
                  if (p is Map<String, dynamic>) {
                    final portId = p['id']?.toString();
                    if (portId != null) {
                      exteriorHidden.add(portId);
                      // Interior marker when child can be drilled into.
                      if (_isList(child['children']) ||
                          _isList(child['_children'])) {
                        interiorHidden.add(portId);
                      }
                    }
                  }
                }
              }
            }
          }

          // Also mark the node's own ports as having hidden interior
          // connections.  For the top block this is the only source of
          // port markers because there is no parent scope that would
          // add exterior markers.  Once real edge data is fetched the
          // difference logic (interiorHidden − interiorVisible)
          // naturally suppresses markers for ports with visible wires.
          //
          // Skip when _connectedPorts is present — the slim-connected
          // block above already added the truly-connected ports to
          // interiorHidden.  Adding all own ports here would mask
          // unconnected ports (reset, clk) that should get outline-only
          // interior markers instead.
          if (elkNode['_connectedPorts'] is! List) {
            final ownPorts = elkNode['ports'];
            if (ownPorts is List) {
              for (final p in ownPorts) {
                if (p is Map<String, dynamic>) {
                  final portId = p['id']?.toString();
                  if (portId != null) {
                    interiorHidden.add(portId);
                  }
                }
              }
            }
          }
        }
      }
    } else {
      // Root node or node without ID – process children + edges only
      final children = elkNode['children'];
      if (children is List) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            _extractNode(
              child,
              instances: instances,
              ports: ports,
              edges: edges,
              exteriorVisible: exteriorVisible,
              exteriorHidden: exteriorHidden,
              interiorVisible: interiorVisible,
              interiorHidden: interiorHidden,
              allChildPorts: allChildPorts,
              allScopePorts: allScopePorts,
              isRoot: false,
              offsetX: rootOffsetX,
              offsetY: rootOffsetY,
            );
          }
        }
      }
      _extractEdges(
        elkNode,
        edges: edges,
        offsetX: rootOffsetX,
        offsetY: rootOffsetY,
        scopeHierarchyPath: elkNode['hierarchyNodeId']?.toString(),
      );
      final rootId = elkNode['id']?.toString() ?? '';
      _categorizeEdgePorts(
        elkNode['edges'],
        rootId,
        exteriorVisible,
        interiorVisible,
      );
      _categorizeEdgePorts(
        elkNode['_edges'],
        rootId,
        exteriorHidden,
        interiorHidden,
      );
    }
  }

  /// Categorize ports referenced by [edgeList] as interior (belonging to
  /// [scopeNodeId]) or exterior (belonging to a child).
  static void _categorizeEdgePorts(
    dynamic edgeList,
    String scopeNodeId,
    Set<String> exteriorSet,
    Set<String> interiorSet,
  ) {
    if (edgeList is! List) {
      return;
    }
    for (final e in edgeList) {
      if (e is! Map<String, dynamic>) {
        continue;
      }
      final source = e['source']?.toString();
      final sourcePort = e['sourcePort']?.toString();
      final target = e['target']?.toString();
      final targetPort = e['targetPort']?.toString();

      if (sourcePort != null && source != null) {
        if (source == scopeNodeId) {
          interiorSet.add(sourcePort);
        } else {
          exteriorSet.add(sourcePort);
        }
      }
      if (targetPort != null && target != null) {
        if (target == scopeNodeId) {
          interiorSet.add(targetPort);
        } else {
          exteriorSet.add(targetPort);
        }
      }
    }
  }

  /// Extract all edges from `elkNode.edges`.
  ///
  /// Passthrough edge pairs (split via dummy nodes for ELK routing) are
  /// merged back into single edges using the `_passthroughGroup` marker.
  static void _extractEdges(
    Map<String, dynamic> elkNode, {
    required List<SchematicEdgeData> edges,
    required double offsetX,
    required double offsetY,
    String? scopeHierarchyPath,
  }) {
    final nodeEdges = elkNode['edges'];
    if (nodeEdges is! List) {
      return;
    }

    // Separate normal edges from passthrough halves.
    final passthroughGroups = <String, List<Map<String, dynamic>>>{};

    for (final e in nodeEdges) {
      if (e is Map<String, dynamic>) {
        final group = e['_passthroughGroup'];
        if (group is String) {
          passthroughGroups.putIfAbsent(group, () => []).add(e);
        } else {
          final edge = _extractEdge(
            e,
            offsetX,
            offsetY,
            scopeHierarchyPath: scopeHierarchyPath,
          );
          if (edge != null) {
            edges.add(edge);
          }
        }
      }
    }

    // Merge passthrough pairs into single edges.
    for (final entry in passthroughGroups.entries) {
      final groupId = entry.key;
      final halves = entry.value;
      if (halves.length != 2) {
        // Fallback: emit individually.
        for (final e in halves) {
          final edge = _extractEdge(
            e,
            offsetX,
            offsetY,
            scopeHierarchyPath: scopeHierarchyPath,
          );
          if (edge != null) {
            edges.add(edge);
          }
        }
        continue;
      }

      // Sort so '_a' comes before '_b'.
      halves.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

      final pointsA = _extractEdgePoints(halves[0], offsetX, offsetY);
      final pointsB = _extractEdgePoints(halves[1], offsetX, offsetY);

      // Concatenate, deduplicating the junction point.
      final merged = <SchematicPoint>[...pointsA];
      if (merged.isNotEmpty && pointsB.isNotEmpty) {
        final lastA = merged.last;
        final firstB = pointsB.first;
        if ((lastA.x - firstB.x).abs() < 0.5 &&
            (lastA.y - firstB.y).abs() < 0.5) {
          merged.addAll(pointsB.skip(1));
        } else {
          merged.addAll(pointsB);
        }
      } else {
        merged.addAll(pointsB);
      }

      if (merged.length < 2) {
        continue;
      }

      final hwMeta = _map(halves[0]['hwMeta']);
      final parentMeta = _map(hwMeta['parent']);
      final parentHwMeta = _map(parentMeta['hwMeta']);

      edges.add(
        SchematicEdgeData(
          id: groupId,
          source: _str(halves[0]['source']),
          sourcePort: _str(halves[0]['sourcePort']),
          target: _str(halves[1]['target']),
          targetPort: _str(halves[1]['targetPort']),
          name: (hwMeta['name'] ?? '').toString(),
          signalWidth: _int(hwMeta['signalWidth'], 1),
          parentId: _str(parentMeta['id']),
          parentName: (parentHwMeta['name'] ?? '').toString(),
          cssClass: (hwMeta['cssClass'] ?? '').toString(),
          points: merged,
          scopeHierarchyPath: scopeHierarchyPath,
          addr: (hwMeta['addr'] is List)
              ? (hwMeta['addr'] as List).cast<int>()
              : null,
        ),
      );
    }
  }

  /// Extract the point list from an ELK edge without creating a full
  /// [SchematicEdgeData].  Used by passthrough edge merging.
  static List<SchematicPoint> _extractEdgePoints(
    Map<String, dynamic> elkEdge,
    double offsetX,
    double offsetY,
  ) {
    final points = <SchematicPoint>[];
    final sections = elkEdge['sections'];
    if (sections is List) {
      for (final section in sections) {
        if (section is! Map<String, dynamic>) {
          continue;
        }
        final sp = section['startPoint'];
        if (sp is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(sp['x']) - offsetX,
              _double(sp['y']) - offsetY,
            ),
          );
        }
        final bps = section['bendPoints'];
        if (bps is List) {
          for (final bp in bps) {
            if (bp is Map<String, dynamic>) {
              points.add(
                SchematicPoint(
                  _double(bp['x']) - offsetX,
                  _double(bp['y']) - offsetY,
                ),
              );
            }
          }
        }
        final ep = section['endPoint'];
        if (ep is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(ep['x']) - offsetX,
              _double(ep['y']) - offsetY,
            ),
          );
        }
      }
    }
    final srcPt = elkEdge['sourcePoint'];
    if (srcPt is Map<String, dynamic>) {
      points.insert(
        0,
        SchematicPoint(
          _double(srcPt['x']) - offsetX,
          _double(srcPt['y']) - offsetY,
        ),
      );
    }
    final primBps = elkEdge['bendPoints'];
    if (primBps is List) {
      for (final bp in primBps) {
        if (bp is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(bp['x']) - offsetX,
              _double(bp['y']) - offsetY,
            ),
          );
        }
      }
    }
    final tgtPt = elkEdge['targetPoint'];
    if (tgtPt is Map<String, dynamic>) {
      points.add(
        SchematicPoint(
          _double(tgtPt['x']) - offsetX,
          _double(tgtPt['y']) - offsetY,
        ),
      );
    }
    return points;
  }

  /// Convert a single ELK edge into a [SchematicEdgeData].
  ///
  /// Handles both extended edges (with `sections`) and primitive edges
  /// (with `sourcePoint`/`targetPoint`/`bendPoints`).
  static SchematicEdgeData? _extractEdge(
    Map<String, dynamic> elkEdge,
    double offsetX,
    double offsetY, {
    String? scopeHierarchyPath,
  }) {
    final points = <SchematicPoint>[];

    // Extended edges – sections with start/bend/end points
    final sections = elkEdge['sections'];
    if (sections is List) {
      for (final section in sections) {
        if (section is! Map<String, dynamic>) {
          continue;
        }
        final sp = section['startPoint'];
        if (sp is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(sp['x']) - offsetX,
              _double(sp['y']) - offsetY,
            ),
          );
        }
        final bps = section['bendPoints'];
        if (bps is List) {
          for (final bp in bps) {
            if (bp is Map<String, dynamic>) {
              points.add(
                SchematicPoint(
                  _double(bp['x']) - offsetX,
                  _double(bp['y']) - offsetY,
                ),
              );
            }
          }
        }
        final ep = section['endPoint'];
        if (ep is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(ep['x']) - offsetX,
              _double(ep['y']) - offsetY,
            ),
          );
        }
      }
    }

    // Primitive edges
    final srcPt = elkEdge['sourcePoint'];
    if (srcPt is Map<String, dynamic>) {
      points.insert(
        0,
        SchematicPoint(
          _double(srcPt['x']) - offsetX,
          _double(srcPt['y']) - offsetY,
        ),
      );
    }
    final primBps = elkEdge['bendPoints'];
    if (primBps is List) {
      for (final bp in primBps) {
        if (bp is Map<String, dynamic>) {
          points.add(
            SchematicPoint(
              _double(bp['x']) - offsetX,
              _double(bp['y']) - offsetY,
            ),
          );
        }
      }
    }
    final tgtPt = elkEdge['targetPoint'];
    if (tgtPt is Map<String, dynamic>) {
      points.add(
        SchematicPoint(
          _double(tgtPt['x']) - offsetX,
          _double(tgtPt['y']) - offsetY,
        ),
      );
    }

    if (points.length < 2) {
      return null;
    }

    final hwMeta = _map(elkEdge['hwMeta']);
    final parentMeta = _map(hwMeta['parent']);
    final parentHwMeta = _map(parentMeta['hwMeta']);

    return SchematicEdgeData(
      id: (elkEdge['id'] ?? '').toString(),
      source: _str(elkEdge['source']) ?? _firstStr(elkEdge['sources']),
      sourcePort: _str(elkEdge['sourcePort']),
      target: _str(elkEdge['target']) ?? _firstStr(elkEdge['targets']),
      targetPort: _str(elkEdge['targetPort']),
      points: points,
      name: (hwMeta['name'] ?? '').toString(),
      parentId: _str(parentMeta['id']),
      parentName: (parentHwMeta['name'] ?? '').toString(),
      cssClass: (hwMeta['cssClass'] ?? '').toString(),
      signalWidth: _int(hwMeta['signalWidth'], 1),
      scopeHierarchyPath: scopeHierarchyPath,
      addr: (hwMeta['addr'] is List)
          ? (hwMeta['addr'] as List).cast<int>()
          : null,
    );
  }

  // -----------------------------------------------------------------------
  // Tiny helpers
  // -----------------------------------------------------------------------

  static double _double(dynamic v, [double fallback = 0]) =>
      (v is num) ? v.toDouble() : fallback;

  static int _int(dynamic v, [int fallback = 0]) =>
      (v is num) ? v.toInt() : fallback;

  static Map<String, dynamic> _map(dynamic v) =>
      (v is Map<String, dynamic>) ? v : const {};

  static bool _isList(dynamic v) => v is List && v.isNotEmpty;

  static String? _str(dynamic v) =>
      (v != null && v.toString().isNotEmpty) ? v.toString() : null;

  static String? _firstStr(dynamic v) =>
      (v is List && v.isNotEmpty) ? v.first.toString() : null;

  /// Handle bodyText that may be a string or list-of-strings.
  static String _bodyText(dynamic v) {
    if (v is String) {
      return v;
    }
    if (v is List) {
      return v.map((e) => e.toString()).join('\n');
    }
    return '';
  }
}
