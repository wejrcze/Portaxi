// Portaxi media generator: city emblems and a few UI textures as 64x64 TGA files (card J, wave 3).
//
// Usage (from anywhere, Node 18+, no packages):
//   node tools/make-emblems.mjs
//
// Reads the six city emblem SVGs (OG, UC, TB, SW, IF, DN) from the EMB object in docs/mock/portaxi.html
// and writes Portaxi/Media/emblem_<KEY>.tga. It also writes three procedural textures used by the UI:
//   ring.tga   white anti-aliased ring, tinted in game (emblem border)
//   glow.tga   white soft disc, tinted in game (glow behind the selected emblem)
//   portal.tga the arcane portal disc of the mock's minimap button
// Every file: 64x64, 32-bit BGRA with alpha, uncompressed true-colour (TGA image type 2), bottom-left origin
// (descriptor 0x08), no image ID, no footer: 18 + 64 * 64 * 4 = 16402 bytes. Output is deterministic.
//
// The rasterizer implements only the SVG subset the emblems use: rect (incl. rx/ry), circle, ellipse, line,
// polygon, polyline, path (M L H V C S Q T A Z, absolute and relative), g with fill / stroke / opacity /
// transform (translate, rotate, scale, matrix), fill / fill-opacity / stroke / stroke-width / stroke-opacity /
// opacity, nonzero fill rule. Strokes use round joins and caps. Anti-aliasing: 4x4 supersampling.
// Emblems are clipped to a circle, as the mock shows them (border-radius: 50%).

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MOCK = join(ROOT, "docs", "mock", "portaxi.html");
const OUT = join(ROOT, "Portaxi", "Media");
const KEYS = ["OG", "UC", "TB", "SW", "IF", "DN"];
const SIZE = 64; // output pixels per side
const SS = 4; // supersampling per axis
const N = SIZE * SS; // samples per side

// ---------------------------------------------------------------------------------------------
// Reading the mock

function readEmblems(html) {
  const start = html.indexOf("const EMB={");
  if (start < 0) throw new Error("EMB object not found in " + MOCK);
  const end = html.indexOf("};", start);
  const block = html.slice(start, end);
  const out = {};
  for (const m of block.matchAll(/\b([A-Z]{2,3}):`([^`]*)`/g)) out[m[1]] = m[2];
  for (const key of KEYS) if (!out[key]) throw new Error("emblem " + key + " not found");
  return out;
}

// ---------------------------------------------------------------------------------------------
// Tiny XML reader (enough for the mock's inline SVG)

function parseXml(text) {
  const root = { name: "#root", attrs: {}, children: [] };
  const stack = [root];
  const tag = /<(\/?)([a-zA-Z][\w:-]*)([^>]*?)(\/?)>/g;
  for (const m of text.matchAll(tag)) {
    const [, closing, name, rawAttrs, selfClosing] = m;
    if (closing) {
      if (stack.length > 1) stack.pop();
      continue;
    }
    const attrs = {};
    for (const a of rawAttrs.matchAll(/([\w:-]+)\s*=\s*"([^"]*)"/g)) attrs[a[1]] = a[2];
    const node = { name, attrs, children: [] };
    stack[stack.length - 1].children.push(node);
    if (!selfClosing) stack.push(node);
  }
  return root;
}

// ---------------------------------------------------------------------------------------------
// Colours and numbers

const NAMED = { black: "#000000", white: "#ffffff", red: "#ff0000", green: "#008000", blue: "#0000ff" };

function parseColor(value) {
  if (value == null || value === "none" || value === "transparent") return null;
  let v = NAMED[value] || value;
  if (/^#[0-9a-f]{3}$/i.test(v)) v = "#" + v[1] + v[1] + v[2] + v[2] + v[3] + v[3];
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(v);
  if (!m) throw new Error("unsupported colour " + value);
  return [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255];
}

const num = (v, d = 0) => (v == null || v === "" ? d : parseFloat(v));

// ---------------------------------------------------------------------------------------------
// Affine matrices [a, b, c, d, e, f]: x' = a x + c y + e, y' = b x + d y + f

const IDENTITY = [1, 0, 0, 1, 0, 0];

function mul(m, n) {
  return [
    m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5],
  ];
}

function apply(m, x, y) {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

function parseTransform(text) {
  let m = IDENTITY;
  if (!text) return m;
  for (const t of text.matchAll(/(\w+)\s*\(([^)]*)\)/g)) {
    const a = (t[2].match(/[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/gi) || []).map(Number);
    let n;
    switch (t[1]) {
      case "translate": n = [1, 0, 0, 1, a[0] || 0, a[1] || 0]; break;
      case "scale": n = [a[0], 0, 0, a.length > 1 ? a[1] : a[0], 0, 0]; break;
      case "matrix": n = a.slice(0, 6); break;
      case "rotate": {
        const r = (a[0] * Math.PI) / 180, cos = Math.cos(r), sin = Math.sin(r);
        const cx = a[1] || 0, cy = a[2] || 0;
        n = mul(mul([1, 0, 0, 1, cx, cy], [cos, sin, -sin, cos, 0, 0]), [1, 0, 0, 1, -cx, -cy]);
        break;
      }
      default: throw new Error("unsupported transform " + t[1]);
    }
    m = mul(m, n);
  }
  return m;
}

// ---------------------------------------------------------------------------------------------
// Geometry: every shape becomes a list of subpaths { pts: [[x, y], ...], closed } in user units

function segmentsFor(length) {
  return Math.max(8, Math.min(96, Math.ceil(length * 2)));
}

function ellipsePath(cx, cy, rx, ry) {
  const n = segmentsFor(2 * Math.PI * Math.max(rx, ry));
  const pts = [];
  for (let i = 0; i < n; i++) {
    const t = (i / n) * 2 * Math.PI;
    pts.push([cx + rx * Math.cos(t), cy + ry * Math.sin(t)]);
  }
  return [{ pts, closed: true }];
}

function rectPath(a) {
  const x = num(a.x), y = num(a.y), w = num(a.width), h = num(a.height);
  let rx = a.rx != null ? num(a.rx) : a.ry != null ? num(a.ry) : 0;
  let ry = a.ry != null ? num(a.ry) : rx;
  rx = Math.min(rx, w / 2);
  ry = Math.min(ry, h / 2);
  if (rx <= 0 || ry <= 0) return [{ pts: [[x, y], [x + w, y], [x + w, y + h], [x, y + h]], closed: true }];
  const pts = [];
  const corner = (cx, cy, from) => {
    const n = segmentsFor((Math.PI / 2) * Math.max(rx, ry) * 2);
    for (let i = 0; i <= n; i++) {
      const t = from + (i / n) * (Math.PI / 2);
      pts.push([cx + rx * Math.cos(t), cy + ry * Math.sin(t)]);
    }
  };
  corner(x + w - rx, y + ry, -Math.PI / 2);
  corner(x + w - rx, y + h - ry, 0);
  corner(x + rx, y + h - ry, Math.PI / 2);
  corner(x + rx, y + ry, Math.PI);
  return [{ pts, closed: true }];
}

function pointsPath(text, closed) {
  const v = (text.match(/[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/gi) || []).map(Number);
  const pts = [];
  for (let i = 0; i + 1 < v.length; i += 2) pts.push([v[i], v[i + 1]]);
  return [{ pts, closed }];
}

// Path data reader: a cursor over the string, so packed arc flags ("0 01 5 5") parse correctly.
function pathPath(d) {
  let i = 0;
  const skip = () => { while (i < d.length && /[\s,]/.test(d[i])) i++; };
  const number = () => {
    skip();
    const m = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/.exec(d.slice(i));
    if (!m) throw new Error("bad path number at " + i + " in " + d);
    i += m[0].length;
    return parseFloat(m[0]);
  };
  const flag = () => { skip(); const f = d[i++]; if (f !== "0" && f !== "1") throw new Error("bad arc flag"); return f === "1"; };

  const subpaths = [];
  let cur = null, x = 0, y = 0, sx = 0, sy = 0, lastCtrl = null;
  const lineTo = (nx, ny) => { cur.pts.push([nx, ny]); x = nx; y = ny; };
  const moveTo = (nx, ny) => {
    cur = { pts: [[nx, ny]], closed: false };
    subpaths.push(cur);
    x = sx = nx; y = sy = ny;
  };
  const cubic = (x1, y1, x2, y2, x3, y3) => {
    const len = Math.hypot(x1 - x, y1 - y) + Math.hypot(x2 - x1, y2 - y1) + Math.hypot(x3 - x2, y3 - y2);
    const n = segmentsFor(len), x0 = x, y0 = y;
    for (let k = 1; k <= n; k++) {
      const t = k / n, u = 1 - t;
      cur.pts.push([
        u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
        u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3,
      ]);
    }
    x = x3; y = y3;
  };
  const quad = (x1, y1, x2, y2) => {
    const len = Math.hypot(x1 - x, y1 - y) + Math.hypot(x2 - x1, y2 - y1);
    const n = segmentsFor(len), x0 = x, y0 = y;
    for (let k = 1; k <= n; k++) {
      const t = k / n, u = 1 - t;
      cur.pts.push([u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2]);
    }
    x = x2; y = y2;
  };
  // Endpoint to centre parametrisation (SVG 1.1 implementation notes, F.6.5).
  const arc = (rx, ry, rot, large, sweep, x2, y2) => {
    if (x === x2 && y === y2) return;
    rx = Math.abs(rx); ry = Math.abs(ry);
    if (rx === 0 || ry === 0) return lineTo(x2, y2);
    const phi = (rot * Math.PI) / 180, cos = Math.cos(phi), sin = Math.sin(phi);
    const dx = (x - x2) / 2, dy = (y - y2) / 2;
    const x1p = cos * dx + sin * dy, y1p = -sin * dx + cos * dy;
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) { rx *= Math.sqrt(lambda); ry *= Math.sqrt(lambda); }
    const num2 = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    let coef = Math.sqrt(Math.max(0, num2 / den));
    if (large === sweep) coef = -coef;
    const cxp = (coef * rx * y1p) / ry, cyp = (-coef * ry * x1p) / rx;
    const cx = cos * cxp - sin * cyp + (x + x2) / 2, cy = sin * cxp + cos * cyp + (y + y2) / 2;
    const ang = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    const t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    let dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && dt > 0) dt -= 2 * Math.PI;
    if (sweep && dt < 0) dt += 2 * Math.PI;
    const n = segmentsFor(Math.abs(dt) * Math.max(rx, ry));
    for (let k = 1; k <= n; k++) {
      const t = t1 + (dt * k) / n;
      const ex = rx * Math.cos(t), ey = ry * Math.sin(t);
      cur.pts.push([cos * ex - sin * ey + cx, sin * ex + cos * ey + cy]);
    }
    x = x2; y = y2;
  };

  let cmd = "";
  while (true) {
    skip();
    if (i >= d.length) break;
    if (/[a-zA-Z]/.test(d[i])) {
      cmd = d[i++];
    } else if (!cmd) {
      throw new Error("path data must start with a command: " + d);
    }
    const rel = cmd === cmd.toLowerCase();
    const C = cmd.toUpperCase();
    const ox = rel ? x : 0, oy = rel ? y : 0;
    if (C !== "Z" && !cur && C !== "M") moveTo(x, y);
    switch (C) {
      case "M": {
        moveTo(ox + number(), oy + number());
        cmd = rel ? "l" : "L"; // further pairs are implicit line-tos
        lastCtrl = null;
        break;
      }
      case "L": lineTo(ox + number(), oy + number()); lastCtrl = null; break;
      case "H": lineTo(ox + number(), y); lastCtrl = null; break;
      case "V": lineTo(x, oy + number()); lastCtrl = null; break;
      case "C": {
        const x1 = ox + number(), y1 = oy + number(), x2 = ox + number(), y2 = oy + number();
        const x3 = ox + number(), y3 = oy + number();
        cubic(x1, y1, x2, y2, x3, y3);
        lastCtrl = ["C", x2, y2];
        break;
      }
      case "S": {
        const r = lastCtrl && lastCtrl[0] === "C" ? [2 * x - lastCtrl[1], 2 * y - lastCtrl[2]] : [x, y];
        const x2 = ox + number(), y2 = oy + number(), x3 = ox + number(), y3 = oy + number();
        cubic(r[0], r[1], x2, y2, x3, y3);
        lastCtrl = ["C", x2, y2];
        break;
      }
      case "Q": {
        const x1 = ox + number(), y1 = oy + number(), x2 = ox + number(), y2 = oy + number();
        quad(x1, y1, x2, y2);
        lastCtrl = ["Q", x1, y1];
        break;
      }
      case "T": {
        const r = lastCtrl && lastCtrl[0] === "Q" ? [2 * x - lastCtrl[1], 2 * y - lastCtrl[2]] : [x, y];
        quad(r[0], r[1], ox + number(), oy + number());
        lastCtrl = ["Q", r[0], r[1]];
        break;
      }
      case "A": {
        const rx = number(), ry = number(), rot = number(), large = flag(), sweep = flag();
        arc(rx, ry, rot, large, sweep, ox + number(), oy + number());
        lastCtrl = null;
        break;
      }
      case "Z": {
        if (cur) {
          cur.closed = true;
          x = sx; y = sy;
          cur = null;
        }
        lastCtrl = null;
        break;
      }
      default: throw new Error("unsupported path command " + cmd);
    }
  }
  return subpaths.filter((s) => s.pts.length > 1);
}

function geometry(node) {
  const a = node.attrs;
  switch (node.name) {
    case "rect": return rectPath(a);
    case "circle": return ellipsePath(num(a.cx), num(a.cy), num(a.r), num(a.r));
    case "ellipse": return ellipsePath(num(a.cx), num(a.cy), num(a.rx), num(a.ry));
    case "line": return [{ pts: [[num(a.x1), num(a.y1)], [num(a.x2), num(a.y2)]], closed: false }];
    case "polygon": return pointsPath(a.points || "", true);
    case "polyline": return pointsPath(a.points || "", false);
    case "path": return pathPath(a.d || "");
    default: return null;
  }
}

// ---------------------------------------------------------------------------------------------
// Rasterising: masks of N x N samples (1 = covered), composited into premultiplied RGBA layers

function newLayer() {
  return new Float64Array(N * N * 4);
}

// Nonzero fill of polygons given in sample space (each point already multiplied by the sample scale).
function fillMask(polys) {
  const mask = new Uint8Array(N * N);
  const edges = [];
  let minY = Infinity, maxY = -Infinity;
  for (const pts of polys) {
    for (let k = 0; k < pts.length; k++) {
      const [x0, y0] = pts[k], [x1, y1] = pts[(k + 1) % pts.length];
      if (y0 === y1) continue;
      edges.push([x0, y0, x1, y1, y1 > y0 ? 1 : -1]);
      minY = Math.min(minY, y0, y1);
      maxY = Math.max(maxY, y0, y1);
    }
  }
  const rowFrom = Math.max(0, Math.floor(minY - 0.5)), rowTo = Math.min(N - 1, Math.ceil(maxY));
  for (let row = rowFrom; row <= rowTo; row++) {
    const sy = row + 0.5;
    const xs = [];
    for (const [x0, y0, x1, y1, dir] of edges) {
      const lo = Math.min(y0, y1), hi = Math.max(y0, y1);
      if (sy < lo || sy >= hi) continue;
      xs.push([x0 + ((sy - y0) * (x1 - x0)) / (y1 - y0), dir]);
    }
    if (xs.length < 2) continue;
    xs.sort((p, q) => p[0] - q[0]);
    let winding = 0;
    for (let k = 0; k < xs.length - 1; k++) {
      winding += xs[k][1];
      if (winding === 0) continue;
      const from = Math.max(0, Math.ceil(xs[k][0] - 0.5)), to = Math.min(N - 1, Math.floor(xs[k + 1][0] - 0.5));
      for (let col = from; col <= to; col++) mask[row * N + col] = 1;
    }
  }
  return mask;
}

// Stroke as the union of capsules around every segment (round joins and caps), half width hw in samples.
function strokeMask(lines, hw) {
  const mask = new Uint8Array(N * N);
  const hw2 = hw * hw;
  for (const pts of lines) {
    for (let k = 0; k + 1 < pts.length; k++) {
      const [x0, y0] = pts[k], [x1, y1] = pts[k + 1];
      const dx = x1 - x0, dy = y1 - y0, len2 = dx * dx + dy * dy;
      const c0 = Math.max(0, Math.floor(Math.min(x0, x1) - hw)), c1 = Math.min(N - 1, Math.ceil(Math.max(x0, x1) + hw));
      const r0 = Math.max(0, Math.floor(Math.min(y0, y1) - hw)), r1 = Math.min(N - 1, Math.ceil(Math.max(y0, y1) + hw));
      for (let row = r0; row <= r1; row++) {
        for (let col = c0; col <= c1; col++) {
          const px = col + 0.5, py = row + 0.5;
          let t = len2 > 0 ? ((px - x0) * dx + (py - y0) * dy) / len2 : 0;
          t = Math.max(0, Math.min(1, t));
          const ex = x0 + t * dx - px, ey = y0 + t * dy - py;
          if (ex * ex + ey * ey <= hw2) mask[row * N + col] = 1;
        }
      }
    }
  }
  return mask;
}

function paint(layer, mask, rgb, alpha) {
  if (alpha <= 0) return;
  for (let s = 0; s < N * N; s++) {
    if (!mask[s]) continue;
    const o = s * 4, keep = 1 - alpha;
    layer[o] = rgb[0] * alpha + layer[o] * keep;
    layer[o + 1] = rgb[1] * alpha + layer[o + 1] * keep;
    layer[o + 2] = rgb[2] * alpha + layer[o + 2] * keep;
    layer[o + 3] = alpha + layer[o + 3] * keep;
  }
}

// Source-over of a premultiplied layer with an extra opacity.
function composite(dst, src, opacity) {
  for (let o = 0; o < dst.length; o += 4) {
    const a = src[o + 3] * opacity;
    if (a <= 0) continue;
    const keep = 1 - a;
    dst[o] = src[o] * opacity + dst[o] * keep;
    dst[o + 1] = src[o + 1] * opacity + dst[o + 1] * keep;
    dst[o + 2] = src[o + 2] * opacity + dst[o + 2] * keep;
    dst[o + 3] = a + dst[o + 3] * keep;
  }
}

// Draws node and its children into layer. style: inherited presentation attributes.
function draw(node, layer, matrix, style, scale) {
  const a = node.attrs;
  const own = { ...style };
  for (const k of ["fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity"]) if (a[k] != null) own[k] = a[k];
  const m = mul(matrix, parseTransform(a.transform));
  const opacity = num(a.opacity, 1);

  if (node.name === "g" || node.name === "svg" || node.name === "#root") {
    if (opacity >= 1) {
      for (const child of node.children) draw(child, layer, m, own, scale);
    } else {
      const sub = newLayer();
      for (const child of node.children) draw(child, sub, m, own, scale);
      composite(layer, sub, opacity);
    }
    return;
  }
  const geo = geometry(node);
  if (!geo) return; // unknown or non-graphic element (title, defs...): ignored
  const toSamples = (pts) => pts.map(([x, y]) => {
    const [tx, ty] = apply(m, x, y);
    return [tx * scale * SS, ty * scale * SS];
  });
  const fill = parseColor(own.fill === undefined ? "#000000" : own.fill);
  if (fill && node.name !== "line" && node.name !== "polyline") {
    paint(layer, fillMask(geo.map((s) => toSamples(s.pts))), fill, opacity * num(own["fill-opacity"], 1));
  }
  const stroke = parseColor(own.stroke);
  const width = num(own["stroke-width"], 1);
  if (stroke && width > 0) {
    const lines = geo.map((s) => toSamples(s.closed ? s.pts.concat([s.pts[0]]) : s.pts));
    const det = Math.sqrt(Math.abs(m[0] * m[3] - m[1] * m[2]));
    paint(layer, strokeMask(lines, (width * det * scale * SS) / 2), stroke, opacity * num(own["stroke-opacity"], 1));
  }
}

function renderSvg(svgText) {
  const tree = parseXml(svgText);
  const svg = tree.children.find((c) => c.name === "svg");
  if (!svg) throw new Error("no <svg> element");
  const vb = (svg.attrs.viewBox || "0 0 64 64").split(/[\s,]+/).map(Number);
  const scale = SIZE / vb[2];
  const layer = newLayer();
  draw(svg, layer, [1, 0, 0, 1, -vb[0], -vb[1]], {}, scale);
  return layer;
}

// Keeps only the samples inside the circle that fills the image (the mock's round emblem).
function clipCircle(layer) {
  const r = N / 2;
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const dx = col + 0.5 - r, dy = row + 0.5 - r;
      if (dx * dx + dy * dy > r * r) layer.fill(0, (row * N + col) * 4, (row * N + col) * 4 + 4);
    }
  }
  return layer;
}

// Procedural layer: fn(x, y) -> [r, g, b, a] (straight alpha) at a sample centre, x/y in output pixels.
function proceduralLayer(fn) {
  const layer = newLayer();
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const [r, g, b, al] = fn((col + 0.5) / SS, (row + 0.5) / SS);
      const o = (row * N + col) * 4;
      layer[o] = r * al; layer[o + 1] = g * al; layer[o + 2] = b * al; layer[o + 3] = al;
    }
  }
  return layer;
}

// ---------------------------------------------------------------------------------------------
// Down-sampling and TGA output

const to8 = (v) => Math.max(0, Math.min(255, Math.round(v * 255)));

// Averages SS x SS samples per pixel; returns straight-alpha RGBA bytes, top row first.
function downsample(layer) {
  const px = new Uint8Array(SIZE * SIZE * 4);
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const o = ((y * SS + sy) * N + (x * SS + sx)) * 4;
          r += layer[o]; g += layer[o + 1]; b += layer[o + 2]; a += layer[o + 3];
        }
      }
      const o = (y * SIZE + x) * 4, k = SS * SS;
      if (a > 0) {
        px[o] = to8(r / a); px[o + 1] = to8(g / a); px[o + 2] = to8(b / a);
      }
      px[o + 3] = to8(a / k);
    }
  }
  return bleed(px);
}

// Gives fully transparent pixels the colour of their visible neighbours, so bilinear filtering in game
// does not pull dark fringes into the anti-aliased edge.
function bleed(px) {
  for (let pass = 0; pass < 2; pass++) {
    const src = px.slice();
    for (let y = 0; y < SIZE; y++) {
      for (let x = 0; x < SIZE; x++) {
        const o = (y * SIZE + x) * 4;
        if (src[o + 3] > 0 || (src[o] | src[o + 1] | src[o + 2]) > 0) continue;
        let r = 0, g = 0, b = 0, n = 0;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            const nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= SIZE || ny >= SIZE) continue;
            const q = (ny * SIZE + nx) * 4;
            if (src[q + 3] === 0 && (src[q] | src[q + 1] | src[q + 2]) === 0) continue;
            r += src[q]; g += src[q + 1]; b += src[q + 2]; n++;
          }
        }
        if (n) { px[o] = Math.round(r / n); px[o + 1] = Math.round(g / n); px[o + 2] = Math.round(b / n); }
      }
    }
  }
  return px;
}

function tga(px) {
  const out = Buffer.alloc(18 + SIZE * SIZE * 4);
  out[2] = 2; // uncompressed true-colour
  out.writeUInt16LE(SIZE, 12);
  out.writeUInt16LE(SIZE, 14);
  out[16] = 32; // bits per pixel
  out[17] = 0x08; // 8 alpha bits, bottom-left origin
  let p = 18;
  for (let y = SIZE - 1; y >= 0; y--) {
    for (let x = 0; x < SIZE; x++) {
      const o = (y * SIZE + x) * 4;
      out[p++] = px[o + 2]; out[p++] = px[o + 1]; out[p++] = px[o]; out[p++] = px[o + 3];
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Procedural textures

const C = SIZE / 2;
const dist = (x, y) => Math.hypot(x - C, y - C);

// Ring: the outer 3 px of the disc (scaled with the emblem in game).
const ring = (x, y) => {
  const d = dist(x, y);
  return [1, 1, 1, d <= C && d >= C - 3 ? 1 : 0];
};

// Glow: soft white disc, strongest in the middle.
const glow = (x, y) => {
  const t = Math.max(0, 1 - dist(x, y) / C);
  return [1, 1, 1, t * t];
};

// Portal disc of the mock's minimap button: radial-gradient(circle, #d8f6ff 0, #3fc7eb 32%, #1b4a8a 62%,
// #0c1830 72%); CSS sizes it to the farthest corner, so the percentages are of C * sqrt(2).
const PORTAL_STOPS = [[0, "#d8f6ff"], [0.32, "#3fc7eb"], [0.62, "#1b4a8a"], [0.72, "#0c1830"]]
  .map(([t, c]) => [t * C * Math.SQRT2, parseColor(c)]);
const portal = (x, y) => {
  const d = dist(x, y);
  if (d > C) return [0, 0, 0, 0];
  let k = 0;
  while (k < PORTAL_STOPS.length - 1 && d > PORTAL_STOPS[k + 1][0]) k++;
  const [d0, c0] = PORTAL_STOPS[k], [d1, c1] = PORTAL_STOPS[Math.min(k + 1, PORTAL_STOPS.length - 1)];
  const t = d1 > d0 ? Math.max(0, Math.min(1, (d - d0) / (d1 - d0))) : 0;
  return [c0[0] + (c1[0] - c0[0]) * t, c0[1] + (c1[1] - c0[1]) * t, c0[2] + (c1[2] - c0[2]) * t, 1];
};

// ---------------------------------------------------------------------------------------------
// Main

function write(name, layer) {
  const file = join(OUT, name + ".tga");
  writeFileSync(file, tga(downsample(layer)));
  console.log("wrote " + file);
}

const emblems = readEmblems(readFileSync(MOCK, "utf8"));
mkdirSync(OUT, { recursive: true });
for (const key of KEYS) write("emblem_" + key, clipCircle(renderSvg(emblems[key])));
write("ring", proceduralLayer(ring));
write("glow", proceduralLayer(glow));
write("portal", proceduralLayer(portal));
