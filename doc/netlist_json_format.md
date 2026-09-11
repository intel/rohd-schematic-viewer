# ROHD Netlist JSON Format (fields beyond standard Yosys JSON)

`NetlistSchematicAdapter` (`lib/src/schematic/netlist_schematic_adapter.dart`)
loads any Yosys-JSON-compatible netlist. When a netlist is ROHD-authored
(`creator: "NetlistSynthesizer (rohd)"`), it also carries a small set of
extension fields beyond the standard Yosys schema.

**This file is a copy of `doc/netlist_json_format.md` from the core `rohd`
package — that copy is the source of truth.** It's duplicated here so the
viewer's field list stays discoverable without leaving this repository.
If you're changing what the synthesizer emits, update the core doc first.

## Versioning policy

- `creator` and `version` only matter together: the extensions below only
  apply when `creator == "NetlistSynthesizer (rohd)"`.
- **The version is informational only** (`NetlistSchematicAdapter
  .latestKnownRohdNetlistVersion` is currently `0.0.2`). A missing, malformed,
  older, or newer version must never block loading — plain, unbranded Yosys
  JSON is just as valid an input and simply carries none of these fields.
  Call `isRohdNetlistVersion` only to enable optional behavior tied to one
  specific extension format.
- `0.0.2` moved the `rohd.src_trace` file dictionary from a per-module
  `files` list to a single top-level `files` array shared by every
  module — see below.

## Fields ROHD adds (schema version `0.0.2`)

| Field | Location | Standard Yosys? |
| --- | --- | --- |
| `version` | top-level | No |
| `files` | top-level | No — shared file dictionary for `rohd.src_trace`; present only when tracing is enabled |
| `attributes.rohd.src_trace` | module | No |
| `attributes.src = "generated"` | module | Key is standard; this value convention is not |
| `logic_type` | port, netname | No |
| `attributes.computed` | netname | No |
| `$struct_unpack` cell type | cell | No |
| `$struct_pack` cell type | cell | No |

### `logic_type` (ports & netnames)

Describes a signal's ROHD `Logic` shape beyond its flat bit width:

- Plain `Logic`: `{"width": N}`
- `LogicArray`: `{"width": N, "arrayDims": [...], "elementWidth": M, "elementType": {...}?}`
- `LogicStructure`: `{"typeName": "ClassName", "fields": [{"name", "width", "bits"?}, ...]}`
  (fields LSB-to-MSB; a nested field instead has `"type": {...}` recursing
  the same shape).

### `attributes.rohd.src_trace` (module) — **not the FLC format**

Present only when a `SourceTracer` was active during `Module.build()` with
a `packageRoot`, and is opt-in via `NetlistSynthesizerConfiguration(trace:
true)`. Maps this module's signals/instances to the Dart source location
that created them:

```json
{
  "signals": { "count": ["0:42:5"] },
  "instances": { "adder0": ["0:17:17"] }
}
```

`signals`/`instances` map a local name to a `["fileIndex:line:col", ...]`
frame list (only the constructor's own call site — no stack, no trie
compaction).

**Important:** despite the similar name, this is a separate, simpler
mechanism from the standalone FLC (File-Line-Column) format used by the
DevTools/schematic-viewer cross-probe feature (`TraceService.flcJson` /
`.flcModuleJson()`; see the core repo's `doc/cross_probing.md`). Nothing
in this repository reads `rohd.src_trace` today — cross-probing here goes
through `FlcService`/`FlcData` instead, which is generated and served
completely independently of netlist synthesis.

**`fileIndex` resolves against the netlist's top-level `files` array, not
a per-module list.** Given a decoded netlist document `doc` and a frame
`"0:42:5"` found at
`doc["modules"]["FilterChannel"]["attributes"]["rohd.src_trace"]["signals"]["count"]`:

```dart
final files = (doc['files'] as List).cast<String>();
final frame = '0:42:5';
final parts = frame.split(':');
final file = files[int.parse(parts[0])];   // fileIndex → path
final line = int.parse(parts[1]);
final column = parts.length > 2 ? int.parse(parts[2]) : null;
```

A single module's standalone JSON (e.g. `NetlistService.moduleJson()`, or
`NetlistService.slimJson`'s `netlist.files`) re-embeds this same shared
`files` list at its own top level, so frame indices stay resolvable
without the full combined netlist.

### `attributes.computed` (netname)

`1` marks a netname as generated/inserted infrastructure (constant
drivers, inline-SV internals) rather than a directly authored signal name.

### `$struct_pack` / `$struct_unpack` (cell types)

ROHD-only pseudo-cells with no Yosys equivalent, representing construction
(`$struct_pack`) and field access (`$struct_unpack`) of a `LogicStructure`.
Parameters: `STRUCT_NAME`, `FIELD_COUNT`, and per field `i`:
`FIELD_{i}_NAME`, `FIELD_{i}_OFFSET`, `FIELD_{i}_WIDTH`. `$struct_unpack`
has a single input port `A` and one output per field; `$struct_pack` has
one input per field and a single output port `Y`. A consumer that doesn't
recognize these types can still treat them as opaque cells via their
`port_directions`/`connections`, same as any unknown cell type.

Everything else in a ROHD netlist (`$buf`, `$const`, `$mux`, `$dff`,
`$dffe`, `$slice`, `$concat`, standard `hide_name`/`parameters`/
`port_directions`/`connections`/`attributes.top`, etc.) follows standard
Yosys JSON conventions.
