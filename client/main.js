// Browser client (Section 12.4). Sends input, draws the frames Oracle sends back, one frame in flight (Section 12.3).
import { TARGET_FPS, RECONNECT_MAX_S, DEBUG_HEATMAP, WORLD_ID, PLAYER_ID } from './config.js';
import { HEADER_BYTES, MAGIC, VERSION, FLAG_TARGET, FLAG_HEATMAP, readHeader, decodeRuns } from './frame.js';
import { MATERIALS, HOTBAR, MISSING, buildPalette, buildHeatmap, shade } from './palette.js';
import { drawCrosshair, drawTarget } from './aim.js';

const query = new URLSearchParams(location.search);
let worldId = Number(query.get('world') ?? WORLD_ID); // changes when the player makes or joins a world
const playerId = Number(query.get('player') ?? PLAYER_ID);
const heatmap = query.has('heatmap') || DEBUG_HEATMAP;
const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;

const $ = id => document.getElementById(id);
const stage = $('stage');
const canvas = $('view');
const ctx = canvas.getContext('2d');
const term = $('term');
const log = $('log');
const menu = $('menu');
const play = $('play');
const hud = $('hud');
const hotbar = $('hotbar');
const heldName = $('held-name');

const palette = buildPalette();
const heatPalette = buildHeatmap();

// ---- Terminal -------------------------------------------------------------------------------------------

const cursor = document.createElement('span');
cursor.className = 'cursor';
cursor.textContent = '█';
cursor.setAttribute('aria-hidden', 'true');

function say(text = '') {
  if (cursor.parentNode === log) cursor.remove();
  const p = document.createElement('p');
  p.textContent = text;
  log.append(p);
  while (log.childElementCount > 100) log.firstElementChild.remove(); // hours of reconnects stay bounded
  settle();
}

function command(text) {
  if (log.querySelector('p')) say(); // a blank line between commands
  say();
  const ps = document.createElement('span');
  ps.className = 'ps';
  ps.textContent = 'SQL>';
  log.lastChild.append(ps, ` ${text}`);
}

// A blinking cursor on the next line while a call is running.
function wait() {
  log.append(cursor);
  settle();
}

// The terminal scrolls like a real one: the oldest lines leave at the top.
function settle() {
  term.scrollTop = term.scrollHeight;
}

function showMenu() {
  menu.hidden = state !== 'ready' || busy;
  if (!menu.hidden) {
    play.after(cursor);
    play.focus({ preventScroll: true });
  }
  settle();
}

const elapsed = ms => {
  const cs = Math.round(ms / 10);
  const two = n => String(n).padStart(2, '0');
  return `${two(Math.floor(cs / 360000))}:${two(Math.floor(cs / 6000) % 60)}:${two(Math.floor(cs / 100) % 60)}.${two(cs % 100)}`;
};

// SQL*Plus-style result sets: headings over dashed rules, numbers right-aligned, text left-aligned.
function resultSet(columns) {
  const cell = ([, width, left], v) => (left ? String(v).padEnd(width) : String(v).padStart(width));
  return {
    head: columns.map(c => cell(c, c[0])).join(' '),
    rule: columns.map(([, width]) => '-'.repeat(width)).join(' '),
    row: values => columns.map((c, i) => cell(c, values[i])).join(' '),
  };
}

function table(set, body) {
  const rule = document.createElement('span');
  rule.className = 'rule';
  rule.textContent = set.rule;
  rule.setAttribute('aria-hidden', 'true');
  return [`${set.head}\n`, rule, '\n', body];
}

const CONTROLS = [
  ['W A S D', 'Move'],
  ['Space', 'Jump'],
  ['Shift', 'Sneak'],
  ['Ctrl', 'Sprint'],
  ['Left click', 'Break block'],
  ['Right click', 'Place block'],
  ['1–0, wheel', 'Choose block'],
  ['F3', 'Show or hide stats'],
];
const CONTROL_SET = resultSet([['KEY', 12, true], ['ACTION', 18, true]]);
$('controls').append(...table(CONTROL_SET, CONTROLS.map(CONTROL_SET.row).join('\n')));
$('row-count').textContent = `${CONTROLS.length} rows selected.`;

const rowsSelected = n => (n ? `${n} row${n === 1 ? '' : 's'} selected.` : 'no rows selected');

// ---- Screen ---------------------------------------------------------------------------------------------

let width = 0;
let height = 0;
let image;
let pix;

function size(w, h) {
  if (w === width && h === height) return;
  width = w;
  height = h;
  canvas.width = w;
  canvas.height = h;
  image = ctx.createImageData(w, h);
  pix = new Uint32Array(image.data.buffer);
  fit();
}

// Scale by a whole number of device pixels so every game pixel is the same size, and centre on a device
// pixel. --ui sizes the type, HUD and hotbar as if the screen were 640 wide, whatever SCREEN_W the database
// renders (Section 14.1 allows 160 to 640), in whole device pixels so the 11px type stays crisp. At 640×360
// one --ui is one game pixel.
function fit() {
  const dpr = devicePixelRatio || 1;
  const scale = Math.max(1, Math.floor(Math.min((innerWidth * dpr) / width, (innerHeight * dpr) / height)));
  const gp = scale / dpr;
  stage.style.width = `${width * gp}px`;
  stage.style.height = `${height * gp}px`;
  stage.style.left = `${Math.round((innerWidth * dpr - width * scale) / 2) / dpr}px`;
  stage.style.top = `${Math.max(0, Math.round((innerHeight * dpr - height * scale) / 2)) / dpr}px`;
  stage.style.setProperty('--ui', `${Math.max(1, Math.floor((scale * width) / 640)) / dpr}px`);
}

addEventListener('resize', fit);

// ---- Hotbar ---------------------------------------------------------------------------------------------

// A 16-pixel isometric cube lit like the world: top face, then an x-wall on the left and a z-wall on the right.
function cube(rgb) {
  const c = document.createElement('canvas');
  c.width = 16;
  c.height = 16;
  c.setAttribute('aria-hidden', 'true');
  const g = c.getContext('2d');
  const img = g.createImageData(16, 16);
  const faces = [0, 1, 2].map(face => shade(rgb, face, 0));
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 16; x++) {
      const cx = x + 0.5;
      const cy = y + 0.5;
      const slope = Math.abs(cx - 8) / 2;
      if (cy < slope || cy > 16 - slope) continue;
      img.data.set([...faces[cy < 8 - slope ? 0 : cx < 8 ? 1 : 2], 255], (y * 16 + x) * 4);
    }
  }
  g.putImageData(img, 0, 0);
  return c;
}

let slot = 0;
const slots = HOTBAR.map(id => {
  const li = document.createElement('li');
  li.setAttribute('aria-label', MATERIALS[id].name);
  li.append(cube(MATERIALS[id].rgb));
  hotbar.append(li);
  return li;
});
slots[slot].setAttribute('aria-current', 'true');

function select(i) {
  slots[slot].removeAttribute('aria-current');
  slot = (i + HOTBAR.length) % HOTBAR.length;
  slots[slot].setAttribute('aria-current', 'true');
  heldName.textContent = MATERIALS[HOTBAR[slot]].name;
  for (const animation of heldName.getAnimations()) animation.cancel();
  heldName.animate([{ opacity: 1 }, { opacity: 1, offset: 0.6 }, { opacity: 0 }], { duration: 1800 });
}

// ---- Input (Section 10.1) -------------------------------------------------------------------------------

const KEY_BITS = { KeyW: 1, KeyS: 2, KeyA: 4, KeyD: 8, Space: 16, ShiftLeft: 32, ShiftRight: 32, ControlLeft: 64, ControlRight: 64 };
const down = new Set();
let mdx = 0;
let mdy = 0;
let lclick = 0;
let rclick = 0;

const locked = () => document.pointerLockElement === canvas;
const keyBits = () => [...down].reduce((bits, code) => bits | KEY_BITS[code], 0);

addEventListener('keydown', e => {
  if (e.code === 'F3') {
    e.preventDefault();
    hud.hidden = !hud.hidden;
    return;
  }
  if (!locked()) return;
  const digit = /^Digit(\d)$/.exec(e.code);
  if (digit) select((Number(digit[1]) + 9) % 10);
  else if (Object.hasOwn(KEY_BITS, e.code)) down.add(e.code);
  else return;
  e.preventDefault(); // keeps Ctrl+D, Ctrl+S and the like away from the browser while sprinting
});
addEventListener('keyup', e => down.delete(e.code));
addEventListener('blur', () => down.clear());

addEventListener('mousemove', e => {
  if (!locked()) return;
  mdx += e.movementX;
  mdy += e.movementY;
});
addEventListener('mousedown', e => {
  if (!locked()) return;
  if (e.button === 0) lclick = 1;
  if (e.button === 2) rclick = 1;
});
addEventListener('contextmenu', e => {
  if (locked()) e.preventDefault();
});
addEventListener('wheel', e => {
  if (!locked() || e.deltaY === 0) return;
  e.preventDefault();
  select(slot + Math.sign(e.deltaY));
}, { passive: false });

// Ctrl is sprint, and Ctrl+W closes the tab in most browsers: ask before leaving mid-game.
addEventListener('beforeunload', e => {
  if (locked()) e.preventDefault();
});

stage.addEventListener('click', e => {
  if (busy || e.target.closest('input, .command, .world-row')) return; // those have their own jobs
  if (state === 'ready' && !locked()) canvas.requestPointerLock()?.catch?.(() => {}); // failures arrive as pointerlockerror
});
document.addEventListener('pointerlockerror', () => say('ERROR: The browser did not capture the mouse. Click again in a moment.'));
document.addEventListener('pointerlockchange', () => {
  down.clear();
  mdx = 0;
  mdy = 0;
  const playing = locked();
  stage.classList.toggle('playing', playing);
  term.hidden = playing;
  if (!playing) showMenu();
});

// ---- Connection (Section 12.2) --------------------------------------------------------------------------

let ws = null;
let state = 'closed';
let busy = false; // a menu command is asking questions or waiting on the server
let commandAt = 0;
let attempt = 0;
let helloAt = 0;
let fov = 90;

function connect() {
  state = 'connecting';
  command(`connect ${wsUrl}`);
  wait();
  const sock = new WebSocket(wsUrl);
  sock.binaryType = 'arraybuffer';
  ws = sock;
  let opened = false;

  sock.onopen = () => {
    opened = true;
    state = 'opening';
    say('Connected.');
    command(`exec pc_engine.init_session(p_world_id => ${worldId}, p_player_id => ${playerId}${heatmap ? ', p_debug_heatmap => true' : ''})`);
    wait();
    helloAt = performance.now();
    sock.send(JSON.stringify({ type: 'hello', world_id: worldId, player_id: playerId, debug_heatmap: heatmap }));
  };

  // Binary messages are frames, text messages are JSON control messages.
  sock.onmessage = e => (typeof e.data === 'string' ? onControl(JSON.parse(e.data)) : onFrame(e.data));

  sock.onclose = () => {
    const wasReady = state === 'ready';
    state = 'closed';
    inflight = 0;
    menu.hidden = true;
    if (locked()) document.exitPointerLock();
    if (!opened) say('ERROR: Nothing is answering. Start the server with npm start.');
    else if (wasReady) say('ERROR: Lost the connection to the server.');
    const delay = Math.min(2 ** attempt++, RECONNECT_MAX_S);
    say(`Retrying in ${delay} s.`);
    setTimeout(connect, delay * 1000);
  };
}

function onControl(msg) {
  if (msg.type === 'ready') {
    state = 'ready';
    busy = false;
    attempt = 0;
    fov = msg.fov ?? 90;
    wantFirstFrame = true;
    size(msg.width, msg.height);
    if (msg.testcard) {
      say('Test card: the server runs with --testcard and does not call Oracle.');
      say('You can look around. Moving and editing blocks need pc_engine.');
    } else {
      say('PL/SQL procedure successfully completed.');
    }
    say(`Elapsed: ${elapsed(performance.now() - helloAt)}`);
    showMenu();
  } else if (msg.type === 'worlds') {
    showWorlds(msg.worlds, msg.current);
  } else if (msg.type === 'joined') {
    say('PL/SQL procedure successfully completed.');
    say(`Elapsed: ${elapsed(performance.now() - commandAt)}`);
    say(`You are in world ${msg.world_id}.`);
    worldId = msg.world_id;
    query.set('world', String(worldId)); // a reload comes back to this world
    history.replaceState(null, '', `?${query}`);
    wantFirstFrame = true;
    busy = false;
    showMenu();
  } else if (msg.type === 'error') {
    say(`ERROR: ${msg.message}`);
    inflight = 0;
    listing = null;
    if (busy) {
      busy = false;
      showMenu();
    }
    if (locked()) document.exitPointerLock();
  }
}

// ---- Worlds: the menu's New world and Switch world -------------------------------------------------------

const TERRAIN = ['flat', 'hills', 'hills, arches']; // by generation phase; 0 is the flat world of the old stub
const WORLD_SET = resultSet([['WORLD_ID', 8], ['SEED', 10], ['TERRAIN', 13, true], ['CREATED', 16, true], ['CURRENT', 7, true]]);
let listing = null; // the world rows while the list is open

// One SQL*Plus-style ACCEPT: the label and an inline input. Resolves to the answer, the default for a bare
// Enter, or null for Escape.
function ask(label, fallback) {
  say();
  const input = document.createElement('input');
  input.className = 'ask';
  input.autocomplete = 'off';
  input.spellcheck = false;
  input.setAttribute('aria-label', `${label}, default ${fallback}`);
  log.lastChild.append(`${label} [${fallback}]: `, input);
  settle();
  input.focus({ preventScroll: true });
  return new Promise(resolve => {
    input.addEventListener('keydown', e => {
      if (e.key !== 'Enter' && e.key !== 'Escape') return;
      const answer = e.key === 'Enter' ? input.value.trim() || String(fallback) : null;
      input.replaceWith(answer ?? '');
      resolve(answer);
    });
  });
}

function stopAsking() {
  busy = false;
  showMenu();
}

// Shows the command in the transcript and sends its message; the reply arrives in onControl.
function run(text, msg) {
  if (ws?.readyState !== WebSocket.OPEN) {
    say('ERROR: Not connected to the server.');
    return stopAsking();
  }
  command(text);
  wait();
  commandAt = performance.now();
  ws.send(JSON.stringify(msg));
}

async function newWorld() {
  if (state !== 'ready' || busy) return;
  busy = true;
  showMenu();
  say(); // set the questions apart from the output above, as a command would be
  const fallback = 1 + Math.floor(Math.random() * 2147483646);
  let seed;
  while (seed === undefined) {
    const answer = await ask('Seed', fallback);
    if (answer === null) return stopAsking();
    if (/^\d+$/.test(answer) && Number(answer) >= 1 && Number(answer) <= 2147483646) seed = Number(answer);
    else say('ERROR: A seed is a whole number from 1 to 2147483646.');
  }
  let phase;
  while (phase === undefined) {
    const answer = await ask('Arches and overhangs, y or n', 'y');
    if (answer === null) return stopAsking();
    if (/^y(es)?$/i.test(answer)) phase = 2;
    else if (/^no?$/i.test(answer)) phase = 1;
    else say('ERROR: Answer y or n.');
  }
  run(`exec :world := pc_world.new_world(p_seed => ${seed}, p_phase => ${phase})`, { type: 'new_world', seed, phase });
}

function switchWorld() {
  if (state !== 'ready' || busy) return;
  busy = true;
  showMenu();
  run('select world_id, seed, terrain, created from pc_worlds;', { type: 'worlds' });
}

// The worlds as a result set whose rows are buttons: choosing one moves the player there. Escape leaves it.
function showWorlds(worlds, current) {
  say();
  say(WORLD_SET.head);
  say(WORLD_SET.rule);
  log.lastChild.className = 'rule';
  log.lastChild.setAttribute('aria-hidden', 'true');
  listing = worlds.map(w => {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'world-row';
    row.textContent = WORLD_SET.row([w.world_id, w.seed, TERRAIN[w.phase] ?? '', w.created ?? '', w.world_id === current ? 'yes' : '']);
    if (w.world_id === current) row.setAttribute('aria-current', 'true');
    row.addEventListener('click', () => {
      closeWorlds();
      run(`exec pc_engine.init_session(p_world_id => ${w.world_id}, p_player_id => ${playerId})`, { type: 'join', world_id: w.world_id });
    });
    say();
    log.lastChild.append(row);
    return row;
  });
  say();
  say(rowsSelected(worlds.length));
  if (!listing.length) return stopAsking();
  (listing.find(r => r.hasAttribute('aria-current')) ?? listing[0]).focus({ preventScroll: true });
  settle();
}

function closeWorlds() {
  listing?.forEach(row => { row.disabled = true; });
  listing = null;
}

$('new-world').addEventListener('click', newWorld);
$('switch-world').addEventListener('click', switchWorld);
addEventListener('keydown', e => {
  if (e.key === 'Escape' && listing) {
    closeWorlds();
    stopAsking();
  }
});

// ---- Frames and lockstep (Sections 9.3 and 12.3) --------------------------------------------------------

const SEND_EVERY_MS = 1000 / TARGET_FPS;
let seq = 0;
let inflight = 0; // seq of the input we are waiting on, 0 when none
let sentAt = 0;
let nextSendAt = 0;
let wantFirstFrame = false; // fetch one frame after connecting, so the world shows behind the terminal
let shown = false;
let pending = null;
let last = null;
const stats = { frames: 0, answered: 0, rtt: 0, renderUs: 0, packUs: 0, runs: 0 };

function onFrame(buf) {
  const dv = new DataView(buf);
  const hd = buf.byteLength >= HEADER_BYTES ? readHeader(dv) : null;
  if (hd?.magic !== MAGIC || hd.version !== VERSION) {
    say(`ERROR: The server sent a frame this page cannot read (format ${hd?.version}, expected ${VERSION}). Reload the page.`);
    ws.close();
    return;
  }
  if (hd.seq === inflight) {
    inflight = 0;
    stats.answered += 1;
    stats.rtt += performance.now() - sentAt;
  }
  pending = { dv, hd };
}

function send(now) {
  const dx = Math.trunc(mdx); // carry fractional movement into the next message
  const dy = Math.trunc(mdy);
  mdx -= dx;
  mdy -= dy;
  seq += 1;
  ws.send(JSON.stringify({ seq, keys: keyBits(), mdx: dx, mdy: dy, lclick, rclick, held: HOTBAR[slot] }));
  lclick = 0;
  rclick = 0;
  inflight = seq;
  sentAt = now;
  // Keep a 41.7 ms cadence rather than waiting 41.7 ms after each send: on a 60 Hz display the second
  // would land every third animation frame, 20 fps. After a stall, start a fresh cadence instead of bursting.
  nextSendAt = Math.max(nextSendAt + SEND_EVERY_MS, now + SEND_EVERY_MS / 2);
  wantFirstFrame = false;
}

function draw({ dv, hd }) {
  size(hd.width, hd.height);
  pix.fill(MISSING); // rows the renderer forgot show magenta instead of last frame's pixels
  let runs;
  try {
    runs = decodeRuns(dv, width, pix, hd.flags & FLAG_HEATMAP ? heatPalette : palette);
  } catch (err) {
    console.error(`Frame ${hd.seq} ends early`, err);
    return;
  }
  if (runs !== hd.runTotal) console.warn(`Frame ${hd.seq}: header says ${hd.runTotal} runs, body holds ${runs}.`);
  if (hd.flags & FLAG_TARGET) drawTarget(pix, width, height, hd, fov);
  drawCrosshair(pix, width, height);
  ctx.putImageData(image, 0, 0);
  if (!shown) {
    shown = true;
    canvas.classList.add('shown');
  }
  last = hd;
  stats.frames += 1;
  stats.renderUs += hd.renderUs;
  stats.packUs += hd.packUs;
  stats.runs += hd.runTotal;
}

// ---- HUD ------------------------------------------------------------------------------------------------

const FACE = ['-x', '+x', '-y', '+y', '-z', '+z'];
const PERF = resultSet([['FPS', 5], ['RTT_MS', 6], ['RENDER_MS', 9], ['PACK_MS', 7], ['RUNS', 6]]);
const POSE = resultSet([['X', 6], ['Y', 6], ['Z', 6], ['YAW', 4], ['PITCH', 5], ['TARGET', 13, true]]);
const perfRow = document.createTextNode('');
const poseRow = document.createTextNode('');
hud.append(...table(PERF, perfRow), '\n\n', ...table(POSE, poseRow));
let hudAt = 0;

function updateHud(now) {
  const n = stats.frames;
  if (n && last) {
    const ms = us => (us / n / 1000).toFixed(1);
    const rtt = stats.answered ? (stats.rtt / stats.answered).toFixed(1) : '';
    perfRow.data = PERF.row([((n * 1000) / (now - hudAt)).toFixed(1), rtt, ms(stats.renderUs), ms(stats.packUs), Math.round(stats.runs / n)]);
    const deg = rad => Math.round((rad * 180) / Math.PI);
    const target = last.flags & FLAG_TARGET ? `${last.targetX} ${last.targetY} ${last.targetZ} ${FACE[last.targetFace] ?? '?'}` : '';
    poseRow.data = POSE.row([last.px.toFixed(2), last.py.toFixed(2), last.pz.toFixed(2), deg(last.yaw), deg(last.pitch), target]);
  }
  hudAt = now;
  Object.keys(stats).forEach(k => { stats[k] = 0; });
}

// ---- Main loop ------------------------------------------------------------------------------------------

function loop(now) {
  requestAnimationFrame(loop);
  if (pending) {
    draw(pending);
    pending = null;
  }
  if (state === 'ready' && !inflight && now >= nextSendAt && (locked() || wantFirstFrame)) send(now);
  if (now - hudAt >= 250) updateHud(now);
}

size(640, 360);
if (!matchMedia('(any-pointer: fine)').matches) say('PL/Craft needs a keyboard and a mouse.');
connect();
requestAnimationFrame(loop);
