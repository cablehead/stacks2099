// Screenshot a running stacks2099 into a PNG -- a dev/debugging aid (not a test).
//
// Drives chromium against an already-running server and saves a viewport shot,
// printing a one-line summary of what rendered. Useful for showing the live UI
// to a reviewer (or an agent) without a manual screen grab.
//
//   node shoot.mjs                       # shoot the dev default, /tmp/stacks2099-shot.png
//   node shoot.mjs /tmp/foo.png          # custom output path
//   node shoot.mjs --add                 # also post the shot into the running stack
//   BASE=http://127.0.0.1:5300 node shoot.mjs   # a different instance
//
// The dev server's default address is 127.0.0.1:5099 (target/debug/stacks2099
// --dev). This reads whatever store that server was launched with, so it shows
// the real, current UI -- the same stacks/clips/live pty grids you see, minus
// transient client-only state (focus, scroll, unsubmitted edits).
//
// With --add it POSTs the PNG to /clip/add, which files it as an image clip in
// the current (last-focused) stack -- so the running session can see what the
// browser rendered, no manual screen grab or paste.
import { launchBrowser } from "./lib.mjs";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const ADD = args.includes("--add");
const BASE = process.env.BASE || "http://127.0.0.1:5099";
const OUT = args.find((a) => !a.startsWith("--")) || process.env.PNG ||
  join(tmpdir(), "stacks2099-shot.png");

const browser = await launchBrowser();
const ctx = await browser.newContext({
  viewport: { width: 1280, height: 800 },
});
const page = await ctx.newPage();
const errors = [];
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});

await page.goto(BASE, { waitUntil: "domcontentloaded" });
// Wait for the SSE-driven projection to render at least one pane, then give the
// terminal grid a beat to stream a frame.
try {
  await page.waitForSelector(".pane", { timeout: 12000 });
} catch { /* shoot anyway */ }
await page.waitForTimeout(1500);

const summary = await page.evaluate(() => ({
  title: document.title,
  panes: document.querySelectorAll(".pane").length,
  clips: document.querySelectorAll("[data-clip]").length,
  hasGrid: !!document.querySelector("[id^='grid-'] *"),
}));
console.log("summary " + JSON.stringify(summary));
if (errors.length) {
  console.log("console_errors " + JSON.stringify(errors.slice(0, 5)));
}

await page.screenshot({ path: OUT, fullPage: false });
await browser.close();
console.log("shot " + OUT);

if (ADD) {
  const res = await fetch(`${BASE}/clip/add`, {
    method: "POST",
    headers: { "content-type": "image/png" },
    body: readFileSync(OUT),
  });
  if (!res.ok) throw new Error(`clip/add ${res.status}`);
  console.log("added clip " + (await res.text()).trim());
}
