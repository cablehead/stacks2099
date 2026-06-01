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

test("seqno-diff: alternate-screen flip replaces the grid then restores main on exit", () => withApp(async (page) => {
  // Regression for the bat/less/vim hang: the primary and alternate screens
  // have independent line storage + seqnos in wezterm, so a `\x1b[?1049h`
  // transition makes the diff state invalid. Without a full re-emit on the
  // flip, alt content overlays the first N rows of stale main content and
  // less's status line lands somewhere nonsensical. We force the same
  // entry/exit a TUI would and assert that the row set actually swaps.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => {
    const s = document.querySelector("[id^='screen-']");
    return s && s.getAttribute("data-sid");
  }, { timeout: 15000 });
  const sid = await page.evaluate(() => document.querySelector("[id^='screen-']").getAttribute("data-sid"));
  const send = (cmd) => page.evaluate(
    async ({ sid, cmd }) => {
      await fetch(`/pty/input?sid=${encodeURIComponent(sid)}`, { method: "POST", body: cmd });
    },
    { sid, cmd },
  );
  const hasMainMarker = () => page.evaluate(() =>
    [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => r.textContent.trim().startsWith("MAIN_"))
  );
  const hasAltMarker = () => page.evaluate(() =>
    [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => /^#\s*Network services/.test(r.textContent.trim()))
  );

  // Seed main-screen scrollback with a unique marker that must survive
  // entry/exit through `less` and must be GONE while less is active.
  await send("for i in 1..20 { print $\"MAIN_($i)\" }\n");
  await page.waitForFunction(
    () => [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => r.textContent.trim().startsWith("MAIN_")),
    { timeout: 10000 },
  );

  // Enter `less` -- switches to the alternate screen.
  await send("less /etc/services\n");
  await page.waitForFunction(
    () => [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => /^#\s*Network services/.test(r.textContent.trim())),
    { timeout: 10000 },
  );
  assert.ok(await hasAltMarker(), "alt-screen content (/etc/services header) should be in the grid while less is active");
  assert.ok(!(await hasMainMarker()), "MAIN_* markers must NOT be visible while the alternate screen is active");

  // Exit less ('q'). Restores the primary screen, including MAIN_* markers.
  await send("q");
  await page.waitForFunction(
    () => [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => r.textContent.trim().startsWith("MAIN_")),
    { timeout: 10000 },
  );
  assert.ok(await hasMainMarker(), "MAIN_* markers must reappear after exiting the alternate screen");
  assert.ok(!(await hasAltMarker()), "the alt-screen /etc/services header should be gone after exit");
}));

test("rename terminal: live grid + cursor survive; pane-head label updates", () => withApp(async (page) => {
  // Regression: a clip.patch{label} for a terminal used to fall into the
  // full-pane repane path, which re-emitted `<div id='grid-{cid}'></div>`
  // and let idiomorph wipe the live scrollback until /pty/view reconnected.
  // The fix is to patch only the `<header id='pane-head-{cid}'>` for
  // terminals on a label change, never the whole <section>.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const before = await page.evaluate(() => ({
    rows: document.querySelectorAll("[id^='grid-'] .row").length,
    cursor: !!document.querySelector("[id^='grid-'] .cursor"),
  }));
  assert.ok(before.rows > 0, "grid must have rows before the rename");
  assert.ok(before.cursor, "cursor overlay must exist before the rename");

  // Open the rename modal, type a new name, submit.
  await page.evaluate(() => document.getElementById("rename-tab-trigger")?.click());
  await page.waitForSelector(".modal-input", { timeout: 5000 });
  await page.evaluate(() => {
    const i = document.querySelector(".modal-input");
    i.value = "RENAMED_PROBE";
    i.dispatchEvent(new Event("input", { bubbles: true }));
    i.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
  });

  // The label patch and head update arrive over SSE; wait for the new label
  // to appear in the pane-head text.
  await page.waitForFunction(
    () => !!document.querySelector("#doc .pane .pane-head")?.textContent?.includes("RENAMED_PROBE"),
    { timeout: 5000 },
  );

  const after = await page.evaluate(() => ({
    rows: document.querySelectorAll("[id^='grid-'] .row").length,
    cursor: !!document.querySelector("[id^='grid-'] .cursor"),
  }));
  assert.ok(after.rows > 0, `grid must still have rows after the rename (had ${before.rows}, now ${after.rows})`);
  assert.ok(after.cursor, "cursor overlay must survive the rename");
}));

test("rename modal pre-fills from the $label signal", () => withApp(async (page) => {
  // Regression: openRenameTab used to scrape `btn.firstChild.textContent`,
  // which is the row icon's `<svg>` -- so the modal opened with the wrong
  // text (or empty). Now the trigger button's `data-on:click` reads `$label`
  // directly, and the server keeps `$label` in sync with the selected clip.
  await page.waitForSelector("#doc .pane", { timeout: 15000 });
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });

  // Open the modal; the draft input must contain a non-empty, non-svg value
  // (the dev terminal clip's default display label is "nu").
  await page.evaluate(() => document.getElementById("rename-tab-trigger")?.click());
  const drafted = await page.waitForFunction(
    () => document.querySelector(".modal-input")?.value,
    { timeout: 5000 },
  ).then((h) => h.jsonValue());
  assert.ok(typeof drafted === "string" && drafted.length > 0, `modal must pre-fill from $label, got "${drafted}"`);
}));

test("focusing a note opens the editor + receives keystrokes", () => withApp(async (page) => {
  // Regression: __focusClip used to branch on `pane.dataset.kind === 'note'`,
  // but a note clip's kind is 'content' (the only kinds are 'content' and
  // 'terminal'). The right discriminator is `dataset.render === 'note'`,
  // which matches what scanPanes already uses. Pre-fix the textarea never
  // became visible or focused, so the user couldn't type into a note.
  await page.evaluate(async () => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "initial" });
  });
  await page.waitForFunction(() => document.querySelectorAll("#doc .pane").length >= 2, { timeout: 10000 });
  await page.waitForFunction(
    () => [...document.querySelectorAll("#doc .pane")].some((p) => p.dataset.render === "note"),
    { timeout: 10000 },
  );
  const cid = await page.evaluate(() =>
    [...document.querySelectorAll("#doc .pane")].find((p) => p.dataset.render === "note")?.dataset.clip
  );
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  const focused = await page.evaluate(() => document.activeElement?.classList.contains("note-edit"));
  assert.ok(focused, "the note's textarea must be focused after __focusClip");

  await page.keyboard.type(" typed!");
  const value = await page.evaluate(() => document.querySelector(".note-edit")?.value);
  assert.equal(value, "initial typed!", `typed keystrokes must land in the textarea (got "${value}")`);
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

// Regression: the server used to skip re-rendering a note's pane on every
// clip.update (the `editing_note` guard), so a note edited by anything other
// than this browser (an agent, the CLI) never refreshed live -- it stayed stale
// until reload. The pane now re-renders live; the <pre> picks up the new body.
test("an outside note update refreshes the <pre> live", () => withApp(async (page) => {
  await page.evaluate(async () => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "before" });
  });
  await page.waitForFunction(
    () => [...document.querySelectorAll("#doc .pane")].some((p) => p.dataset.render === "note"),
    { timeout: 10000 });
  const cid = await page.evaluate(() =>
    [...document.querySelectorAll("#doc .pane")].find((p) => p.dataset.render === "note")?.dataset.clip
  );
  // Simulate an agent rewriting the note body from outside the editor.
  await page.evaluate(async (cid) => {
    await fetch("/clip/update?clip=" + encodeURIComponent(cid), {
      method: "POST", headers: { "content-type": "text/plain" }, body: "after",
    });
  }, cid);
  await page.waitForFunction(
    (cid) => document.querySelector("#note-pre-" + CSS.escape(cid))?.textContent === "after",
    cid,
    { timeout: 10000 },
  );
}));

// The flip side of the live refresh: an in-flight edit must survive an outside
// update. The editor textarea carries data-ignore-morph, so the morph that
// refreshes the <pre> underneath leaves the unsaved draft (and focus) intact.
test("an outside note update preserves an in-flight edit", () => withApp(async (page) => {
  await page.evaluate(async () => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "base" });
  });
  await page.waitForFunction(
    () => [...document.querySelectorAll("#doc .pane")].some((p) => p.dataset.render === "note"),
    { timeout: 10000 });
  const cid = await page.evaluate(() =>
    [...document.querySelectorAll("#doc .pane")].find((p) => p.dataset.render === "note")?.dataset.clip
  );
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.keyboard.type(" draft");
  // Agent rewrites the body underneath the open editor.
  await page.evaluate(async (cid) => {
    await fetch("/clip/update?clip=" + encodeURIComponent(cid), {
      method: "POST", headers: { "content-type": "text/plain" }, body: "agent body",
    });
  }, cid);
  // The <pre> picks up the agent's body live...
  await page.waitForFunction(
    (cid) => document.querySelector("#note-pre-" + CSS.escape(cid))?.textContent === "agent body",
    cid,
    { timeout: 10000 },
  );
  // ...while the editor keeps the unsaved draft and stays focused.
  const value = await page.evaluate(() => document.querySelector(".note-edit")?.value);
  assert.equal(value, "base draft", `the in-flight draft must survive the morph (got "${value}")`);
  const focused = await page.evaluate(() => document.activeElement?.classList.contains("note-edit"));
  assert.ok(focused, "the editor stays focused through the morph");
}));

// The new-clip picker is pure client logic (no server round-trip until a row is
// chosen), so the projection tests can't reach it. Its keyboard quick-select is
// the whole point -- a capture-phase handler patched in on the $picking edge.
test("new-clip picker: Ctrl-n/Ctrl-p and arrows move selection; Enter creates the clip; Esc closes", () => withApp(async (page) => {
  // Scope to .picker-panel: the bottom clip-actions panel reuses .picker-row.
  const sel = () => page.$$eval(".picker-panel .picker-row", (rs) => rs.map((r) => r.classList.contains("sel")));
  const selIdx = () => page.evaluate(() => [...document.querySelectorAll(".picker-panel .picker-row")].findIndex((r) => r.classList.contains("sel")));
  const hidden = () => page.evaluate(() => getComputedStyle(document.querySelector(".picker-backdrop")).display === "none");

  // Open from the top bar via Alt+T; selection starts on the first row.
  await page.keyboard.press("Alt+t");
  await page.waitForSelector(".picker-backdrop", { state: "visible", timeout: 5000 });
  await page.waitForFunction(() => document.querySelector(".picker-panel .picker-row.sel") === document.querySelector(".picker-panel .picker-row"), { timeout: 3000 });
  assert.deepEqual(await sel(), [true, false], "opens with the first row (Terminal) selected");

  // One highlight that Ctrl-n / Ctrl-p / ArrowDown move.
  await page.keyboard.press("Control+n");
  await page.waitForFunction(() => [...document.querySelectorAll(".picker-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });
  await page.keyboard.press("Control+p");
  assert.deepEqual(await sel(), [true, false], "Ctrl-p returns to the first row");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => [...document.querySelectorAll(".picker-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });

  // Esc closes and creates nothing.
  const panesBefore = await page.evaluate(() => document.querySelectorAll("#doc .pane").length);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".picker-backdrop")).display === "none", { timeout: 3000 });
  await page.waitForTimeout(300);
  assert.equal(await page.evaluate(() => document.querySelectorAll("#doc .pane").length), panesBefore, "Esc creates no clip");

  // Reopen, select Note (row 1), Enter creates a note pane over SSE.
  await page.keyboard.press("Alt+t");
  await page.waitForSelector(".picker-backdrop", { state: "visible", timeout: 5000 });
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => [...document.querySelectorAll(".picker-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });
  assert.equal(await selIdx(), 1, "Note row is selected before Enter");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".picker-backdrop")).display === "none", { timeout: 3000 });
  assert.ok(await hidden(), "Enter closes the picker");
  await page.waitForFunction(
    () => [...document.querySelectorAll("#doc .pane")].some((p) => p.dataset.render === "note"),
    { timeout: 10000 },
  );
}));

// The picker is modal while open: it must own every key, so nothing leaks to a
// terminal. Regression guard for the picker's scoped capture handler
// (stopImmediatePropagation) -- picker keys must never reach the pty. App
// chords like Alt+T are navigate-only now (ADR 0005: a focused clip owns all
// keys), so opening goes through navigate.
test("new-clip picker: while open, keystrokes don't leak to the terminal", () => withApp(async (page) => {
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const cid = await page.evaluate(() => document.querySelector("#doc .pane[data-render='terminal']")?.dataset.clip);
  assert.ok(cid, "a terminal pane is present");

  // Open the picker (navigate mode) and type characters that would reach the
  // pty if they leaked. They must be swallowed by the picker.
  await page.keyboard.press("Alt+t");
  await page.waitForSelector(".picker-backdrop", { state: "visible", timeout: 5000 });
  await page.keyboard.type("LEAKZZZ");
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".picker-backdrop")).display === "none", { timeout: 3000 });

  // Focus the terminal and type a sentinel that DOES reach the pty and echoes.
  // pty input is ordered, so once the sentinel shows, any leaked LEAKZZZ would
  // be on the line too.
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.waitForTimeout(150);
  await page.keyboard.type("SENT9");
  await page.waitForFunction(
    () => [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => r.textContent.includes("SENT9")),
    { timeout: 10000 },
  );
  const leaked = await page.evaluate(() =>
    [...document.querySelectorAll("[id^='grid-'] .row")].some((r) => r.textContent.includes("LEAKZZZ"))
  );
  assert.ok(!leaked, "no picker keystroke reached the terminal");
}));

// The clip-actions panel is the bottom-right mirror of the New picker: same
// scoped capture-phase handler, opened by mod-K in navigate mode. Holds the
// current-clip actions (Rename / Close).
test("clip-actions: mod-K opens in navigate; Ctrl-n/Ctrl-p move; Enter opens rename; Esc closes", () => withApp(async (page) => {
  const selIdx = () => page.evaluate(() => [...document.querySelectorAll(".actions-panel .picker-row")].findIndex((r) => r.classList.contains("sel")));
  const hidden = () => page.evaluate(() => getComputedStyle(document.querySelector(".actions-backdrop")).display === "none");

  // Linux headless: mod = Ctrl. Open from navigate mode; Rename (row 0) selected.
  await page.keyboard.press("Control+k");
  await page.waitForSelector(".actions-backdrop", { state: "visible", timeout: 5000 });
  assert.equal(await selIdx(), 0, "opens with Rename selected");

  await page.keyboard.press("Control+n");
  await page.waitForFunction(() => [...document.querySelectorAll(".actions-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });
  await page.keyboard.press("Control+p");
  assert.equal(await selIdx(), 0, "Ctrl-p returns to Rename");

  // Esc closes without opening rename.
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".actions-backdrop")).display === "none", { timeout: 3000 });
  assert.equal(await page.evaluate(() => !!document.querySelector(".modal-backdrop") && getComputedStyle(document.querySelector(".modal-backdrop")).display !== "none"), false, "Esc opens no rename modal");

  // Reopen, Enter on Rename opens the rename modal and closes the panel.
  await page.keyboard.press("Control+k");
  await page.waitForSelector(".actions-backdrop", { state: "visible", timeout: 5000 });
  await page.keyboard.press("Enter");
  await page.waitForSelector(".modal-input", { state: "visible", timeout: 5000 });
  assert.ok(await hidden(), "the actions panel closed when Rename was chosen");
}));

test("clip-actions: Close removes the selected clip", () => withApp(async (page) => {
  // Add a note so there are two clips, then select the note and close it.
  await page.evaluate(async () => {
    await fetch("/clip/add", { method: "POST", headers: { "content-type": "text/markdown" }, body: "doomed" });
  });
  await page.waitForFunction(() => document.querySelectorAll("#doc .pane").length >= 2, { timeout: 10000 });
  const noteCid = await page.evaluate(() =>
    [...document.querySelectorAll("#doc .pane")].find((p) => p.dataset.render === "note")?.dataset.clip
  );
  assert.ok(noteCid, "a note pane exists");
  // Select the note's clips-list row (matched by the id prefix in its <small>)
  // so it becomes the current (.active) clip.
  await page.evaluate((cid) => {
    const short = cid.slice(0, 8);
    const li = [...document.querySelectorAll("#clips-list ul.clips li")]
      .find((el) => el.querySelector(".row small")?.textContent?.trim() === short);
    li?.querySelector(".row")?.click();
  }, noteCid);
  await page.waitForFunction((cid) => document.querySelector("#pane-" + CSS.escape(cid))?.classList.contains("active"), noteCid, { timeout: 5000 });

  // Open actions; Close is the last row. Ctrl-p from row 0 wraps up to it.
  await page.keyboard.press("Control+k");
  await page.waitForSelector(".actions-backdrop", { state: "visible", timeout: 5000 });
  await page.keyboard.press("Control+p");
  await page.waitForFunction(() => {
    const rows = [...document.querySelectorAll(".actions-panel .picker-row")];
    return rows.findIndex((r) => r.classList.contains("sel")) === rows.length - 1;
  }, { timeout: 3000 });
  await page.keyboard.press("Enter");

  await page.waitForFunction((cid) => !document.querySelector("#pane-" + CSS.escape(cid)), noteCid, { timeout: 10000 });
}));

test("clip-actions: Ctrl-K stays with a focused terminal (readline kill-line, not the panel)", () => withApp(async (page) => {
  // Ctrl+K is kill-line for a focused terminal on every platform, so it must
  // NOT open the panel while a terminal is focused -- only Cmd+K does.
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const cid = await page.evaluate(() => document.querySelector("#doc .pane[data-render='terminal']")?.dataset.clip);
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.waitForTimeout(150);

  await page.keyboard.press("Control+k");
  await page.waitForTimeout(300);
  const open = await page.evaluate(() => getComputedStyle(document.querySelector(".actions-backdrop")).display !== "none");
  assert.ok(!open, "Ctrl-K must not open the clip-actions panel while a terminal is focused");
}));

test("clip-actions: Cmd-K opens the panel even when a terminal is focused", () => withApp(async (page) => {
  // Cmd+K is a Meta combo, which key-buffer drops, so it never reaches the pty
  // -- it opens clip actions in every mode, including a focused terminal.
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const cid = await page.evaluate(() => document.querySelector("#doc .pane[data-render='terminal']")?.dataset.clip);
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.waitForTimeout(150);

  await page.keyboard.press("Meta+k");
  await page.waitForSelector(".actions-backdrop", { state: "visible", timeout: 5000 });
  assert.equal(
    await page.evaluate(() => [...document.querySelectorAll(".actions-panel .picker-row")].findIndex((r) => r.classList.contains("sel"))),
    0,
    "panel opens with Rename selected, from focus mode",
  );
}));

// macOS Option (and AltGr on non-US layouts) is a character-compose modifier:
// pressing it produces a printable character with altKey=true (e.g. Danish
// Option+I -> "|"). key-buffer must forward that character literally to the pty,
// NOT as a Meta sequence (ESC + char). Sending ESC|, the shell never sees the
// pipe.
test("key-buffer forwards an Option-composed character literally (not ESC-prefixed)", () => withApp(async (page) => {
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const cid = await page.evaluate(() => document.querySelector("#doc .pane[data-render='terminal']")?.dataset.clip);
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.waitForTimeout(150);

  // Capture exactly what key-buffer POSTs to the pty.
  const sent = await page.evaluate(() => {
    return new Promise((resolve) => {
      const orig = window.fetch;
      window.fetch = function (url, opts) {
        if (typeof url === "string" && url.includes("/pty/input") && opts?.body != null) {
          window.fetch = orig;
          resolve(typeof opts.body === "string" ? opts.body : "");
        }
        return orig.apply(this, arguments);
      };
      // Synthesize the keydown a Danish keyboard fires for Option+I = "|":
      // a printable key with altKey set (the OS already composed the glyph).
      window.dispatchEvent(new KeyboardEvent("keydown", {
        key: "|", code: "KeyI", altKey: true, bubbles: true, cancelable: true,
      }));
    });
  });

  assert.equal(sent, "|", `pty must receive the literal "|", got ${JSON.stringify(sent)}`);

  // A genuine Alt+letter chord (ev.key matches the physical key's letter, no
  // composition) still goes through as Meta -- ESC + letter -- for TUIs that
  // bind Meta keys.
  const meta = await page.evaluate(() => {
    return new Promise((resolve) => {
      const orig = window.fetch;
      window.fetch = function (url, opts) {
        if (typeof url === "string" && url.includes("/pty/input") && opts?.body != null) {
          window.fetch = orig;
          resolve(typeof opts.body === "string" ? opts.body : "");
        }
        return orig.apply(this, arguments);
      };
      window.dispatchEvent(new KeyboardEvent("keydown", {
        key: "b", code: "KeyB", altKey: true, bubbles: true, cancelable: true,
      }));
    });
  });
  assert.equal(meta, "\x1bb", `a true Alt+letter chord stays Meta-prefixed, got ${JSON.stringify(meta)}`);
}));

// ADR 0005: a focused clip gets every key raw outside a tiny carve-out. On a
// Danish layout the "~" dead key is Option + the physical BracketRight key, so
// the keydown carries altKey + key:"~" + code:"BracketRight". The old global
// keymap matched physical BracketRight -> "]" -> nextStack and swallowed it, so
// "~" never reached the terminal. With the mode-projected keymap, focus mode
// has no bracket binding, so the character reaches the pty.
test("focus mode passes an Option-composed ~ (physical BracketRight) to the pty, not stack-cycle", () => withApp(async (page) => {
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const cid = await page.evaluate(() => document.querySelector("#doc .pane[data-render='terminal']")?.dataset.clip);
  await page.evaluate((cid) => window.__focusClip(cid), cid);
  await page.waitForTimeout(150);

  const sent = await page.evaluate(() => {
    return new Promise((resolve) => {
      let landed = null;
      const orig = window.fetch;
      window.fetch = function (url, opts) {
        if (typeof url === "string" && url.includes("/pty/input") && opts?.body != null) {
          landed = typeof opts.body === "string" ? opts.body : "";
          window.fetch = orig;
          resolve(landed);
        }
        return orig.apply(this, arguments);
      };
      // Dispatch on document so the event traverses both the capture-phase app
      // keymap (document) and key-buffer (window) -- exactly like a real press.
      document.dispatchEvent(new KeyboardEvent("keydown", {
        key: "~", code: "BracketRight", altKey: true, bubbles: true, cancelable: true,
      }));
      // If nothing was forwarded (the chord was intercepted), resolve empty.
      setTimeout(() => { window.fetch = orig; resolve(landed); }, 500);
    });
  });

  assert.equal(sent, "~", `focused pty must receive "~", got ${JSON.stringify(sent)}`);
}));

test("layout flip to niri resizes the pty to the niri column, not the flow width", () => withApp(async (page) => {
  // Regression: flipping flow->niri measured the pane before the niri 80ch
  // width (and sidebar collapse) had reflowed, so __applyLayout pushed a
  // too-wide resize (the full-width doc) to the pty. A program reading the
  // winsize in that window (e.g. bat) drew to the stale wide size and
  // overflowed the narrower niri column. Every resize after the flip must fit
  // the niri pane.
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  await page.evaluate(() => {
    window.__resizes = [];
    const orig = window.fetch;
    window.fetch = (url, opts) => {
      if (typeof url === "string" && url.includes("/pty/resize")) {
        try { window.__resizes.push(JSON.parse(opts?.body || "{}").cols); } catch {}
      }
      return orig(url, opts);
    };
  });
  await page.evaluate(() => window.app.toggleLayout());
  await page.waitForFunction(() => document.getElementById("doc").classList.contains("layout-niri"), { timeout: 5000 });
  await page.waitForTimeout(700);
  const { resizes, cap } = await page.evaluate(() => {
    const grid = document.querySelector("[id^='grid-']");
    const screen = grid.closest(".pane-screen") || grid.parentElement;
    const probe = document.createElement("span");
    probe.className = "cell-probe"; // grid.css: correct term font + size
    probe.textContent = "M".repeat(80);
    document.body.appendChild(probe);
    const cw = probe.getBoundingClientRect().width / 80;
    probe.remove();
    return { resizes: window.__resizes, cap: Math.floor(screen.clientWidth / cw) };
  });
  assert.ok(resizes.length > 0, "a resize fired on the niri flip");
  for (const c of resizes) {
    // +1 slack for sub-pixel/border rounding. The pre-fix bug emitted the full
    // flow width (e.g. 140), far over the ~80-col niri pane.
    assert.ok(c <= cap + 1, `niri resize cols=${c} must fit the niri pane (~${cap}); a wider value is the stale flow width`);
  }
}));

test("theme picker: top-bar button opens it; Nord recolors the terminal", () => withApp(async (page) => {
  await page.click('.topbar .bar-btn[title="Theme"]');
  await page.waitForSelector(".theme-backdrop", { state: "visible", timeout: 5000 });
  // Default is the active (current) theme at open.
  assert.equal(
    await page.evaluate(() => [...document.querySelectorAll(".theme-panel .picker-row")].findIndex((r) => r.classList.contains("active"))),
    0,
    "Default is marked active on open",
  );
  // Quick-select Nord (row 1) and apply.
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => [...document.querySelectorAll(".theme-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.body.getAttribute("data-theme") === "nord", { timeout: 3000 });
  // The terminal pane background now resolves to Nord's --term-bg (#2e3440).
  const bg = await page.evaluate(() => getComputedStyle(document.querySelector("#doc .pane")).backgroundColor);
  assert.equal(bg, "rgb(46, 52, 64)", `pane background recolors to Nord (got ${bg})`);
}));

test("reverse video renders its color via the themable var (so it follows the theme)", () => withApp(async (page) => {
  // The experiment's key discovery: reverse-video cells emit color *inline*
  // (fg/bg swapped server-side), and that inline color must be var(--cN), not a
  // hardcoded hex, or a theme swap wouldn't reach reverse cells. SGR 7 (reverse)
  // + 31 (red fg) makes the cell background palette index 1 -> background:var(--c1).
  await page.waitForFunction(() => !!document.querySelector("[id^='grid-'] .row"), { timeout: 15000 });
  const sid = await page.evaluate(() => document.querySelector("[id^='screen-']").getAttribute("data-sid"));
  await page.evaluate(async (sid) => {
    await fetch("/pty/input?sid=" + encodeURIComponent(sid), { method: "POST", body: "print $\"(ansi -e '7;31m')REVCELL(ansi reset)\"\n" });
  }, sid);
  await page.waitForFunction(
    () => [...document.querySelectorAll("[id^='grid-'] [style]")].some((e) => /var\(--c\d/.test(e.getAttribute("style") || "")),
    { timeout: 8000 },
  );
  const styled = await page.evaluate(() =>
    [...document.querySelectorAll("[id^='grid-'] [style]")].map((e) => e.getAttribute("style")).filter((s) => s.includes("var(--c"))
  );
  assert.ok(styled.length > 0, "a reverse-video cell renders its color via var(--cN), not a hardcoded hex");
}));

test("stacks switcher: top-bar breadcrumb opens it; keyboard-select switches the active stack", () => withApp(async (page) => {
  // Second stack so switching is meaningful.
  await page.evaluate(async () => { await fetch("/stack/new", { method: "POST" }); });
  await page.waitForFunction(() => document.querySelectorAll("#stacks-list ul.stacks li").length >= 2, { timeout: 8000 });
  const sel0 = await page.evaluate(() => document.querySelector("#stacks-list ul.stacks li.selected .row")?.dataset.stack);

  await page.click(".stack-crumb");
  await page.waitForSelector(".stack-backdrop", { state: "visible", timeout: 5000 });
  // Rows are the live stacks + a New stack row; exactly one stack is active.
  const actives = await page.evaluate(() => [...document.querySelectorAll(".stack-panel .picker-row")].filter((r) => r.classList.contains("active")).length);
  assert.equal(actives, 1, "the current stack is marked active");

  // Move to a different stack (row 1) and switch via Enter.
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => [...document.querySelectorAll(".stack-panel .picker-row")].findIndex((r) => r.classList.contains("sel")) === 1, { timeout: 3000 });
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".stack-backdrop")).display === "none", { timeout: 3000 });
  await page.waitForFunction((s) => document.querySelector("#stacks-list ul.stacks li.selected .row")?.dataset.stack !== s, sel0, { timeout: 5000 });
}));

test("Alt+] cycles to the next stack (works with the rail collapsed)", () => withApp(async (page) => {
  await page.evaluate(async () => { await fetch("/stack/new", { method: "POST" }); });
  await page.waitForFunction(() => document.querySelectorAll("#stacks-list ul.stacks li").length >= 2, { timeout: 8000 });
  const sel0 = await page.evaluate(() => document.querySelector("#stacks-list ul.stacks li.selected .row")?.dataset.stack);
  await page.keyboard.press("Alt+]");
  await page.waitForFunction((s) => document.querySelector("#stacks-list ul.stacks li.selected .row")?.dataset.stack !== s, sel0, { timeout: 5000 });
}));

test("Alt+\\ opens the stacks switcher", () => withApp(async (page) => {
  await page.keyboard.press("Alt+\\");
  await page.waitForSelector(".stack-backdrop", { state: "visible", timeout: 5000 });
  assert.equal(
    await page.evaluate(() => getComputedStyle(document.querySelector(".stack-backdrop")).display !== "none"),
    true,
    "Alt+\\ opens the stacks switcher",
  );
}));
