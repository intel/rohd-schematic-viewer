'use strict';

const fs = require('node:fs');
const { parseArgs } = require('node:util');

const routeTolerance = 0.05;
const fields = ['x', 'y', 'width', 'height'];

function index(graph, label, laidOut) {
  const items = new Map();
  function fail(message) { throw new Error(`${label}: ${message}`); }
  function add(obj, kind, parent) {
    const id = obj?.id;
    if (typeof id !== 'string' || !id) fail(`${kind} without a string ID under ${parent}`);
    if (items.has(id)) fail(`duplicate ID ${id}`);
    const item = { kind, parent, obj };
    items.set(id, item);
    return item;
  }
  function box(obj, kind, parent) {
    const item = add(obj, kind, parent);
    if (!laidOut) return;
    const origin = items.get(parent)?.box;
    const x = parent === null && obj.x === undefined ? 0 : obj.x;
    const y = parent === null && obj.y === undefined ? 0 : obj.y;
    if (![x, y, obj.width, obj.height].every(Number.isFinite) ||
        obj.width < 0 || obj.height < 0) fail(`invalid ${kind} geometry: ${obj.id}`);
    item.box = [x + (origin?.[0] ?? 0), y + (origin?.[1] ?? 0), obj.width, obj.height];
    if (!item.box.every(Number.isFinite)) fail(`invalid absolute geometry: ${obj.id}`);
  }
  function visit(n, parent) {
    box(n, 'node', parent);
    for (const p of n.ports ?? []) box(p, 'port', n.id);
    for (const e of n.edges ?? []) add(e, 'edge', n.id);
    for (const child of n.children ?? []) visit(child, n.id);
  }
  visit(graph, null);
  for (const item of items.values()) {
    if (item.kind !== 'edge') continue;
    const e = item.obj;
    item.ends = ['source', 'target'].map(side => {
      const list = e[`${side}s`];
      if (list !== undefined && (!Array.isArray(list) || list.length !== 1)) {
        fail(`${e.id}: expected one ${side} port`);
      }
      const id = e[`${side}Port`] ?? list?.[0];
      const p = items.get(id);
      if (p?.kind !== 'port' || (list && list[0] !== id) ||
          (e[side] !== undefined && e[side] !== p.parent)) {
        fail(`${e.id}: invalid ${side} port ${id}`);
      }
      return id;
    });
    if (!laidOut) continue;
    const container = items.get(e.container ?? item.parent);
    if (container?.kind !== 'node') fail(`${e.id}: invalid route container ${e.container}`);
    if (e.sections?.length !== 1) fail(`${e.id}: expected one routed section`);
    const s = e.sections[0];
    const points = [s.startPoint, ...(s.bendPoints ?? []), s.endPoint];
    for (const [i, p] of points.entries()) {
      if (!Number.isFinite(p?.x) || !Number.isFinite(p.y)) fail(`${e.id}: invalid point ${i}`);
      if (i && Math.min(Math.abs(p.x - points[i-1].x), Math.abs(p.y - points[i-1].y)) > routeTolerance) {
        fail(`${e.id}: non-orthogonal segment at point ${i}`);
      }
    }
    for (const [i, shape, p] of [[0, s.incomingShape, s.startPoint], [1, s.outgoingShape, s.endPoint]]) {
      if (shape !== item.ends[i]) fail(`${e.id}: expected endpoint ${item.ends[i]}, got ${shape}`);
      const [px, py, w, h] = items.get(shape).box;
      const x = container.box[0] + p.x, y = container.box[1] + p.y;
      if (x < px - routeTolerance || x > px + w + routeTolerance ||
          y < py - routeTolerance || y > py + h + routeTolerance) fail(`${e.id}: detached from ${shape}`);
    }
  }
  return items;
}

function compareLayouts(input, reference, candidate) {
  const expected = index(input, 'input', false);
  const layouts = [['reference', reference], ['candidate', candidate]].map(([label, graph]) => {
    const actual = index(graph, label, true);
    for (const [id, before] of expected) {
      const after = actual.get(id);
      if (!after) throw new Error(`${label}: missing ${before.kind} ${id}`);
      if (after.kind !== before.kind || (before.kind !== 'edge' && after.parent !== before.parent)) {
        throw new Error(`${label}: changed kind or parent for ${id}`);
      }
      if (before.ends?.some((port, i) => after.ends[i] !== port)) {
        throw new Error(`${label}: rewired edge ${id}, expected ${before.ends.join(' -> ')}`);
      }
    }
    for (const id of actual.keys()) if (!expected.has(id)) throw new Error(`${label}: extra ID ${id}`);
    return actual;
  });
  const report = { nodes: 0, ports: 0, attachedRoutes: 0, maxBoxDelta: 0, worst: null };
  for (const [id, item] of layouts[0]) {
    if (item.kind === 'edge') { report.attachedRoutes++; continue; }
    report[item.kind === 'node' ? 'nodes' : 'ports']++;
    item.box.forEach((v, i) => {
      const delta = Math.abs(v - layouts[1].get(id).box[i]);
      if (delta > report.maxBoxDelta) {
        report.maxBoxDelta = delta;
        report.worst = { id, field: fields[i] };
      }
    });
  }
  return report;
}

module.exports = { compareLayouts };
if (require.main === module) {
  const usage = 'node scripts/xchkr.cjs [--max-box-delta N] input.json reference.json candidate.json';
  try {
    const { values, positionals } = parseArgs({ allowPositionals: true, options: {
      'max-box-delta': { type: 'string' }, help: { type: 'boolean', short: 'h' },
    } });
    if (values.help) console.log(usage);
    else {
      const raw = values['max-box-delta'];
      const limit = raw === undefined ? Infinity : Number(raw);
      if (positionals.length !== 3 || (raw !== undefined && (!raw.trim() || !Number.isFinite(limit) || limit < 0))) {
        throw new Error(usage);
      }
      const report = compareLayouts(...positionals.map(path => {
        try { return JSON.parse(fs.readFileSync(path, 'utf8')); }
        catch (e) { throw new Error(`${path}: ${e.message}`); }
      }));
      console.log(JSON.stringify(report));
      if (report.maxBoxDelta > limit) throw new Error(`placement exceeds limit ${limit}`);
    }
  } catch (e) {
    console.error(`xchkr: ${e.message}`);
    process.exitCode = 1;
  }
}
