// Crosshair and target-face outline, drawn into the decoded pixels so they sit on the game's own pixel grid.
// Projection is the renderer's (Section 7.3): y-sheared, square pixels, depth along the camera's forward axis.

const EYE = 1.62;
const NEAR = 0.05;

// Corners of each face, numbered as in Section 11.1 (0 −x, 1 +x, 2 −y, 3 +y, 4 −z, 5 +z), from the block's min corner.
const FACES = [
  [[0, 0, 0], [0, 1, 0], [0, 1, 1], [0, 0, 1]],
  [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]],
  [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
  [[0, 1, 0], [1, 1, 0], [1, 1, 1], [0, 1, 1]],
  [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]],
  [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]],
];

export function camera(hd, fovDeg) {
  const f = hd.width / 2 / Math.tan((fovDeg * Math.PI) / 360);
  return {
    ex: hd.px, ey: hd.py + EYE, ez: hd.pz,
    cos: Math.cos(hd.yaw), sin: Math.sin(hd.yaw),
    f, h: hd.height / 2 + f * Math.tan(hd.pitch), mid: hd.width / 2,
  };
}

// World point → [t, u, v]: depth along forward, distance along right, height above the eye.
function toCamera(cam, [x, y, z]) {
  const dx = x - cam.ex;
  const dz = z - cam.ez;
  return [dx * cam.cos + dz * cam.sin, dz * cam.cos - dx * cam.sin, y - cam.ey];
}

export const toScreen = (cam, [t, u, v]) => [cam.mid + (cam.f * u) / t, cam.h - (cam.f * v) / t];
export const project = (cam, point) => toScreen(cam, toCamera(cam, point));

export function drawCrosshair(pix, width, height) {
  const cx = Math.floor(width / 2);
  const cy = Math.floor(height / 2);
  const invert = i => { pix[i] ^= 0x00ffffff; };
  for (let d = -4; d <= 4; d++) {
    invert(cy * width + cx + d);
    if (d !== 0) invert((cy + d) * width + cx);
  }
}

export function drawTarget(pix, width, height, hd, fovDeg) {
  const corners = FACES[hd.targetFace]?.map(([a, b, c]) => [hd.targetX + a, hd.targetY + b, hd.targetZ + c]);
  if (!corners) return;
  const cam = camera(hd, fovDeg);
  const pts = corners.map(p => toCamera(cam, p));
  for (let k = 0; k < 4; k++) {
    const edge = clipNear(pts[k], pts[(k + 1) % 4]);
    const seg = edge && clipRect(...toScreen(cam, edge[0]), ...toScreen(cam, edge[1]), width, height);
    if (seg) line(pix, width, height, seg);
  }
}

// Cut an edge at the near plane so corners behind the eye still give a usable line.
function clipNear(a, b) {
  if (a[0] < NEAR && b[0] < NEAR) return null;
  const cut = (p, q) => p.map((v, i) => v + ((q[i] - v) * (NEAR - p[0])) / (q[0] - p[0]));
  if (a[0] < NEAR) return [cut(a, b), b];
  if (b[0] < NEAR) return [a, cut(b, a)];
  return [a, b];
}

// Liang–Barsky: clip a screen segment to [0, width) × [0, height) before stepping along it.
function clipRect(x0, y0, x1, y1, width, height) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  let lo = 0;
  let hi = 1;
  const edges = [[-dx, x0], [dx, width - 1e-6 - x0], [-dy, y0], [dy, height - 1e-6 - y0]];
  for (const [p, q] of edges) {
    if (p === 0) {
      if (q < 0) return null;
      continue;
    }
    const r = q / p;
    if (p < 0) lo = Math.max(lo, r);
    else hi = Math.min(hi, r);
    if (lo > hi) return null;
  }
  return [x0 + lo * dx, y0 + lo * dy, x0 + hi * dx, y0 + hi * dy];
}

// Halve each channel along the segment: dark on any material, and still shows what is underneath.
function line(pix, width, height, [x0, y0, x1, y1]) {
  const n = Math.ceil(Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0))) || 1;
  for (let i = 0; i <= n; i++) {
    const x = Math.floor(x0 + ((x1 - x0) * i) / n);
    const y = Math.floor(y0 + ((y1 - y0) * i) / n);
    if (x < 0 || x >= width || y < 0 || y >= height) continue; // float dust at a clipped end
    const p = y * width + x;
    pix[p] = ((pix[p] >>> 1) & 0x7f7f7f7f) | 0xff000000;
  }
}
