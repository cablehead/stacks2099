// Per-feature screenshots for the release changelog.
//
// Each shot shows the feature IN CONTEXT: a focused terminal (lit, not dimmed)
// with the relevant panel open over the app, captured at the full viewport --
// not a tight crop of the panel alone. The theme shot themes the terminal so
// the palette change is visible next to the open picker.
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
const ctx = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  deviceScaleFactor: 2,
});
const page = await ctx.newPage();

async function load() {
  await page.goto(BASE, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".topbar", { timeout: 12000 });
  await page.waitForTimeout(1200); // let SSE projection paint panes
}

// Focus a terminal pane so it renders lit (navigate mode dims every pane to .3;
// focus mode lights the active one to full opacity) and scrolls into view.
// Returns the focused clip id, or null if the stack has no terminal.
async function focusTerminal() {
  const cid = await page.evaluate(() => {
    const panes = [...document.querySelectorAll(".pane[data-kind='terminal']")];
    const lit = panes.find((p) => p.querySelector("[id^='grid-'] *")) ||
      panes[0];
    return lit?.getAttribute("data-clip") || null;
  });
  if (cid) {
    await page.evaluate(
      (id) => window.__focusClip && window.__focusClip(id),
      cid,
    );
    await page.waitForTimeout(800);
  }
  return cid;
}

// Apply a terminal palette via the top-bar Theme picker (opens, clicks, closes).
async function applyTheme(label) {
  await page.click('.bar-btn[title="Theme"]');
  await page.waitForTimeout(250);
  await page.click(`.theme-panel .picker-row:has-text("${label}")`);
  await page.waitForTimeout(400);
}

async function shotViewport(out) {
  const path = join(OUTDIR, out);
  await page.screenshot({ path }); // viewport, not fullPage
  console.log(`shot ${out}`);
}

async function cropTo(selector, out) {
  const el = await page.waitForSelector(selector, {
    state: "visible",
    timeout: 8000,
  });
  await el.scrollIntoViewIfNeeded().catch(() => {});
  await el.screenshot({ path: join(OUTDIR, out) });
  console.log(`shot ${out}`);
}

const shots = [];

// 1. One top bar -- the merged bar with its handles. The bar is the feature, so
// a full-width crop is the right frame.
shots.push(async () => {
  await load();
  await cropTo(".topbar", "topbar.png");
});

// 2. Theme picker open next to a focused, themed terminal.
shots.push(async () => {
  await load();
  await focusTerminal();
  await applyTheme("Nord"); // recolour the terminal so the change is visible
  await page.click('.bar-btn[title="Theme"]'); // reopen the picker for the shot
  await page.waitForTimeout(300);
  await shotViewport("theme.png");
});

// 3. New-clip dropdown over the app.
shots.push(async () => {
  await load();
  await focusTerminal();
  await page.click(".bar-btn-primary");
  await page.waitForTimeout(300);
  await shotViewport("newclip.png");
});

// 4. Clip-actions panel (mod+K) rising over a focused terminal.
shots.push(async () => {
  await load();
  await focusTerminal();
  await page.evaluate(() => window.app.openActions());
  await page.waitForTimeout(300);
  await shotViewport("actions.png");
});

// 5. Stacks switcher from the top-left breadcrumb.
shots.push(async () => {
  await load();
  await focusTerminal();
  await page.click(".stack-crumb");
  await page.waitForTimeout(300);
  await shotViewport("stacks.png");
});

// 6. Scrollable (niri) stack layout, with a terminal focused so the strip reads.
shots.push(async () => {
  await load();
  const before = await page.evaluate(() =>
    document.querySelector("#doc")?.classList.contains("layout-niri")
  );
  if (!before) {
    await page.evaluate(() => window.app.toggleLayout());
    await page.waitForSelector("#doc.layout-niri", { timeout: 6000 }).catch(
      () => {},
    );
    await page.waitForTimeout(800);
  }
  await focusTerminal();
  await shotViewport("layout-niri.png");
  if (!before) {
    await page.evaluate(() => window.app.toggleLayout());
    await page.waitForTimeout(400);
  }
});

// 7. Live terminal pane -- the server-rendered cell grid itself, focused. A
// generous pane crop is the right frame for "a terminal as an HTML grid".
shots.push(async () => {
  await load();
  const cid = await focusTerminal();
  if (!cid) {
    console.log("skip terminal.png (no terminal in focused stack)");
    return;
  }
  await cropTo(`.pane[data-clip="${cid}"]`, "terminal.png");
});

for (const s of shots) {
  try {
    await s();
  } catch (e) {
    console.log("FAILED " + e.message);
  }
}

await browser.close();
console.log("done -> " + OUTDIR);
