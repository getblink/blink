// Hero pointillist-reveal harness. Iterates the wave-priority field OFFLINE
// (the browser freezes rAF, so live screenshots can't show motion) by mirroring
// the animation's cover-fit sampling and rendering arrival heatmaps / frames.
//
// The trunk/branch is hard to isolate by colour (it's dark-blue, same family as
// the hills + deep sky), so we HARDCODE its path as a polyline in hero-normalized
// coords and prioritize cells by distance to it. The painting is a fixed asset.
//
// Usage (run from anywhere): node scratchpad/hero-wave/wave.mjs <mode>
//   mode = overlay | heat | frames   (default: overlay)
import { createRequire } from "module";
const require = createRequire(
  "/Users/henryz2004/conductor/workspaces/blink/prague-v1/site/node_modules/",
);
const sharp = require("sharp");
const SRC =
  "/Users/henryz2004/conductor/workspaces/blink/prague-v1/site/public/pointilism-3.webp";
const OUT = "/tmp";
const mode = process.argv[2] || "overlay";

// hero box (override via args: node wave.mjs <mode> <w> <h>) to test aspects
const w = +process.argv[3] || 1200, h = +process.argv[4] || 600;
const gap = Math.max(11, Math.round(Math.sqrt((w * h) / 6000)));

// --- HARDCODED branch polyline in PAINTING-normalized coords (x,y of the
//     source art): right edge -> owl perch -> up into the canopy. Anchored to
//     the art (not the hero box) so it stays aligned at any hero aspect. ---
const BRANCH = [
  [1.0, 0.326], [0.9, 0.332], [0.82, 0.338], [0.76, 0.338],
  [0.7, 0.282], [0.65, 0.213], [0.61, 0.15], [0.58, 0.094],
];

// cover-fit, top-anchored sample (matches the page)
const sw = Math.round(w * 0.25), sh = Math.round(h * 0.25);
const meta = await sharp(SRC).metadata();
const ir = meta.width / meta.height, fr = sw / sh;
let dw, dh;
if (ir > fr) { dh = sh; dw = Math.round(sh * ir); } else { dw = sw; dh = Math.round(sw / ir); }
const leftc = Math.max(0, Math.round((dw - sw) / 2));
// map painting-normalized -> hero px through the same cover-fit
const offX = (sw - dw) / 2;
const bpx = BRANCH.map(([pnx, pny]) => [(offX + pnx * dw) * (w / sw), pny * dh * (h / sh)]);
const cover = await sharp(SRC).resize(dw, dh, { fit: "fill" }).raw().toBuffer();
const data = Buffer.alloc(sw * sh * 3);
for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) {
  const sxp = Math.min(dw - 1, leftc + x), syp = Math.min(dh - 1, y);
  const si = (syp * dw + sxp) * 3, di = (y * sw + x) * 3;
  data[di] = cover[si]; data[di + 1] = cover[si + 1]; data[di + 2] = cover[si + 2];
}
const cl = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

// distance (in hero px) from a point to the branch polyline
function distToBranch(px, py) {
  let best = Infinity;
  for (let k = 0; k < bpx.length - 1; k++) {
    const ax = bpx[k][0], ay = bpx[k][1];
    const bx = bpx[k + 1][0], by = bpx[k + 1][1];
    const dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy || 1;
    let t = ((px - ax) * dx + (py - ay) * dy) / L2;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    const cx = ax + t * dx, cy = ay + t * dy;
    const d = Math.hypot(px - cx, py - cy);
    if (d < best) best = d;
  }
  return best;
}

const xs = []; for (let x = gap / 2; x < w; x += gap) xs.push(x);
const ys = []; for (let y = gap / 2; y < h; y += gap) ys.push(y);
const cols = xs.length, rows = ys.length, N = cols * rows;
const cell = new Array(N);
for (let ry = 0; ry < rows; ry++) for (let cx = 0; cx < cols; cx++) {
  const x = xs[cx], y = ys[ry];
  const sx = Math.min(sw - 1, ((x / w) * sw) | 0), sy = Math.min(sh - 1, ((y / h) * sh) | 0);
  const i = (sy * sw + sx) * 3, cr = data[i], cg = data[i + 1], cb = data[i + 2];
  const lum = 0.299 * cr + 0.587 * cg + 0.114 * cb;
  const cool = cl((cb - cr) / 85);
  const canopy = cl((Math.min(cg, cb) - cr) / 95) * cl((lum - 80) / 80);
  const warm = cl((cr - cb) / 80), bright = cl((lum - 150) / 105);
  // trunk priority from the hardcoded polyline: 1 on the branch, decaying out
  const dB = distToBranch(x, y);
  const trunk = cl(1 - dB / (gap * 4)); // within ~4 cells of the branch
  cell[ry * cols + cx] = { x, y, cr, cg, cb, cool, canopy, warm, bright, trunk };
}

// branch seed = the owl perch point, mapped through the cover-fit
const seedX = bpx[3][0], seedY = bpx[3][1];
const diag = Math.hypot(w, h);
const cornerX = w * 0.06, cornerY = h * 0.08; // warm sunset corner = last
let vx = cornerX - seedX, vy = cornerY - seedY; const vl = Math.hypot(vx, vy) || 1; vx /= vl; vy /= vl;

const nrm = (a) => { let mn = Infinity, mx = -Infinity; for (const v of a) { if (v < mn) mn = v; if (v > mx) mx = v; } const s = mx - mn || 1; return a.map((v) => (v - mn) / s); };

// FIELD: trunk leads; otherwise an even-ish radial spread (so no corner is
// starved) with the warm sunset corner trailing. Tunable weights.
const TREE_W = 0.8, RADIAL_W = 0.5, PROJ_W = 0.22, COLOUR_W = 0.3;
const field = nrm(cell.map((c) => {
  const radial = Math.hypot(c.x - seedX, c.y - seedY) / diag;
  const proj = Math.max(0, ((c.x - seedX) * vx + (c.y - seedY) * vy) / diag);
  const colour = c.warm * 0.55 + c.bright * 0.3 - c.cool * 0.12;
  const tree = cl(c.trunk * 1.0 + c.canopy * 0.4);
  return radial * RADIAL_W + proj * PROJ_W + colour * COLOUR_W - tree * TREE_W;
}));

const hg = (gap / 2) | 0;
function paintCell(buf, c, col) {
  const x0 = Math.max(0, (c.x - hg) | 0), x1 = Math.min(w, (c.x + hg + 1) | 0);
  const y0 = Math.max(0, (c.y - hg) | 0), y1 = Math.min(h, (c.y + hg + 1) | 0);
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const j = (y * w + x) * 3; buf[j] = col[0]; buf[j + 1] = col[1]; buf[j + 2] = col[2]; }
}
function drawBranch(buf) {
  for (let k = 0; k < BRANCH.length - 1; k++) {
    const ax = BRANCH[k][0] * w, ay = BRANCH[k][1] * h, bx = BRANCH[k + 1][0] * w, by = BRANCH[k + 1][1] * h;
    const steps = Math.ceil(Math.hypot(bx - ax, by - ay));
    for (let s = 0; s <= steps; s++) { const px = Math.round(ax + (bx - ax) * s / steps), py = Math.round(ay + (by - ay) * s / steps);
      for (let oy = -2; oy <= 2; oy++) for (let ox = -2; ox <= 2; ox++) { const xx = px + ox, yy = py + oy; if (xx >= 0 && xx < w && yy >= 0 && yy < h) { const j = (yy * w + xx) * 3; buf[j] = 255; buf[j + 1] = 40; buf[j + 2] = 40; } } }
  }
}
function ramp(t) { const s = [[20, 60, 180], [30, 150, 200], [40, 190, 120], [220, 170, 40], [220, 60, 40]]; const f = t * (s.length - 1), i = Math.min(s.length - 2, f | 0), k = f - i; return s[i].map((c, j) => Math.round(c + (s[i + 1][j] - c) * k)); }

if (mode === "overlay") {
  const buf = Buffer.alloc(w * h * 3);
  for (const c of cell) paintCell(buf, c, [c.cr, c.cg, c.cb]);
  drawBranch(buf);
  await sharp(buf, { raw: { width: w, height: h, channels: 3 } }).png().toFile(`${OUT}/hw_overlay.png`);
  console.log("overlay -> /tmp/hw_overlay.png (red = hardcoded branch polyline)");
} else if (mode === "heat") {
  const buf = Buffer.alloc(w * h * 3);
  for (let i = 0; i < N; i++) paintCell(buf, cell[i], ramp(field[i]));
  await sharp(buf, { raw: { width: w, height: h, channels: 3 } }).png().toFile(`${OUT}/hw_heat.png`);
  console.log("heat -> /tmp/hw_heat.png (blue first ... red last)");
} else if (mode === "frames") {
  const cream = [242, 240, 233], taus = [0.08, 0.22, 0.38, 0.58, 0.82];
  const FW = 470, FH = 235, G = 6, comps = [];
  for (let k = 0; k < taus.length; k++) {
    const buf = Buffer.alloc(w * h * 3);
    for (let i = 0; i < N; i++) paintCell(buf, cell[i], field[i] <= taus[k] ? [cell[i].cr, cell[i].cg, cell[i].cb] : cream);
    comps.push({ input: await sharp(buf, { raw: { width: w, height: h, channels: 3 } }).resize(FW, FH).png().toBuffer(), top: G, left: G + k * (FW + G) });
  }
  await sharp({ create: { width: taus.length * (FW + G) + G, height: FH + 2 * G, channels: 3, background: { r: 28, g: 30, b: 36 } } }).composite(comps).png().toFile(`${OUT}/hw_frames.png`);
  console.log("frames -> /tmp/hw_frames.png  t =", taus.join(", "));
}
