const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ELK = require('../assets/js/elk.bundled.js');
const { compareLayouts } = require('./xchkr.cjs');

const input = { id: 'root', children: [{ id: 'scope',
  children: ['a', 'b'].map(id => ({ id, width: 20, height: 10,
    ports: [{ id: `${id}.p`, width: 2, height: 2 }] })),
  edges: [{ id: 'wire', source: 'a', sourcePort: 'a.p', target: 'b', targetPort: 'b.p' }],
}] };

let reference;
test.before(async () => {
  const elk = new ELK();
  try { reference = await elk.layout(structuredClone(input)); }
  finally { elk.terminateWorker(); }
});

test('validates a real compound elkjs layout, independent of edge storage location', () => {
  const candidate = structuredClone(reference);
  candidate.edges = candidate.children[0].edges.splice(0);
  const report = compareLayouts(input, reference, candidate);
  assert.deepEqual(report, { nodes: 4, ports: 2, attachedRoutes: 1, maxBoxDelta: 0, worst: null });
});

test('the input catches shared omissions, rewiring, and duplicate IDs', () => {
  const broken = structuredClone(reference);
  const scope = broken.children[0];
  const [wire] = scope.edges.splice(0);
  assert.throws(() => compareLayouts(input, broken, broken), /reference: missing edge wire/);
  scope.edges.push(wire);
  [wire.source, wire.target] = [wire.target, wire.source];
  [wire.sourcePort, wire.targetPort] = [wire.targetPort, wire.sourcePort];
  const s = wire.sections[0];
  [s.incomingShape, s.outgoingShape] = [s.outgoingShape, s.incomingShape];
  [s.startPoint, s.endPoint] = [s.endPoint, s.startPoint];
  assert.throws(() => compareLayouts(input, reference, broken), /candidate: rewired edge wire/);
  scope.edges.push(wire);
  assert.throws(() => compareLayouts(input, reference, broken), /duplicate ID wire/);
});

test('rejects missing, diagonal and detached routes even when box positions match', () => {
  for (const [edit, error] of [
    [e => { delete e.sections; }, /wire: expected one routed section/],
    [e => { e.sections[0].bendPoints = [{ x: 1000, y: 2000 }]; }, /wire: non-orthogonal/],
    [e => { for (const p of [e.sections[0].startPoint, e.sections[0].endPoint]) p.y += 100; }, /wire: detached/],
  ]) {
    const candidate = structuredClone(reference);
    edit(candidate.children[0].edges[0]);
    assert.throws(() => compareLayouts(input, reference, candidate), error);
  }
});

test('CLI reports placement differences and gates only above the requested limit', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xchkr-'));
  const candidate = structuredClone(reference);
  candidate.width += 2;
  const paths = [input, reference, candidate].map((_, i) => path.join(dir, `${i}.json`));
  try {
    [input, reference, candidate].forEach((g, i) => fs.writeFileSync(paths[i], JSON.stringify(g)));
    function run(...args) {
      return spawnSync(process.execPath, [require.resolve('./xchkr.cjs'), ...args, ...paths], { encoding: 'utf8' });
    }
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.maxBoxDelta, 2);
    assert.deepEqual(report.worst, { id: 'root', field: 'width' });
    assert.equal(run('--max-box-delta', '2').status, 0);
    assert.equal(run('--max-box-delta', '1').status, 1);
  } finally {
    paths.forEach(p => fs.rmSync(p, { force: true }));
    fs.rmdirSync(dir);
  }
});
