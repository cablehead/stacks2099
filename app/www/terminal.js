// terminal.js: shared mechanics for a projection terminal pane.
//
// The page owns sid acquisition and opens the /pty/view SSE declaratively
// (Datastar data-effect). This module owns the browser-side concerns that
// don't belong to any framework: measuring the monospace cell, pinning the
// scroll container to a whole number of rows, auto-sticking to the bottom,
// and emitting resize requests when the pane geometry changes.

/** Load the vendored terminal font before any measurement. An @font-face
 *  only loads when first used, so document.fonts.ready alone can resolve
 *  before it arrives -- then we'd measure a fallback metric. */
export async function ensureTermFont() {
  try {
    await Promise.all([
      document.fonts.load("14px JetBrainsMonoNerd"),
      document.fonts.load("bold 14px JetBrainsMonoNerd"),
    ]);
  } catch {}
  await document.fonts.ready;
}

/** Mount terminal mechanics on a #screen / #grid pair.
 *  - screen:   the scroll container (absolutely positioned, fills its pane)
 *  - grid:     the morph target inside screen (server-rendered rows)
 *  - onResize: (cols, rows) => void, called on the initial measure and
 *              whenever the measured geometry changes (debounced).
 *  Returns { initialDims, syncNow } -- syncNow() forces a re-measure and a
 *  fresh onResize emit (used after a session switch so the newly-focused
 *  pty gets sized to the current pane). */
export function mountTerminal({ screen, grid, onResize, fixedRows }) {
  function measureCell() {
    const probe = document.createElement("span");
    probe.className = "cell-probe";
    probe.textContent = "M".repeat(80);
    document.body.appendChild(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    return { w: rect.width / 80, h: rect.height };
  }

  let cell = measureCell();

  function dims() {
    // Width from the container's content box (clientWidth excludes the
    // reserved scrollbar gutter). Height from the parent so reading it
    // doesn't feed back through the explicit height we set on screen --
    // but the parent (.pane) also contains the header, so we subtract
    // siblings preceding `screen` to get the space actually available to it.
    // With fixedRows the pane is a constant height (continuous-document
    // panes); otherwise rows fill the available height (niri layout).
    const availW = screen.clientWidth || screen.parentElement?.clientWidth ||
      window.innerWidth;
    const parent = screen.parentElement;
    let headOffset = 0;
    if (parent) {
      for (
        let s = parent.firstElementChild;
        s && s !== screen;
        s = s.nextElementSibling
      ) {
        headOffset += s.offsetHeight || 0;
      }
    }
    const availH = (parent?.clientHeight || window.innerHeight) - headOffset;
    return {
      // Low floor so a deliberately narrow pane (Alt+O width cycle) gets a
      // correspondingly narrow pty rather than overflowing a clamped width.
      cols: Math.max(2, Math.floor(availW / cell.w)),
      rows: fixedRows ? fixedRows : Math.max(5, Math.floor(availH / cell.h)),
    };
  }

  // Pin the scroll container to a whole number of rows tall. Any sub-row
  // remainder sits below it (filled by the page background) rather than
  // clipping a half-row at the top when scrolled to the bottom.
  function applyHeight(rows) {
    screen.style.height = Math.round(rows * cell.h) + "px";
  }

  // Auto-stick-to-bottom plus scroll anchoring. `stick` means "pinned to the
  // live prompt"; it must flip only on a genuine user scroll. The trap is that
  // rebuilding the grid (a morph clamping scrollTop, our own anchor/stick writes)
  // also fires scroll events -- and reading those as user intent is what cleared
  // `stick` on a reconnect, leaving the view stuck at the scrollback top. The
  // `mutating` window swallows every scroll event a mutation triggers, so `stick`
  // survives rebuilds and only real user scrolls (which fire on their own) change
  // it. That makes both cases idiomatic: at the bottom you stay pinned across a
  // reconnect/resize; scrolled up you keep your place.
  let stick = true;
  let mutating = false;
  let mutatingClear = null;
  function beginMutating() {
    mutating = true;
    clearTimeout(mutatingClear);
    // Clear on the next task. A mutation's scroll events fire in the rendering
    // step before then, so they land inside the window; a later user scroll does
    // not. A genuine scroll within a few ms of a frame is the only thing this can
    // miss, which is harmless (the next scroll re-reads the position).
    mutatingClear = setTimeout(() => {
      mutating = false;
    }, 0);
  }
  screen.addEventListener("scroll", () => {
    if (mutating) return;
    stick = screen.scrollHeight - screen.scrollTop - screen.clientHeight < 8;
  });

  // Morph HUD: each /pty/view SSE patch arrives as one synchronous morph
  // pass, so one MutationObserver callback batch == one server frame. We
  // count the .row elements actually shipped by that patch, broken down:
  //
  //   +N  rows added at the bottom    (server emitted a mode:append patch)
  //   -M  rows removed off the top    (server emitted a mode:remove patch)
  //   ~K  rows rewritten in place     (default-outer morph; seqno advanced)
  //
  // Under seqno-diff the server only ships rows that actually changed, so
  // +N -M ~K *is* "lines shipped by this patch". A steady-state keystroke
  // should show a handful (cursor row + prompt repaint); a value near the
  // scrollback cap would mean the diff path regressed and we're shipping
  // the whole grid again.
  const pane = screen.closest(".pane");
  const head = pane?.querySelector(".pane-head");
  let hud = null;
  if (head) {
    hud = document.createElement("span");
    hud.className = "grid-hud";
    hud.title =
      "rows shipped by the last server patch: +added -removed ~changed (avg total)";
    hud.textContent = "+0 -0 ~0";
    head.appendChild(hud);
  }
  let hudAvg = 0;
  function bumpHud(adds, removes, changes) {
    if (!hud) return;
    const total = adds + removes + changes;
    hudAvg = hudAvg * 0.7 + total * 0.3;
    hud.textContent = `+${adds} -${removes} ~${changes} (avg ${
      hudAvg.toFixed(0)
    })`;
  }

  new MutationObserver((muts) => {
    beginMutating();

    // Count this frame's row churn (one batch == one server patch) for the HUD.
    let adds = 0;
    let removes = 0;
    const changedIds = new Set();
    for (const m of muts) {
      if (m.type === "childList") {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1 && n.classList?.contains("row")) adds++;
        }
        for (const n of m.removedNodes) {
          if (n.nodeType === 1 && n.classList?.contains("row")) removes++;
        }
        // A childList change inside an existing .row means its content was
        // rewritten by an outer-morph patch.
        const row = m.target.nodeType === 1 ? m.target.closest?.(".row") : null;
        if (row && row.isConnected) changedIds.add(row.id);
      } else {
        // characterData / attribute change on a descendant of a .row.
        const el = m.target.nodeType === 1 ? m.target : m.target.parentElement;
        const row = el?.closest?.(".row");
        if (row && row.isConnected) changedIds.add(row.id);
      }
    }

    if (stick) {
      // Pinned to the bottom: follow new output (and snapshots) down to the
      // prompt. A reconnect at the bottom lands here because `stick` survived the
      // rebuild (the mutating guard above keeps the scroll events it fired from
      // clearing the flag).
      if (screen.scrollTop !== screen.scrollHeight - screen.clientHeight) {
        screen.scrollTop = screen.scrollHeight;
      }
    }
    // else: the user is reading scrollback. We deliberately leave scrollTop
    // alone so CSS scroll anchoring (overflow-anchor on #screen, set in grid.css)
    // holds the line under their eye as rows trim off the top -- appends below
    // the viewport don't move it. Anchoring needs us NOT to touch scrollTop, so
    // there's no manual adjustment here.

    if (adds || removes || changedIds.size) {
      bumpHud(adds, removes, changedIds.size);
    }
  }).observe(grid, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
  });

  const initialDims = dims();
  applyHeight(initialDims.rows);
  let lastKey = `${initialDims.cols}x${initialDims.rows}`;

  let timer;
  function reflow(force) {
    clearTimeout(timer);
    timer = setTimeout(() => {
      cell = measureCell();
      const d = dims();
      applyHeight(d.rows);
      const key = `${d.cols}x${d.rows}`;
      if (!force && key === lastKey) return;
      lastKey = key;
      onResize?.(d.cols, d.rows);
    }, 80);
  }

  // A ResizeObserver on the pane is the single geometry driver. It fires on any
  // box change -- a window resize (the pane width tracks the viewport), the
  // sidebar collapsing, topbar growth, the zoom float -- so a separate window
  // "resize" listener would be redundant.
  if (screen.parentElement && typeof ResizeObserver !== "undefined") {
    new ResizeObserver(() => reflow(false)).observe(screen.parentElement);
  }

  return {
    initialDims,
    syncNow() {
      cell = measureCell();
      const d = dims();
      applyHeight(d.rows);
      lastKey = `${d.cols}x${d.rows}`;
      onResize?.(d.cols, d.rows);
      return d;
    },
    // Change the pane's fixed row count (Alt+O height cycle) and reflow: the
    // scroll container grows/shrinks to the new height and the pty is resized
    // to match. Cols are unchanged (width is still pane-driven).
    setFixedRows(n) {
      fixedRows = n;
      cell = measureCell();
      const d = dims();
      applyHeight(d.rows);
      lastKey = `${d.cols}x${d.rows}`;
      onResize?.(d.cols, d.rows);
      return d;
    },
  };
}
