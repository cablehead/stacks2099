// End-to-end smoke tests: the live SSE render and the per-mime clip panes that
// the projection unit tests (tests/test_projection.nu) can't reach.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnApp, launchBrowser, PNG_1x1 } from "./lib.mjs";

let app, browser;
before(async () => { app = await spawnApp(); browser = await launchBrowser(); });
after(async () => { await browser?.close(); app?.close(); });

const open = async () => {
  const page = await browser.newPage();
  await page.goto(app.base);
  await page.waitForSelector("#clips-list li", { timeout: 15000 });
  return page;
};

test("boots: stacks + clips columns and a live terminal grid", async () => {
  const page = await open();
  try {
    await page.waitForSelector("#doc .pane", { timeout: 15000 });
    // the seeded terminal's pty streamed rows into its grid
    await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] *"), { timeout: 15000 });
    const s = await page.evaluate(() => ({
      stacks: document.querySelectorAll("#stacks-list li").length,
      clips: document.querySelectorAll("#clips-list li").length,
    }));
    assert.ok(s.stacks >= 1, "a stack renders in the left column");
    assert.ok(s.clips >= 1, "a clip renders in the middle column");
  } finally { await page.close(); }
});

test("image clip renders inline via /clip/blob", async () => {
  const page = await open();
  try {
    await page.evaluate(async (bytes) => {
      await fetch("/clip/add", { method: "POST", headers: { "content-type": "image/png" }, body: new Uint8Array(bytes) });
    }, [...PNG_1x1]);
    await page.waitForFunction(() => {
      const i = document.querySelector("#doc .pane img.clip-img");
      return i && i.complete && i.naturalWidth > 0;
    }, { timeout: 10000 });
  } finally { await page.close(); }
});

test("uri-list clip renders a live <iframe> embed", async () => {
  const page = await open();
  try {
    await page.evaluate(async (base) => {
      await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/uri-list" }, body: `${base}/\n` });
    }, app.base);
    const f = await page.waitForSelector("#doc .pane iframe.clip-embed", { timeout: 10000 });
    assert.ok((await f.getAttribute("src"))?.startsWith(app.base), "iframe points at the URL");
  } finally { await page.close(); }
});

test("markdown clip toggles rendered <-> edit", async () => {
  const page = await open();
  try {
    await page.evaluate(async () => {
      await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "# Heading\n\n- a\n- b\n" });
    });
    // the new markdown note offers a "Rendered" toggle
    await page.waitForFunction(
      () => [...document.querySelectorAll("#doc .pane .mini-btn")].some((b) => b.textContent.includes("Rendered")),
      { timeout: 10000 });
    await page.locator("#doc .pane .mini-btn", { hasText: "Rendered" }).first().click();
    const h1 = await page.waitForSelector("#doc .pane .clip-md h1", { timeout: 10000 });
    assert.equal((await h1.textContent())?.trim(), "Heading", "markdown renders to HTML");
    // and back to the editable note (the <pre> shows; the textarea is hidden
    // until focused, so assert the display element returns)
    await page.locator("#doc .pane .mini-btn", { hasText: "Edit" }).first().click();
    await page.waitForSelector("#doc .pane .note-pre", { timeout: 10000 });
  } finally { await page.close(); }
});
