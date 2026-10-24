// Milestone 0 (Section 4), `npm run db:bench`: runs B1–B6 against the schema in .env, prints the results
// with the decisions they lead to, and saves them to db/bench/results.md. The PL/SQL benchmarks run once
// compiled INTERPRETED and once NATIVE (when the database can run native code). B6 is Node's round trip.
// It recompiles pc_frame for B5, so live game sessions get ORA-04068 once and reload. It reinstalls db/ and
// drops pc_bench when done.
import os from 'node:os';
import path from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import oracledb from 'oracledb';
import { dbSettings } from './oracle.js';
import { install, statements } from './install.js';

const BENCH_DIR = fileURLToPath(new URL('../db/bench/', import.meta.url));
const KINDS = { AA: 1, NT: 2, VA: 3 };
const KIND_NAMES = { AA: 'associative array', NT: 'nested table', VA: 'VARRAY' };

// Section 4 keeps the median of three runs. The first database this ran on drifted ±20% between runs, so the
// noisier benchmarks get more runs, interleaved so that drift hits every candidate alike.
const LONG_ROUNDS = 3; // B1, B2
const B3_ROUNDS = 9;
const SHORT_ROUNDS = 11; // B4, B5: a few milliseconds each

export function spread(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return { median: s[Math.floor(s.length / 2)], min: s[0], max: s.at(-1), runs: xs };
}

export const median = xs => spread(xs).median;

// Section 4's rule on B4 + B5 at 640×360.
export function resolutionFor(frameMs) {
  if (frameMs <= 25) return { width: 640, height: 360, far: 48, verdict: 'Build at 640×360, view distance 48.' };
  if (frameMs <= 50) return { width: 320, height: 180, far: 48, verdict: 'Build at 320×180.' };
  return { width: 256, height: 144, far: 32, verdict: 'Stop: try view distance 32 and 256×144 before writing anything else.' };
}

// B3, from interleaved rounds: a challenger replaces the associative array only if it was faster in at least
// two thirds of the rounds, side by side. Otherwise the associative array stays, being indexable from 0 and
// free of EXTEND (Section 13.3). Returns the pick and each challenger's wins.
export function pickCollection(runs) {
  const wins = {};
  for (const kind of Object.keys(runs).filter(k => k !== 'AA')) {
    wins[kind] = runs[kind].filter((ns, i) => ns < runs.AA[i]).length;
  }
  const clear = Object.keys(wins).filter(k => wins[k] >= Math.ceil((runs.AA.length * 2) / 3));
  const pick = clear.sort((a, b) => median(runs[a]) - median(runs[b]))[0] ?? 'AA';
  return { pick, wins };
}

async function value(conn, call, binds = {}) {
  const r = await conn.execute(`begin :v := ${call}; end;`, { ...binds, v: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER } });
  return r.outBinds.v;
}

// Each call once per round, for n rounds; returns the spread of each.
async function rounds(conn, calls, n) {
  const runs = Object.fromEntries(Object.keys(calls).map(k => [k, []]));
  for (let i = 0; i < n; i++) {
    for (const [key, [call, binds]] of Object.entries(calls)) runs[key].push(await value(conn, call, binds));
  }
  return Object.fromEntries(Object.entries(runs).map(([key, xs]) => [key, spread(xs)]));
}

async function compile(conn, codeType, b4Kind) {
  await conn.execute(`alter session set plsql_code_type = ${codeType}`);
  await conn.execute('alter session set plsql_optimize_level = 3');
  await conn.execute(`alter session set plsql_ccflags = 'b4_kind:${b4Kind}'`);
  for (const file of ['pc_bench.pks', 'pc_bench.pkb']) {
    for (const sql of statements(readFileSync(path.join(BENCH_DIR, file), 'utf8'))) await conn.execute(sql);
  }
  await conn.execute('alter package pc_frame compile'); // B5 measures the real pc_frame, in this mode
  await conn.execute("alter session set plsql_ccflags = ''");
  const { rows } = await conn.execute(
    `select name || ' line ' || line || ': ' || text from user_errors where name in ('PC_BENCH', 'PC_FRAME') order by name, sequence`,
  );
  return rows.map(r => r[0].trim());
}

async function runMode(conn, codeType) {
  const errors = await compile(conn, codeType, KINDS.AA);
  if (errors.length) return { codeType, unavailable: errors[0] };
  const r = { codeType };
  Object.assign(r, await rounds(conn, {
    b1: ['pc_bench.b1'],
    b2Double: ['pc_bench.b2(false)'],
    b2Number: ['pc_bench.b2(true)'],
  }, LONG_ROUNDS));

  await conn.execute('begin pc_bench.b3_fill; end;');
  r.b3 = await rounds(conn, Object.fromEntries(Object.keys(KINDS).map(k => [k, ['pc_bench.b3(:k)', { k }]])), B3_ROUNDS);
  ({ pick: r.winner, wins: r.b3Wins } = pickCollection(Object.fromEntries(Object.entries(r.b3).map(([k, s]) => [k, s.runs]))));

  await compile(conn, codeType, KINDS[r.winner]); // B4 reads from the type B3 picked
  const s = await rounds(conn, {
    b4Full: ['pc_bench.b4(640, 71)'],
    b5Full: ["pc_bench.b5('pack', 640)"],
    b4Half: ['pc_bench.b4(320, 71)'],
    b5Half: ["pc_bench.b5('pack', 320)"],
    b4Small: ['pc_bench.b4(256, 47)'], // view distance 32 walks about 2/3 as many cells
    b5Small: ["pc_bench.b5('pack', 256)"],
    record: ["pc_bench.b5('record', 640)"],
  }, SHORT_ROUNDS);
  r.b4 = { full: s.b4Full, half: s.b4Half, small: s.b4Small };
  r.b5 = { full: s.b5Full, half: s.b5Half, small: s.b5Small, record: s.record };
  return r;
}

async function memory(kind) {
  const conn = await oracledb.getConnection(dbSettings()); // a fresh session, so earlier fills do not count
  try {
    return await value(conn, 'pc_bench.b3_memory(:k)', { k: kind });
  } finally {
    await conn.close();
  }
}

async function roundTrip() {
  const conn = await oracledb.getConnection(dbSettings());
  const frame = { dir: oracledb.BIND_OUT, type: oracledb.BUFFER, maxSize: 1_200_000 }; // as the relay binds it
  try {
    const times = [];
    let bytes = 0;
    for (let i = 0; i < 1010; i++) {
      const began = performance.now();
      const r = await conn.execute('begin pc_bench.b6(:frame); end;', { frame });
      if (i >= 10) times.push(performance.now() - began); // the first ten warm up
      bytes = r.outBinds.frame.length;
    }
    times.sort((a, b) => a - b);
    return { bytes, p50: times[499], p95: times[949], max: times.at(-1) };
  } finally {
    await conn.close();
  }
}

const ms = v => `${v.toFixed(1)} ms`;
const show = (s, unit) => {
  const f = v => (unit === 'ns' ? v.toFixed(0) : v.toFixed(1));
  return `${f(s.median)} ${unit} (${f(s.min)}–${f(s.max)})`;
};

// The results as Markdown: the table, memory, B6, and what Section 4's rules decide.
export function report(modes, mem, b6) {
  const cols = modes.map(m => (m.unavailable ? `${m.codeType} (not available)` : m.codeType));
  const row = (label, f) => `| ${label} | ${modes.map(m => (m.unavailable ? '–' : f(m))).join(' | ')} |`;
  const best = modes.findLast(m => !m.unavailable);
  const frame = best.b4.full.median + best.b5.full.median;
  const res = resolutionFor(frame);
  const rounds = best.b3.AA.runs.length;
  const wins = Object.entries(best.b3Wins).map(([k, n]) => `${KIND_NAMES[k]} ${n}`).join(', ');
  const why = modes.find(m => m.unavailable)?.unavailable;
  return [
    'Median, with the fastest and slowest run in brackets.',
    '',
    `| Benchmark | ${cols.join(' | ')} |`,
    `| --- | ${cols.map(() => '---').join(' | ')} |`,
    row('B1 loop, per iteration', m => show(m.b1, 'ns')),
    row('B2 BINARY_DOUBLE, per operation', m => show(m.b2Double, 'ns')),
    row('B2 NUMBER, per operation', m => show(m.b2Number, 'ns')),
    ...Object.keys(KINDS).map(k => row(`B3 ${KIND_NAMES[k]}, per random read`, m => show(m.b3[k], 'ns'))),
    row('B4 fake frame, 640 columns × 71 steps (≤ 15 ms)', m => show(m.b4.full, 'ms')),
    row('B5 pack 15,360 runs (≤ 5 ms)', m => show(m.b5.full, 'ms')),
    row('**B4 + B5 at 640×360 (≤ 25 ms)**', m => `**${ms(m.b4.full.median + m.b5.full.median)}**`),
    row('B4 + B5 at 320×180', m => ms(m.b4.half.median + m.b5.half.median)),
    row('B4 + B5 at 256×144, view distance 32', m => ms(m.b4.small.median + m.b5.small.median)),
    row('Recording 15,360 runs (counts toward the renderer)', m => show(m.b5.record, 'ms')),
    '',
    ...(why ? [`NATIVE could not compile: ${why}`, ''] : []),
    `B3 memory for 1,048,576 elements (limit 100 MB): ${Object.keys(KINDS)
      .map(k => `${KIND_NAMES[k]} ${(mem[k] / 2 ** 20).toFixed(1)} MB`).join(', ')}.`,
    '',
    `B6 round trip, ${b6.bytes} bytes, 1,000 calls: p50 ${ms(b6.p50)}, p95 ${ms(b6.p95)} (≤ 3 ms), max ${ms(b6.max)}.`,
    '',
    `## Decisions, from ${best.codeType}${best.codeType === 'interpreted' ? ' (NATIVE can only be faster)' : ''}`,
    '',
    `- B2: BINARY_DOUBLE is ${(b2ratio(best)).toFixed(1)}× faster than NUMBER, so NUMBER stays out of hot code.`,
    `- B3: the ${KIND_NAMES[best.winner]} holds the block array and the span cache. Rounds of ${rounds} faster than ` +
      `the associative array: ${wins} (a change needs ${Math.ceil((rounds * 2) / 3)}).`,
    `- B4 + B5 = ${ms(frame)} at 640×360: ${res.verdict}`,
    `- B6: ${b6.p95 <= 3 ? 'within budget.' : 'over budget. Run Node on the database machine and measure again.'}`,
  ].join('\n');
}

const b2ratio = m => m.b2Number.median / m.b2Double.median;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (!dbSettings()) {
    console.error('Set PLCRAFT_DB_USER, PLCRAFT_DB_PASSWORD and PLCRAFT_DB_CONNECT_STRING in .env (see .env.example).');
    process.exit(1);
  }
  const conn = await oracledb.getConnection(dbSettings());
  try {
    const modes = [];
    for (const codeType of ['interpreted', 'native']) {
      console.error(`Running B1–B5 compiled ${codeType}…`);
      modes.push(await runMode(conn, codeType));
    }
    console.error('Measuring B3 memory and the B6 round trip…');
    const usable = modes.findLast(m => !m.unavailable);
    await compile(conn, usable.codeType, KINDS[usable.winner]); // a failed NATIVE pass leaves pc_bench invalid
    const mem = {};
    for (const kind of Object.keys(KINDS)) mem[kind] = await memory(kind);
    const b6 = await roundTrip();
    const [[platform]] = (await conn.execute('select dbms_utility.port_string from dual')).rows;
    const results = [
      '# Milestone 0 results',
      '',
      `Run ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC by \`npm run db:bench\`. Database ${platform} at ` +
        `${process.env.PLCRAFT_DB_CONNECT_STRING}; Node on ${os.hostname()} (${process.platform}), which is what B6 measures.`,
      '',
      report(modes, mem, b6),
      '',
    ].join('\n');
    writeFileSync(path.join(BENCH_DIR, 'results.md'), results);
    console.log(`\n${results}\nSaved to db/bench/results.md.`);
  } finally {
    await install(conn); // every package back to its normal compilation
    await conn.execute('drop package pc_bench');
    await conn.close();
  }
}
