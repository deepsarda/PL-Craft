import test from 'node:test';
import assert from 'node:assert/strict';
import { HEADER_BYTES, readHeader, writeHeader, decodeRuns } from './frame.js';
import { MATERIALS, buildPalette, shade } from './palette.js';
import { camera, project, drawTarget } from './aim.js';

test('T-F1: the example column from Section 9.1 decodes to the right pixels', () => {
  const column = [0x00, 0x03, 0x00, 0x00, 0x00, 0xb4, 0x00, 0x00, 0xb4, 0x00, 0x28, 0x45, 0x00, 0xdc, 0x00, 0x8c, 0x42];
  const bytes = new Uint8Array(HEADER_BYTES + column.length);
  bytes.set(column, HEADER_BYTES);
  const identity = Uint32Array.from({ length: 256 }, (_, i) => i); // pixel value = palette index
  const pix = new Uint32Array(360);
  assert.equal(decodeRuns(new DataView(bytes.buffer), 1, pix, identity), 3);
  assert.deepEqual([pix[0], pix[179], pix[180], pix[219], pix[220], pix[359]], [0, 0, 69, 69, 66, 66]);
});

test('header fields survive a write and a read, including the offset pitch', () => {
  const h = {
    flags: 1, seq: 1834, width: 640, height: 360, renderUs: 18250, physUs: 310, editUs: 0, packUs: 4100,
    px: 64.5, py: 24, pz: 64.5, yaw: 1.5708, pitch: -0.2, held: 2,
    targetFace: 3, targetX: 66, targetY: 23, targetZ: 65, runTotal: 14820,
  };
  const dv = new DataView(new ArrayBuffer(HEADER_BYTES));
  writeHeader(dv, h);
  assert.equal(dv.getUint16(38), 30768); // the Section 9.1 example for pitch −0.2
  assert.deepEqual(readHeader(dv), { magic: 0x5043, version: 1, ...h });
});

test('T-F2: the header bytes that db/tests/frame.sql checks pc_frame against', () => {
  const dv = new DataView(new ArrayBuffer(HEADER_BYTES));
  writeHeader(dv, {
    flags: 1, seq: 1834, width: 640, height: 360, renderUs: 18250, physUs: 310, editUs: 0, packUs: 0,
    px: 64.5, py: 24, pz: 64.5, yaw: 1.5708, pitch: -0.2, held: 2,
    targetFace: 3, targetX: 66, targetY: 23, targetZ: 65, runTotal: 1920,
  });
  assert.equal(
    Buffer.from(dv.buffer).toString('hex').toUpperCase(),
    '504301010000072A028001680000474A01360000' + '0000' + '00000000FBF400005DC00000FBF43D5C7830020300420017004100000780',
  );
});

test('palette index 69 is the Section 9.4 worked example', () => {
  assert.deepEqual(shade(MATERIALS[4].rgb, 1, 1), [109, 154, 103]);
  assert.equal(buildPalette()[69], (0xff000000 | (103 << 16) | (154 << 8) | 109) >>> 0);
});

test('a point along the crosshair ray projects to the screen centre (Section 7.5)', () => {
  const hd = { width: 640, height: 360, px: 40.2, py: 30, pz: 71.9, yaw: 2.1, pitch: -0.4 };
  const cam = camera(hd, 90);
  const look = [Math.cos(hd.yaw) * Math.cos(hd.pitch), Math.sin(hd.pitch), Math.sin(hd.yaw) * Math.cos(hd.pitch)];
  const [x, y] = project(cam, [hd.px + look[0] * 3, hd.py + 1.62 + look[1] * 3, hd.pz + look[2] * 3]);
  assert.ok(Math.abs(x - 320) < 1e-9 && Math.abs(y - 180) < 1e-9, `got ${x}, ${y}`);
});

test('the target outline draws for a face ahead and for a wall with a corner behind the eye', () => {
  const darkened = hd => {
    const pix = new Uint32Array(640 * 360).fill(0xffffffff);
    drawTarget(pix, 640, 360, { width: 640, height: 360, px: 64.5, py: 24, pz: 64.5, yaw: 0, ...hd }, 90);
    return pix.filter(p => p !== 0xffffffff).length;
  };
  assert.ok(darkened({ pitch: -Math.PI / 6, targetFace: 3, targetX: 67, targetY: 23, targetZ: 64 }) > 50); // Section 11.1
  // West face of the next block east, seen while turned south: corner (65, 64) sits at depth −0.29.
  assert.equal(darkened({ yaw: 1.2, pitch: 0, targetFace: 0, targetX: 65, targetY: 25, targetZ: 64 }), 360);
});
