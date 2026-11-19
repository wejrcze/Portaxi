// Renders the CurseForge description images from docs/curseforge/src/*.html to docs/curseforge/*.png
// with headless Edge or Chrome. Each page sets its own size in :root (--w, --h); the list below must match.
//
// Usage (Node 18+, no packages; needs network for the Google Fonts the pages load):
//   node tools/make-curseforge.mjs
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIR = join(ROOT, "docs", "curseforge");
const PAGES = [
  { name: "banner", w: 1200, h: 420 },
  { name: "ride", w: 1200, h: 380 },
];
const browser = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
].find((b) => existsSync(b));
if (!browser) throw new Error("No Edge or Chrome found.");

for (const { name, w, h } of PAGES) {
  const src = join(DIR, "src", name + ".html");
  if (!existsSync(src)) { console.log("skip " + name + " (no source)"); continue; }
  const out = join(DIR, name + ".png");
  execFileSync(browser, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
    "--allow-file-access-from-files", "--virtual-time-budget=8000",
    `--window-size=${w},${h}`, `--screenshot=${out}`, pathToFileURL(src).href,
  ], { stdio: "ignore" });
  console.log("wrote " + out);
}
