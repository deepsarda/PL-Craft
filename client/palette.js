// Materials (Section 5.2) and the 256-entry palette (Section 9.4). Index = material × 16 + 4 × fog band + face.

export const MATERIALS = [
  { name: 'Air' },
  { name: 'Bedrock', rgb: [60, 60, 60] },
  { name: 'Stone', rgb: [125, 125, 125] },
  { name: 'Dirt', rgb: [134, 96, 67] },
  { name: 'Grass', rgb: [95, 159, 53] },
  { name: 'Sand', rgb: [219, 207, 163] },
  { name: 'Water', rgb: [48, 96, 200] },
  { name: 'Log', rgb: [102, 81, 51] },
  { name: 'Leaves', rgb: [60, 120, 40] },
  { name: 'Planks', rgb: [162, 130, 78] },
  { name: 'Cobblestone', rgb: [110, 110, 110] },
  { name: 'Brick', rgb: [150, 74, 58] },
  { name: 'Snow', rgb: [240, 245, 250] },
];

// Keys 1–9 then 0 (Section 12.4). These are also the only materials a player may place.
export const HOTBAR = [2, 3, 4, 5, 7, 8, 9, 10, 11, 12];

const SKY = [[110, 160, 230], [130, 175, 235], [155, 195, 240], [185, 215, 245]]; // top of sky to horizon
const FOG = SKY[3];
const SHADE = [1, 0.8, 0.65, 0.5]; // top, x-wall, z-wall, underside
const FOG_AMOUNT = [0, 0.3, 0.6, 0.88]; // by fog band

const rgba32 = ([r, g, b]) => (0xff000000 | (b << 16) | (g << 8) | r) >>> 0; // ImageData bytes are R, G, B, A

// Indices nothing should paint (unused sky slots, materials 13–15, unpainted pixels) show as magenta,
// so a renderer bug is a loud colour instead of a plausible one.
export const MISSING = rgba32([255, 0, 255]);

export function shade(rgb, face, band) {
  const a = FOG_AMOUNT[band];
  return rgb.map((v, i) => Math.min(255, Math.max(0, Math.round((1 - a) * v * SHADE[face] + a * FOG[i]))));
}

export function buildPalette() {
  const pal = new Uint32Array(256).fill(MISSING);
  SKY.forEach((rgb, i) => { pal[i] = rgba32(rgb); });
  for (let m = 1; m < MATERIALS.length; m++) {
    for (let band = 0; band < 4; band++) {
      for (let face = 0; face < 4; face++) pal[m * 16 + band * 4 + face] = rgba32(shade(MATERIALS[m].rgb, face, band));
    }
  }
  return pal;
}

// Heat-map frames (flag bit 2) carry cells walked per column instead of colours: blue for few, red for many.
export function buildHeatmap() {
  return Uint32Array.from({ length: 256 }, (_, i) => {
    const k = n => (n + (240 * (1 - i / 255)) / 30) % 12;
    const f = n => Math.round(255 * (0.5 - 0.5 * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1))));
    return rgba32([f(0), f(8), f(4)]);
  });
}
