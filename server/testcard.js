// Stand-in for pc_engine while the PL/SQL does not exist yet (`npm run testcard`). It answers every input
// with a valid v1 frame of sky, flat grass and four compass pillars, and only does mouse look, so the relay
// and client can be built and checked end to end. Delete it once pc_engine.tick returns real frames.
import { HEADER_BYTES, FLAG_TARGET, NO_FACE, writeHeader } from '../client/frame.js';

const W = 640;
const H = 360;
const F = 320; // focal length for a 90° FOV, so P = tan 45° = 1 (Section 7.1)
const EYE = 1.62;
const FEET = { x: 64.5, y: 24, z: 64.5 }; // standing on grass whose top is at y = 24
const SENS = 0.0025;
const PITCH_LIMIT = (55 * Math.PI) / 180; // PITCH_LIMIT_DEG
const REACH = 5;
const FAR = 48;
const PILLAR_DEPTH = 20;
const PILLAR_TOP = 4; // blocks above the ground
const PILLAR_HALF = Math.atan(0.5 / PILLAR_DEPTH);
const PILLARS = [[0, 2], [Math.PI / 2, 11], [Math.PI, 7], [-Math.PI / 2, 12]]; // [bearing, material]: E stone, S brick, W log, N snow
const GRASS = 4;
const TAU = 2 * Math.PI;
const NO_WORLDS = 'The test card has no worlds. Start the server with npm start to use the database.';

const fogBand = t => Math.max(0, Math.min(3, Math.floor((t - 24) / 8) + 1)); // Section 8.7

// Palette index for every row of one screen column: material × 16 + 4 × band + face.
function paintColumn(col, bearing, h) {
  const pillar = PILLARS.find(([b]) => Math.abs(Math.atan2(Math.sin(bearing - b), Math.cos(bearing - b))) < PILLAR_HALF);
  const top = h - (F * (PILLAR_TOP - EYE)) / PILLAR_DEPTH;
  const foot = h + (F * EYE) / PILLAR_DEPTH;
  for (let r = 0; r < H; r++) {
    const y = r + 0.5;
    const depth = y > h ? (F * EYE) / (y - h) : Infinity; // of the ground seen at this row
    if (pillar && y >= top && y < foot) col[r] = pillar[1] * 16 + 1; // x-wall, fog band 0
    else if (depth <= FAR) col[r] = GRASS * 16 + 4 * fogBand(depth); // top face
    else col[r] = y < h - 120 ? 0 : y < h - 60 ? 1 : y < h - 20 ? 2 : 3; // sky, lighter toward the horizon
  }
}

export async function openTestCard() {
  let yaw = 0;
  let pitch = 0;
  const col = new Uint8Array(H);
  const buf = Buffer.alloc(HEADER_BYTES + W * 2 + W * H * 5); // room for the 1.15 MB worst case

  return {
    width: W,
    height: H,
    fov: 90,
    testcard: true,
    async tick(input) {
      const start = performance.now();
      yaw = (((yaw + input.mdx * SENS) % TAU) + TAU) % TAU;
      pitch = Math.max(-PITCH_LIMIT, Math.min(PITCH_LIMIT, pitch - input.mdy * SENS));
      const h = H / 2 + F * Math.tan(pitch);

      let o = HEADER_BYTES;
      let runTotal = 0;
      for (let c = 0; c < W; c++) {
        paintColumn(col, yaw + Math.atan((2 * (c + 0.5)) / W - 1), h);
        const countAt = o;
        o += 2;
        let n = 0;
        for (let r = 0; r < H; n++) {
          let end = r + 1;
          while (end < H && col[end] === col[r]) end++;
          buf.writeUInt16BE(r, o);
          buf.writeUInt16BE(end - r, o + 2);
          buf.writeUInt8(col[r], o + 4);
          o += 5;
          r = end;
        }
        buf.writeUInt16BE(n, countAt);
        runTotal += n;
      }

      // The crosshair hits the ground within reach once you look down far enough (Section 7.5).
      const down = -Math.sin(pitch);
      const dist = down > 0 ? EYE / down : Infinity;
      const hit = dist <= REACH;
      writeHeader(new DataView(buf.buffer, buf.byteOffset, HEADER_BYTES), {
        flags: hit ? FLAG_TARGET : 0,
        seq: input.seq,
        width: W,
        height: H,
        renderUs: Math.round((performance.now() - start) * 1000),
        physUs: 0,
        editUs: 0,
        packUs: 0,
        px: FEET.x,
        py: FEET.y,
        pz: FEET.z,
        yaw,
        pitch,
        held: input.held,
        targetFace: hit ? 3 : NO_FACE,
        targetX: hit ? Math.floor(FEET.x + Math.cos(yaw) * Math.cos(pitch) * dist) : 0,
        targetY: hit ? FEET.y - 1 : 0,
        targetZ: hit ? Math.floor(FEET.z + Math.sin(yaw) * Math.cos(pitch) * dist) : 0,
        runTotal,
      });
      return Buffer.from(buf.subarray(0, o)); // a copy, because the next tick reuses buf
    },
    async save() {},
    async worlds() {
      throw new Error(NO_WORLDS);
    },
    async newWorld() {
      throw new Error(NO_WORLDS);
    },
    async join() {
      throw new Error(NO_WORLDS);
    },
    lost: () => false,
    async shutdown() {},
  };
}
