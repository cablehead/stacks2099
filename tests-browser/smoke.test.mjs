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

test("terminal row ids stay stable across scrollback purge", () => withApp(async (page) => {
  // Regression for the full-grid-morph cliff: row ids in `#grid-<cid>` are
  // wezterm's StableRowIndex, not the phys index, so when scrollback fills past
  // its cap and oldest lines purge, surviving rows keep their ids and idiomorph
  // leaves them untouched. Pre-fix the ids would shift by one per purge and the
  // browser re-morphed the entire scrollback on every frame.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => {
    const s = document.querySelector("[id^='screen-']");
    return s && s.getAttribute("data-sid");
  }, { timeout: 15000 });
  const sid = await page.evaluate(() => document.querySelector("[id^='screen-']").getAttribute("data-sid"));
  const gridSel = await page.evaluate(() => "#" + document.querySelector("[id^='grid-']").id);

  const send = (cmd) => page.evaluate(
    async ({ sid, cmd }) => {
      const r = await fetch(`/pty/input?sid=${encodeURIComponent(sid)}`, { method: "POST", body: cmd });
      if (!r.ok) throw new Error(`pty/input ${r.status}`);
    },
    { sid, cmd },
  );
  const idOfText = (text) => page.evaluate(
    ({ sel, text }) => {
      for (const r of document.querySelectorAll(sel + " .row")) {
        if (r.textContent.trim() === text) return r.id;
      }
      return null;
    },
    { sel: gridSel, text },
  );
  const topRowId = () => page.evaluate((sel) => document.querySelector(sel + " .row").id, gridSel);

  // Emit ~3200 marker lines so the 3000-line cap purges and at least 200 sit in
  // the retained-but-not-original window we'll re-check after another purge.
  await send("for i in 1..3200 { print $\"M_($i)\" }\n");
  await page.waitForFunction(
    (sel) => document.querySelectorAll(sel + " .row").length >= 3000,
    gridSel,
    { timeout: 30000 },
  );

  const marker = "M_2500";
  const markerIdBefore = await idOfText(marker);
  assert.ok(markerIdBefore, `${marker} should be in the retained scrollback`);
  const topIdBefore = await topRowId();

  // Push another 200 lines so the oldest ~200 rows purge off the top.
  await send("for i in 1..200 { print $\"N_($i)\" }\n");
  await page.waitForFunction(
    ({ sel, topIdBefore }) => document.querySelector(sel + " .row")?.id !== topIdBefore,
    { sel: gridSel, topIdBefore },
    { timeout: 15000 },
  );

  const markerIdAfter = await idOfText(marker);
  assert.equal(markerIdAfter, markerIdBefore, `${marker} must keep its row id across a purge`);

  // Row ids are scoped to their grid: `{target}-r-{stable}` (e.g. `grid-foo-r-42`).
  const num = (id) => Number.parseInt(id.replace(/^.*-r-/, ""), 10);
  const topIdAfter = await topRowId();
  assert.ok(
    num(topIdAfter) > num(topIdBefore),
    `top row id must advance after purge: ${topIdBefore} -> ${topIdAfter}`,
  );
}));

test("seqno-diff: post-cap keystroke ships a bounded patch", () => withApp(async (page) => {
  // Regression guard for the seqno-driven per-row diff: above the 3000-line
  // scrollback cap, a single keystroke's SSE patch bundle must stay tiny
  // (the per-row delta), not the whole grid (which pre-diff was ~387 KB
  // every frame). Opens its own /pty/view subscriber so we can size the
  // raw SSE bytes without coordinating with the page's stream.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => {
    const s = document.querySelector("[id^='screen-']");
    return s && s.getAttribute("data-sid");
  }, { timeout: 15000 });
  const sid = await page.evaluate(() => document.querySelector("[id^='screen-']").getAttribute("data-sid"));

  const sizes = await page.evaluate(async (sid) => {
    const out = [];
    const ctrl = new AbortController();
    const resp = await fetch(`/pty/view?sid=${encodeURIComponent(sid)}&target=t-probe&nosig=1`, { signal: ctrl.signal });
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    const drain = () => {
      let i;
      while ((i = buf.indexOf("\n\n")) !== -1) {
        const raw = buf.slice(0, i);
        buf = buf.slice(i + 2);
        if (raw.startsWith("event: datastar-patch-elements")) out.push(raw);
      }
    };
    // Pump until a quiet period of `quietMs` with no new events, capped at `maxMs`.
    const pumpUntilQuiet = async (quietMs, maxMs) => {
      const deadline = Date.now() + maxMs;
      let lastCount = out.length;
      let quietStart = Date.now();
      while (Date.now() < deadline) {
        const timeout = new Promise((r) => setTimeout(() => r("timeout"), 200));
        const got = await Promise.race([reader.read(), timeout]);
        if (got === "timeout") {
          if (out.length === lastCount && Date.now() - quietStart >= quietMs) return;
          if (out.length !== lastCount) { lastCount = out.length; quietStart = Date.now(); }
          continue;
        }
        if (got.done) return;
        if (got.value) buf += dec.decode(got.value, { stream: true });
        drain();
        if (out.length !== lastCount) { lastCount = out.length; quietStart = Date.now(); }
      }
    };

    await pumpUntilQuiet(500, 5000);
    const firstFrame = { events: out.length, bytes: out.reduce((a, e) => a + e.length, 0) };
    out.length = 0;

    // Fill past the 3000-line cap.
    await fetch(`/pty/input?sid=${encodeURIComponent(sid)}`, { method: "POST", body: "for i in 1..3500 { print $\"x_($i)\" }\n" });
    await pumpUntilQuiet(500, 25000);
    out.length = 0;

    // The keystroke we actually care about: a single line above the cap.
    await fetch(`/pty/input?sid=${encodeURIComponent(sid)}`, { method: "POST", body: "print 'k'\n" });
    await pumpUntilQuiet(500, 5000);
    const post = { events: out.length, bytes: out.reduce((a, e) => a + e.length, 0) };

    ctrl.abort();
    return { firstFrame, post };
  }, sid);

  // First frame ships the full current grid in one outer patch.
  assert.ok(sizes.firstFrame.events >= 1, "first frame must arrive");
  // The pre-diff cliff was ~387 KB per post-cap frame. A loose 10 KB ceiling
  // catches a regression to full-scrollback emit without being brittle to
  // shell prompt repaints (a 30-row repaint at ~150B/row is well under).
  assert.ok(
    sizes.post.bytes < 10_000,
    `post-cap keystroke must ship <10KB of SSE, got ${sizes.post.bytes}B in ${sizes.post.events} events`,
  );
}));

test("seqno-diff: appended rows are direct siblings with no text node between them", () => withApp(async (page) => {
  // Regression for the SSE-join blank-line bug: multiple `data: elements`
  // lines in one event get joined with `\n` by the browser, datastar feeds
  // that to DOMParser, and the `\n` between top-level siblings becomes a
  // visible text node in the parsed fragment. With `white-space: pre` on
  // the grid that text node renders as a blank line between every appended
  // row -- one per line of pty output, accumulating fast.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => {
    const s = document.querySelector("[id^='screen-']");
    return s && s.getAttribute("data-sid");
  }, { timeout: 15000 });
  const sid = await page.evaluate(() => document.querySelector("[id^='screen-']").getAttribute("data-sid"));

  // Drive a burst that forces a multi-row append in a single diff frame.
  await page.evaluate(
    async (sid) => {
      await fetch(`/pty/input?sid=${encodeURIComponent(sid)}`, {
        method: "POST",
        body: "for i in 1..200 { print $\"row_($i)\" }\n",
      });
    },
    sid,
  );
  await page.waitForFunction(
    () => document.querySelectorAll("[id^='grid-'] .row").length >= 200,
    { timeout: 15000 },
  );

  const stray = await page.evaluate(() => {
    const g = document.querySelector("[id^='grid-']");
    let count = 0;
    for (const n of g.childNodes) {
      if (n.nodeType === 3 && n.textContent.includes("\n")) count++;
    }
    return count;
  });
  assert.equal(stray, 0, `no stray "\\n" text nodes should sit between row siblings (found ${stray})`);
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
