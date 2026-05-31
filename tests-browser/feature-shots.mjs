// Cropped per-feature screenshots for a release changelog.
//
// Drives the running app and saves one tight PNG per highlighted feature.
// Each shot reloads first (clean overlay state), drives the feature into view,
// then crops to the relevant element so the shot shows just that feature.
//
//   node feature-shots.mjs                 # -> ../changes/<VER>/*.png
//   BASE=http://127.0.0.1:5099 VER=v0.3.0 node feature-shots.mjs
import { launchBrowser } from "./lib.mjs";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const BASE = process.env.BASE || "http://127.0.0.1:5099";
const VER = process.env.VER || "v0.3.0";
const here = fileURLToPath(new URL(".", import.meta.url));
const OUTDIR = join(here, "..", "changes", VER);
mkdirSync(OUTDIR, { recursive: true });

const browser = await launchBrowser();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
const page = await ctx.newPage();

async function load() {
  await page.goto(BASE, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".topbar", { timeout: 12000 });
  await page.waitForTimeout(1200); // let SSE projection paint panes
}

async function cropTo(selector, out) {
  const el = await page.waitForSelector(selector, { state: "visible", timeout: 8000 });
  await el.scrollIntoViewIfNeeded().catch(() => {});
  const path = join(OUTDIR, out);
  // Element screenshot auto-scrolls and crops to the element's exact box, so it
  // works even when the element sits below the fold.
  await el.screenshot({ path });
  const box = await el.boundingBox();
  console.log(`shot ${out} (${box ? Math.round(box.width) + "x" + Math.round(box.height) : "?"})`);
}

// Focus a clip so its pane renders at full opacity. The app dims every pane in
// navigate mode (.3) and lights only the focused/active one in focus mode.
async function focusClip(cid) {
  await page.evaluate((id) => window.__focusClip && window.__focusClip(id), cid);
}

const shots = [];

// 1. One top bar -- the merged bar with New + Actions handles.
shots.push(async () => {
  await load();
  await cropTo(".topbar", "topbar.png", { pad: 6 });
});

// 2. Theme picker -- open from the top bar.
shots.push(async () => {
  await load();
  await page.click('.bar-btn[title="Theme"]');
  await page.waitForTimeout(300);
  await cropTo(".theme-panel", "theme.png", { pad: 10 });
});

// 3. New-clip dropdown.
shots.push(async () => {
  await load();
  await page.click(".bar-btn-primary");
  await page.waitForTimeout(300);
  await cropTo(".picker-panel", "newclip.png", { pad: 10 });
});

// 4. Clip-actions panel (Cmd-K).
shots.push(async () => {
  await load();
  await page.evaluate(() => window.app.openActions());
  await page.waitForTimeout(300);
  await cropTo(".actions-panel", "actions.png", { pad: 10 });
});

// 5. Scrollable (niri) stack layout.
shots.push(async () => {
  await load();
  const before = await page.evaluate(() => document.querySelector("#doc")?.classList.contains("layout-niri"));
  if (!before) {
    await page.evaluate(() => window.app.toggleLayout());
    await page.waitForSelector("#doc.layout-niri", { timeout: 6000 }).catch(() => {});
    await page.waitForTimeout(800);
  }
  // Focus a pane so the strip isn't dimmed; prefer a terminal (a focused note
  // flips to its raw editor).
  const stripCid = await page.evaluate(() => {
    const panes = [...document.querySelectorAll("#doc .pane[data-clip]")];
    const term = panes.find((p) => p.querySelector("[id^='grid-'] *"));
    return (term || panes[0])?.getAttribute("data-clip") || null;
  });
  if (stripCid) { await focusClip(stripCid); await page.waitForTimeout(500); }
  await cropTo("#doc", "layout-niri.png");
  // leave the stack as we found it
  if (!before) {
    await page.evaluate(() => window.app.toggleLayout());
    await page.waitForTimeout(400);
  }
});

// 6. Live terminal pane (server-rendered grid + HUD).
shots.push(async () => {
  await load();
  const cid = await page.evaluate(() => {
    const panes = [...document.querySelectorAll(".pane[data-clip]")];
    const term = panes.find((p) => p.querySelector("[id^='grid-'] *"));
    return term ? term.getAttribute("data-clip") : null;
  });
  if (!cid) { console.log("skip terminal.png (no terminal pane in focused stack)"); return; }
  await focusClip(cid); // light the pane (otherwise dimmed at .3 opacity)
  await page.waitForTimeout(700);
  await cropTo(`.pane[data-clip="${cid}"]`, "terminal.png");
});

for (const s of shots) {
  try { await s(); } catch (e) { console.log("FAILED " + e.message); }
}

await browser.close();
console.log("done -> " + OUTDIR);
