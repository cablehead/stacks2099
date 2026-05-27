// End-to-end smoke tests: the live SSE render and the per-mime clip panes that
// the projection unit tests (tests/test_projection.nu) can't reach. Each test
// gets a fresh, isolated server (own store/port) so clips don't leak between
// tests; the chromium instance is shared.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnApp, launchBrowser, PNG_1x1 } from "./lib.mjs";

let browser;
before(async () => { browser = await launchBrowser(); });
after(async () => { await browser?.close(); });

// Fresh app + page for one test; cleaned up after.
const withApp = async (fn) => {
  const app = await spawnApp();
  const page = await browser.newPage();
  try {
    await page.goto(app.base);
    await page.waitForSelector("#clips-list li", { timeout: 15000 });
    await fn(page, app);
  } finally {
    await page.close();
    app.close();
  }
};

test("boots: stacks + clips columns and a live terminal grid", () => withApp(async (page) => {
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] *"), { timeout: 15000 });
  const s = await page.evaluate(() => ({
    stacks: document.querySelectorAll("#stacks-list li").length,
    clips: document.querySelectorAll("#clips-list ul.clips li").length,
  }));
  assert.ok(s.stacks >= 1, "a stack renders in the left column");
  assert.ok(s.clips >= 1, "a clip renders in the middle column");
}));

test("image clip renders inline via /clip/blob", () => withApp(async (page) => {
  await page.evaluate(async (bytes) => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "image/png" }, body: new Uint8Array(bytes) });
  }, [...PNG_1x1]);
  await page.waitForFunction(() => {
    const i = document.querySelector("#doc .pane img.clip-img");
    return i && i.complete && i.naturalWidth > 0;
  }, { timeout: 10000 });
}));

test("uri-list clip renders a live <iframe> embed", () => withApp(async (page, app) => {
  await page.evaluate(async (base) => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/uri-list" }, body: `${base}/\n` });
  }, app.base);
  const f = await page.waitForSelector("#doc .pane iframe.clip-embed", { timeout: 10000 });
  assert.ok((await f.getAttribute("src"))?.startsWith(app.base), "iframe points at the URL");
}));

test("move reorders #doc panes by relocating nodes (terminal stays live)", () => withApp(async (page) => {
  // seed two notes -> doc is [terminal, alpha, beta]
  await page.evaluate(async () => {
    for (const b of ["alpha", "beta"]) {
      await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: b });
    }
  });
  await page.waitForFunction(() => document.querySelectorAll("#doc .pane").length === 3, { timeout: 10000 });
  await page.waitForTimeout(400);
  const before = await page.evaluate(() => [...document.querySelectorAll("#doc .pane")].map((p) => p.dataset.clip));
  assert.ok(await page.evaluate(() => !!document.querySelector("[id^='grid-'] *")), "terminal grid is live before the move");

  // select the last clip, move it up one slot
  await page.locator("#clips-list ul.clips li").last().locator(".row").click();
  await page.waitForTimeout(300);
  await page.evaluate(() => window.app.move("up"));
  await page.waitForFunction(
    (lastId) => [...document.querySelectorAll("#doc .pane")].map((p) => p.dataset.clip)[1] === lastId,
    before[2], { timeout: 8000 });

  const after = await page.evaluate(() => [...document.querySelectorAll("#doc .pane")].map((p) => p.dataset.clip));
  assert.equal(after[1], before[2], "the moved clip rose one slot");
  assert.deepEqual([...after].sort(), [...before].sort(), "same panes, just reordered");
  assert.ok(await page.evaluate(() => !!document.querySelector("[id^='grid-'] *")), "terminal grid survived the reorder");
}));

test("markdown clip toggles rendered <-> edit", () => withApp(async (page) => {
  await page.evaluate(async () => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "# Heading\n\n- a\n- b\n" });
  });
  await page.waitForFunction(
    () => [...document.querySelectorAll("#doc .pane .mini-btn")].some((b) => b.textContent.includes("Rendered")),
    { timeout: 10000 });
  await page.locator("#doc .pane .mini-btn", { hasText: "Rendered" }).first().click();
  const h1 = await page.waitForSelector("#doc .pane .clip-md h1", { timeout: 10000 });
  assert.equal((await h1.textContent())?.trim(), "Heading", "markdown renders to HTML");
  await page.locator("#doc .pane .mini-btn", { hasText: "Edit" }).first().click();
  await page.waitForSelector("#doc .pane .note-pre", { timeout: 10000 });
}));
