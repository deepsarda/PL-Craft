import test from 'node:test';
import assert from 'node:assert/strict';
import { HEADER_BYTES, readHeader } from '../client/frame.js';
import { parseHello, parseInput, mergeInput } from './messages.js';
import { openTestCard } from './testcard.js';
import { statements } from './install.js';
import { median, pickCollection, resolutionFor } from './bench.js';

test('B3 replaces the associative array only with a challenger faster in two thirds of paired rounds', () => {
  const aa = [118, 92, 102, 96, 98, 104, 112, 94, 105];
  const nt = [105, 100, 109, 107, 103, 122, 103, 102, 111];
  const va = [91, 84, 92, 86, 86, 97, 108, 87, 106]; // the run that settled it: faster in 8 of 9
  assert.deepEqual(pickCollection({ AA: aa, NT: nt, VA: va }), { pick: 'VA', wins: { NT: 2, VA: 8 } });
  const close = [117, 93, 101, 97, 97, 105, 111, 95, 104]; // faster in 5 of 9: noise
  assert.equal(pickCollection({ AA: aa, NT: nt, VA: close }).pick, 'AA');
});

test("Section 4's decision rule picks the resolution from B4 + B5, boundaries included", () => {
  const pick = ms => { const r = resolutionFor(ms); return `${r.width}×${r.height} far ${r.far}`; };
  assert.equal(pick(9.6), '640×360 far 48');
  assert.equal(pick(25), '640×360 far 48');
  assert.equal(pick(25.1), '320×180 far 48');
  assert.equal(pick(50), '320×180 far 48');
  assert.equal(pick(50.1), '256×144 far 32');
  assert.equal(median([9, 1, 4]), 4);
});

const input = { seq: 1834, keys: 21, mdx: -14, mdy: 3, lclick: 0, rclick: 1, held: 2 }; // Section 10.1

test('inputs outside the Section 10.1 ranges are rejected', () => {
  assert.deepEqual(parseInput(input), input);
  for (const bad of [{ keys: 128 }, { mdx: 1.5 }, { held: 6 }, { lclick: 2 }, { seq: 0 }, { seq: '1' }]) {
    assert.equal(parseInput({ ...input, ...bad }), null, JSON.stringify(bad));
  }
  assert.equal(parseInput(null), null);
  assert.equal(parseHello({ type: 'hello', world_id: 1, player_id: -7 }), null);
});

test('inputs merged during a tick keep the latest keys, add mouse movement and keep clicks', () => {
  const newer = { seq: 1835, keys: 1, mdx: 4, mdy: -1, lclick: 1, rclick: 0, held: 9 };
  assert.deepEqual(mergeInput(input, newer), { seq: 1835, keys: 1, held: 9, mdx: -10, mdy: 2, lclick: 1, rclick: 1 });
});

test('SQL files split on lines holding only "/", keeping PL/SQL intact and dropping comment-only chunks', () => {
  const file = [
    '-- Tables',
    'create table t (a number default 4 / 2)',
    '/',
    '-- just a comment',
    '  /  ',
    'begin',
    '  null;',
    'end;',
    '/',
    '',
  ].join('\n');
  assert.deepEqual(statements(file), ['-- Tables\ncreate table t (a number default 4 / 2)', 'begin\n  null;\nend;']);
});

test('T-R1 for the test card: every row of every column is painted exactly once', async () => {
  const card = await openTestCard();
  for (const mdy of [0, -400, 400]) { // level, looking up, looking down
    const frame = await card.tick({ ...input, mdy });
    const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
    const { width, height, runTotal, seq } = readHeader(dv);
    assert.equal(seq, input.seq);
    let o = HEADER_BYTES;
    let runs = 0;
    for (let c = 0; c < width; c++) {
      const painted = new Uint8Array(height);
      const n = dv.getUint16(o);
      o += 2;
      runs += n;
      for (let k = 0; k < n; k++, o += 5) {
        for (let r = dv.getUint16(o); r < dv.getUint16(o) + dv.getUint16(o + 2); r++) painted[r] += 1;
      }
      assert.ok(painted.every(v => v === 1), `column ${c} at mdy ${mdy}`);
    }
    assert.equal(o, frame.byteLength);
    assert.equal(runs, runTotal);
  }
});
