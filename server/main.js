// PL/Craft relay (Section 12): serves client/ and gives every WebSocket its own Oracle session.
// Inputs go up as JSON, frames come back as one binary message each, one tick at a time per player.
import http from 'node:http';
import path from 'node:path';
import { readdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { readHeader } from '../client/frame.js';
import { parseHello, parseInput, mergeInput } from './messages.js';
import { dbSettings, openOracle } from './oracle.js';
import { INTERPRETED_WARNING, installFromEnv } from './install.js';
import { openTestCard } from './testcard.js';

const PORT = Number(process.env.PORT ?? 8080);
const TESTCARD = process.argv.includes('--testcard');
const STATS_EVERY_MS = 5000;
const IDLE_SAVE_MS = 2000; // COMMIT_INTERVAL_S's default

if (!TESTCARD && !dbSettings()) {
  console.error('Set PLCRAFT_DB_USER, PLCRAFT_DB_PASSWORD and PLCRAFT_DB_CONNECT_STRING in .env (see .env.example), or run npm run testcard.');
  process.exit(1);
}
const openEngine = TESTCARD ? openTestCard : openOracle;

// Bring the schema in line with db/ before anyone connects. If that fails, start anyway: every browser
// then shows the same Oracle error in its session transcript, and a restart retries the install.
if (!TESTCARD) {
  try {
    const { native, errors } = await installFromEnv();
    if (!native) console.warn(INTERPRETED_WARNING);
    if (errors.length) console.error(`db/ installed, but these did not compile:\n${errors.join('\n')}`);
    else console.log(`db/ installed, compiled ${native ? 'NATIVE' : 'INTERPRETED'}.`);
  } catch (err) {
    console.error(`Could not install db/: ${err.message}`);
  }
}

// ---- Static files ---------------------------------------------------------------------------------------

// Only files present in client/ at startup are served, so no request path can reach outside it.
// Restart the server after adding a file.
const CLIENT_DIR = fileURLToPath(new URL('../client/', import.meta.url));
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.woff2': 'font/woff2',
};
const FILES = new Map(
  readdirSync(CLIENT_DIR, { recursive: true })
    .filter(f => TYPES[path.extname(f)] && !f.endsWith('.test.js'))
    .map(f => [`/${f.split(path.sep).join('/')}`, path.join(CLIENT_DIR, f)]),
);
FILES.set('/', FILES.get('/index.html'));

const server = http.createServer(async (req, res) => {
  try {
    const file = FILES.get(new URL(req.url, 'http://localhost').pathname);
    if (!file) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('Not found');
      return;
    }
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)], 'cache-control': 'no-cache' }).end(body);
  } catch (err) {
    console.error(`${req.method} ${req.url} failed`, err);
    res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' }).end('Server error');
  }
});

// ---- Sessions -------------------------------------------------------------------------------------------

// One session per player, because a second one would save over the first (Section 17.1).
const players = new Map(); // player id → { ws, closed }, closed settling once that session has shut down
const live = new Set(); // every session's closed promise, for a clean stop

const wss = new WebSocketServer({
  server,
  path: '/ws',
  maxPayload: 4096, // inputs are about 100 bytes
  // Browsers always send Origin. Refusing other sites stops a page elsewhere from driving a local game.
  verifyClient: ({ origin, req }) => !origin || URL.parse(origin)?.host === req.headers.host,
});

wss.on('connection', ws => {
  const done = session(ws);
  live.add(done);
  done.finally(() => live.delete(done));
});

function session(ws) {
  let hello = null;
  let opening = null; // promise of the engine
  let engine = null;
  let pending = null; // the next input, merged if several arrived during one tick
  let ticking = null; // promise of the tick loop, while it runs
  let saveDue = false; // ticks stopped, so pc_engine.save should run
  let idle = null; // timer that sets saveDue
  const calls = [];
  let renderUs = 0;
  let packUs = 0;
  let finish;
  const closed = new Promise(resolve => { finish = resolve; });

  const who = () => `player ${hello?.playerId ?? '?'}`;
  const sendJson = msg => ws.readyState === ws.OPEN && ws.send(JSON.stringify(msg));
  const fail = (message, close = false) => {
    sendJson({ type: 'error', message });
    if (close) ws.close();
  };

  async function start(msg) {
    const h = parseHello(msg);
    if (!h) return fail('The first message must be a hello with a world_id and a player_id.', true);
    const other = players.get(h.playerId);
    if (other?.ws.readyState === ws.OPEN) {
      return fail(
        `Player ${h.playerId} is already playing in another tab or window. ` +
          `Close it, or open this page with ?player=${h.playerId + 1} to play as someone else.`,
        true,
      );
    }
    hello = h;
    players.set(h.playerId, { ws, closed });
    // A reload closes the old socket just before this hello arrives: let that session finish saving first.
    if (other) await other.closed;
    if (ws.readyState !== ws.OPEN) return;
    opening = openEngine(h);
    try {
      engine = await opening;
      sendJson({ type: 'ready', width: engine.width, height: engine.height, fov: engine.fov, testcard: Boolean(engine.testcard) });
    } catch (err) {
      console.error(`${who()}: init_session failed`, err);
      fail(err.message, true);
    }
  }

  // pc_engine commits from inside ticks, at most every COMMIT_INTERVAL_S, and a paused browser stops
  // ticking. So once ticks stop for a moment, save once: the player and any edits since the last commit
  // are then never at risk for longer than that (Section 11.5).
  const armIdleSave = () => {
    clearTimeout(idle);
    idle = setTimeout(() => {
      saveDue = true;
      kick();
    }, IDLE_SAVE_MS);
  };

  function kick() {
    ticking ??= pump().finally(() => { ticking = null; });
  }

  // Ticks and saves share one connection, so they take turns here.
  async function pump() {
    while ((pending || saveDue) && ws.readyState === ws.OPEN) {
      if (!pending) {
        saveDue = false;
        try {
          await engine.save();
        } catch (err) {
          console.error(`${who()}: saving after the game paused failed`, err);
        }
        continue;
      }
      const input = pending;
      pending = null;
      const began = performance.now();
      try {
        const frame = await engine.tick(input);
        armIdleSave();
        calls.push(performance.now() - began);
        const header = readHeader(new DataView(frame.buffer, frame.byteOffset, frame.byteLength));
        renderUs += header.renderUs;
        packUs += header.packUs;
        if (ws.readyState === ws.OPEN) ws.send(frame);
      } catch (err) {
        console.error(`${who()}: tick failed on input ${JSON.stringify(input)}`, err);
        if (engine.lost()) return fail('Lost the connection to Oracle.', true);
        fail(err.message);
      }
    }
  }

  ws.on('message', (data, isBinary) => {
    let msg = null;
    try {
      if (!isBinary) msg = JSON.parse(data.toString());
    } catch {
      // not JSON: handled below like any other unreadable message
    }
    if (!hello) return void start(msg);
    if (!engine) return; // still loading the world; the browser waits for ready before sending input
    const input = parseInput(msg);
    if (!input) return fail('The server could not read that input message.');
    pending = pending ? mergeInput(pending, input) : input;
    kick();
  });

  ws.on('error', err => console.error(`${who()}: socket error`, err));

  const stats = setInterval(() => {
    if (!calls.length) return;
    const n = calls.length;
    calls.sort((a, b) => a - b);
    const pct = q => calls[Math.ceil(q * n) - 1].toFixed(1);
    const avg = us => (us / n / 1000).toFixed(1);
    console.log(`${who()}: ${n} ticks, call p50 ${pct(0.5)} ms p95 ${pct(0.95)} ms, render ${avg(renderUs)} ms, pack ${avg(packUs)} ms`);
    calls.length = 0;
    renderUs = 0;
    packUs = 0;
  }, STATS_EVERY_MS);

  ws.on('close', async () => {
    clearInterval(stats);
    clearTimeout(idle);
    if (opening) {
      const opened = await opening.catch(() => null);
      await ticking;
      try {
        await opened?.shutdown();
      } catch (err) {
        console.error(`${who()}: shutdown failed, so recent changes may not be saved`, err);
      }
    }
    if (hello && players.get(hello.playerId)?.ws === ws) players.delete(hello.playerId);
    finish();
  });

  return closed;
}

// ---- Start and stop -------------------------------------------------------------------------------------

server.on('error', err => {
  console.error(err.code === 'EADDRINUSE' ? `Port ${PORT} is already in use. Set PORT to another one.` : err);
  process.exit(1);
});

server.listen(PORT, () => {
  const engine = TESTCARD ? 'test card, Oracle is not called' : `Oracle at ${process.env.PLCRAFT_DB_CONNECT_STRING}`;
  console.log(`PL/Craft on http://localhost:${PORT} (${engine})`);
});

// Ctrl+C saves every player before exiting. Press it twice to quit without saving.
async function stop() {
  console.log('Stopping: saving every player first.');
  for (const ws of wss.clients) ws.terminate();
  await Promise.all(live);
  process.exit(0);
}
process.once('SIGINT', stop);
process.once('SIGTERM', stop);
