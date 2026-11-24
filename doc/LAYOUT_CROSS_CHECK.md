# Cross-checking ELK layouts with xchkr

Use [xchkr](../scripts/xchkr.cjs) when changing a layout engine or comparing
engine versions. It answers two separate questions: **are the right ports
still connected**, and **how far did the nodes and ports move**? It reads
saved JSON files offline; it does not run either solver.

## Run a comparison

1. Save `input.json`: the active ELK graph **before** layout, not the original
   Yosys netlist. Save it before passing it to a solver that may mutate it.
2. Run the reference and candidate solvers on separate copies of that same
   input. Save each raw hierarchical ELK result, before conversion to canvas
   coordinates, as `reference.json` and `candidate.json`.
3. From the repository root, run with Node.js 18 or newer (no npm install):

   ```sh
   node scripts/xchkr.cjs input.json reference.json candidate.json
   ```

Both results are checked against the input, not just against each other. If
both solvers drop the same wire, the check still fails. The checker expects
the viewer's active point-to-point edges: one orthogonal section per edge,
attached to the original source and target ports. Attachment and orthogonality
use a tolerance of 0.05 layout units. Hidden `_children` and `_edges` are not
part of the active graph.

## Interpret the result

Example output:

```json
{"nodes":4,"ports":2,"attachedRoutes":1,"maxBoxDelta":2,"worst":{"id":"root","field":"width"}}
```

Here the wire passed in both layouts, and the largest box difference was
the root's width, by two layout units. `maxBoxDelta` compares absolute `x`
and `y` positions and box widths and heights. `worst` is `null` for an exact
box match. Even then, valid wires may take different paths; the tool does not
score crossings or readability.

The default exits nonzero for invalid input, topology, geometry, or routing,
but not for placement differences. To also fail on a box difference **greater
than one layout unit**, use:

```sh
node scripts/xchkr.cjs --max-box-delta 1 input.json reference.json candidate.json
```

Run the checker's regression tests with `node --test scripts/test_xchkr.cjs`.
