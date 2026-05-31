// README hero shot: a full-window overview with a clip focused (so the content
// pane renders bright, not the navigate-mode dim). Flow layout, 2x scale.
//
//   BASE=http://127.0.0.1:5099 node readme-shots.mjs
import { launchBrowser } from "./lib.mjs";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const BASE = process.env.BASE || "http://127.0.0.1:5099";
const here = fileURLToPath(new URL(".", import.meta.url));
const OUTDIR = join(here, "..", "docs", "assets");
mkdirSync(OUTDIR, { recursive: true });

const browser = await launchBrowser();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 760 }, deviceScaleFactor: 2 });
const page = await ctx.newPage();
await page.goto(BASE, { waitUntil: "domcontentloaded" });
await page.waitForSelector(".pane", { timeout: 12000 });
await page.waitForTimeout(1500);

// Flow (column) layout for the hero.
const niri = await page.evaluate(() => document.querySelector("#doc")?.classList.contains("layout-niri"));
if (niri) {
  await page.evaluate(() => window.app.toggleLayout());
  await page.waitForTimeout(800);
}

// Focus a rendered-markdown pane if present (bright + readable), else the first.
const cid = await page.evaluate(() => {
  const panes = [...document.querySelectorAll("#doc .pane[data-clip]")];
  const md = panes.find((p) => p.querySelector(".clip-md"));
  return (md || panes[0])?.getAttribute("data-clip") || null;
});
if (cid) { await page.evaluate((id) => window.__focusClip && window.__focusClip(id), cid); }
await page.waitForTimeout(800);

const out = join(OUTDIR, "overview.png");
await page.screenshot({ path: out });
await browser.close();
console.log("shot " + out);
