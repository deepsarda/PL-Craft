// Messages from the browser (Sections 10.1 and 12.2). Everything here comes off the network, so it is
// checked against the documented ranges before any of it is bound into a PL/SQL call.
import { HOTBAR } from '../client/palette.js';

const PLACEABLE = new Set(HOTBAR);
const MAX_ID = 2 ** 31 - 1;
const MAX_MOUSE = 100_000; // pixels between two messages; far beyond any real hand
const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

export function parseHello(msg) {
  if (msg?.type !== 'hello' || !isInt(msg.world_id, 1, MAX_ID) || !isInt(msg.player_id, 1, MAX_ID)) return null;
  return { worldId: msg.world_id, playerId: msg.player_id, debugHeatmap: msg.debug_heatmap === true };
}

export function parseInput(msg) {
  const ok =
    isInt(msg?.seq, 1, MAX_ID) && // p_seq is a PLS_INTEGER
    isInt(msg.keys, 0, 127) &&
    isInt(msg.mdx, -MAX_MOUSE, MAX_MOUSE) &&
    isInt(msg.mdy, -MAX_MOUSE, MAX_MOUSE) &&
    isInt(msg.lclick, 0, 1) &&
    isInt(msg.rclick, 0, 1) &&
    PLACEABLE.has(msg.held);
  if (!ok) return null;
  const { seq, keys, mdx, mdy, lclick, rclick, held } = msg;
  return { seq, keys, mdx, mdy, lclick, rclick, held };
}

// Commands from the page's menu: list the worlds, make a new one, or move to one.
export function parseCommand(msg) {
  switch (msg?.type) {
    case 'worlds':
      return { type: 'worlds' };
    case 'new_world':
      return isInt(msg.seed, 1, 2147483646) && (msg.phase === 1 || msg.phase === 2)
        ? { type: 'new_world', seed: msg.seed, phase: msg.phase }
        : null;
    case 'join':
      return isInt(msg.world_id, 1, MAX_ID) ? { type: 'join', worldId: msg.world_id } : null;
    default:
      return null;
  }
}

// An input that arrives while a tick is running: keep the latest keys, held block and seq,
// add up mouse movement, and keep any click that happened in either.
export function mergeInput(older, newer) {
  return {
    seq: newer.seq,
    keys: newer.keys,
    held: newer.held,
    mdx: older.mdx + newer.mdx,
    mdy: older.mdy + newer.mdy,
    lclick: older.lclick | newer.lclick,
    rclick: older.rclick | newer.rclick,
  };
}
