// Portaxi project logo for CurseForge: a "P" monogram in taxi yellow whose counter is an arcane portal,
// with a taxi checker band on the stem.
//
// Usage (Node 18+, no packages; needs Microsoft Edge or Google Chrome for the PNG):
//   node tools/make-logo.mjs
//
// Writes docs/curseforge/logo.svg (the vector source) and renders docs/curseforge/logo.png (400x400) with a
// headless browser. Edit the geometry and colours below, not the SVG.

import { writeFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT_DIR = join(ROOT, "docs", "curseforge");
const SIZE = 400;
const f = (n) => n.toFixed(1);

// ---------------------------------------------------------------------------------------------
// Geometry (400x400 canvas)

// P: stem x 100..160, bowl 60..270 with outer radius 105, stroke 46 around the counter.
const P_OUTER =
  "M110,60 H205 A105,105 0 0 1 205,270 H160 V340 Q160,350 150,350 H110 Q100,350 100,340 V70 Q100,60 110,60 Z";
const COUNTER = "M160,106 H205 A59,59 0 0 1 205,224 H160 Z";
// Taxi checker band on the stem: 3 x 2 squares of 16 px, inset 6 px so the stem outline stays whole.
const CHECK = 16;
const CHECKS = [[106, 288], [138, 288], [122, 304]];
const PORTAL_C = [208, 165];

// One tapered spiral arm of the portal swirl.
function arm(phi, r0, r1, turns, wmax) {
  const [cx, cy] = PORTAL_C;
  const N = 60, L = [], R = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N;
    const a = phi + t * turns * 2 * Math.PI;
    const r = r0 + (r1 - r0) * Math.pow(t, 0.9);
    const w = wmax * Math.sin(Math.PI * Math.pow(t, 0.7));
    const nx = Math.cos(a), ny = Math.sin(a);
    L.push([cx + nx * (r + w / 2), cy + ny * (r + w / 2)]);
    R.push([cx + nx * Math.max(0, r - w / 2), cy + ny * Math.max(0, r - w / 2)]);
  }
  return "M" + L.concat(R.reverse()).map(([x, y]) => f(x) + "," + f(y)).join(" L") + " Z";
}
const armsMain = [0, 1, 2].map((k) => arm((k * 2 * Math.PI) / 3, 4, 74, 0.62, 13));
const armsFine = [0, 1, 2].map((k) => arm((k * 2 * Math.PI) / 3 + Math.PI / 3, 10, 70, 0.5, 6));

// ---------------------------------------------------------------------------------------------
// SVG

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 400 400">
  <defs>
    <radialGradient id="bg" gradientUnits="userSpaceOnUse" cx="200" cy="185" r="280">
      <stop offset="0" stop-color="#1c2c55"/>
      <stop offset="0.6" stop-color="#111a35"/>
      <stop offset="1" stop-color="#090d1c"/>
    </radialGradient>
    <linearGradient id="gold" gradientUnits="userSpaceOnUse" x1="0" y1="60" x2="0" y2="350">
      <stop offset="0" stop-color="#ffd64a"/>
      <stop offset="0.55" stop-color="#f7b500"/>
      <stop offset="1" stop-color="#e39a00"/>
    </linearGradient>
    <radialGradient id="portal" gradientUnits="userSpaceOnUse" cx="${PORTAL_C[0]}" cy="${PORTAL_C[1]}" r="78">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="0.12" stop-color="#d4f7ff"/>
      <stop offset="0.42" stop-color="#46c6ef"/>
      <stop offset="0.78" stop-color="#3a46c4"/>
      <stop offset="1" stop-color="#22175f"/>
    </radialGradient>
    <clipPath id="counter"><path d="${COUNTER}"/></clipPath>
    <mask id="pmask" maskUnits="userSpaceOnUse" x="0" y="0" width="400" height="400">
      <path d="${P_OUTER} ${COUNTER}" fill="#fff" fill-rule="evenodd"/>
    </mask>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="7" stdDeviation="7" flood-color="#000" flood-opacity="0.5"/>
    </filter>
  </defs>
  <rect width="400" height="400" fill="url(#bg)"/>
  <g transform="translate(-5,-5)">
    <g clip-path="url(#counter)">
      <rect x="150" y="100" width="130" height="130" fill="url(#portal)"/>
      <g fill="#ffffff" fill-opacity="0.55">${armsMain.map((d) => `<path d="${d}"/>`).join("")}</g>
      <g fill="#ffffff" fill-opacity="0.3">${armsFine.map((d) => `<path d="${d}"/>`).join("")}</g>
      <path d="${COUNTER}" fill="none" stroke="#0a0f24" stroke-opacity="0.45" stroke-width="10"/>
    </g>
    <g filter="url(#shadow)">
      <rect width="400" height="400" fill="url(#gold)" mask="url(#pmask)"/>
    </g>
    <g fill="#141a2e">${CHECKS.map(([x, y]) => `<rect x="${x}" y="${y}" width="${CHECK}" height="${CHECK}"/>`).join("")}</g>
  </g>
</svg>
`;

mkdirSync(OUT_DIR, { recursive: true });
const svgFile = join(OUT_DIR, "logo.svg");
writeFileSync(svgFile, svg);
console.log("wrote " + svgFile);

// ---------------------------------------------------------------------------------------------
// PNG via headless Edge / Chrome

const browsers = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
];
const browser = browsers.find((b) => existsSync(b));
if (!browser) {
  console.log("No Edge or Chrome found; PNG not rendered.");
  process.exit(0);
}
const page = join(tmpdir(), "portaxi-logo.html");
writeFileSync(page, `<!doctype html><html><body style="margin:0;background:transparent">${svg}</body></html>`);
const pngFile = join(OUT_DIR, "logo.png");
execFileSync(browser, [
  "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
  `--window-size=${SIZE},${SIZE}`, "--default-background-color=00000000",
  `--screenshot=${pngFile}`, pathToFileURL(page).href,
], { stdio: "ignore" });
rmSync(page, { force: true });
console.log("wrote " + pngFile);
