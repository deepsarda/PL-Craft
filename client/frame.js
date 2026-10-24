// Frame format v1 (Section 9.1). Every number is big-endian and unsigned, which is DataView's default.
// Shared by the browser, the Node relay and the tests, so the layout lives in one place.

export const HEADER_BYTES = 52;
export const MAGIC = 0x5043; // "PC"
export const VERSION = 1;
export const FLAG_TARGET = 1;
export const FLAG_EDITED = 2;
export const FLAG_HEATMAP = 4;
export const NO_FACE = 255;

export function readHeader(dv) {
  return {
    magic: dv.getUint16(0),
    version: dv.getUint8(2),
    flags: dv.getUint8(3),
    seq: dv.getUint32(4),
    width: dv.getUint16(8),
    height: dv.getUint16(10),
    renderUs: dv.getUint32(12),
    physUs: dv.getUint16(16),
    editUs: dv.getUint16(18),
    packUs: dv.getUint16(20),
    px: dv.getUint32(24) / 1000,
    py: dv.getUint32(28) / 1000,
    pz: dv.getUint32(32) / 1000,
    yaw: dv.getUint16(36) / 1e4,
    pitch: (dv.getUint16(38) - 32768) / 1e4,
    held: dv.getUint8(40),
    targetFace: dv.getUint8(41),
    targetX: dv.getUint16(42),
    targetY: dv.getUint16(44),
    targetZ: dv.getUint16(46),
    runTotal: dv.getUint32(48),
  };
}

// The inverse of readHeader. Real frames are packed by pc_frame; this one serves the test card and tests.
export function writeHeader(dv, h) {
  dv.setUint16(0, MAGIC);
  dv.setUint8(2, VERSION);
  dv.setUint8(3, h.flags);
  dv.setUint32(4, h.seq);
  dv.setUint16(8, h.width);
  dv.setUint16(10, h.height);
  dv.setUint32(12, h.renderUs);
  dv.setUint16(16, h.physUs);
  dv.setUint16(18, h.editUs);
  dv.setUint16(20, h.packUs);
  dv.setUint16(22, 0);
  dv.setUint32(24, Math.round(h.px * 1000));
  dv.setUint32(28, Math.round(h.py * 1000));
  dv.setUint32(32, Math.round(h.pz * 1000));
  dv.setUint16(36, Math.round(h.yaw * 1e4));
  dv.setUint16(38, Math.round(h.pitch * 1e4) + 32768);
  dv.setUint8(40, h.held);
  dv.setUint8(41, h.targetFace);
  dv.setUint16(42, h.targetX);
  dv.setUint16(44, h.targetY);
  dv.setUint16(46, h.targetZ);
  dv.setUint32(48, h.runTotal);
}

// Paints every run of the body into pix (width × height, row-major) and returns how many runs it read.
export function decodeRuns(dv, width, pix, pal32) {
  let o = HEADER_BYTES;
  let runs = 0;
  for (let c = 0; c < width; c++) {
    const n = dv.getUint16(o);
    o += 2;
    runs += n;
    for (let k = 0; k < n; k++, o += 5) {
      const colour = pal32[dv.getUint8(o + 4)];
      const end = (dv.getUint16(o) + dv.getUint16(o + 2)) * width + c;
      for (let i = dv.getUint16(o) * width + c; i < end; i += width) pix[i] = colour;
    }
  }
  return runs;
}
