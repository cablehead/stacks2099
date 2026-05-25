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
      document.fonts.load('14px JetBrainsMonoNerd'),
      document.fonts.load('bold 14px JetBrainsMonoNerd'),
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
    const probe = document.createElement('span');
    probe.className = 'cell-probe';
    probe.textContent = 'M'.repeat(80);
    document.body.appendChild(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    return { w: rect.width / 80, h: rect.height };
  }

  let cell = measureCell();

  function dims() {
    // Width from the container's content box (clientWidth excludes the
    // reserved scrollbar gutter). Height from the parent so reading it
    // doesn't feed back through the explicit height we set on screen.
    // With fixedRows the pane is a constant height (continuous-document
    // panes); otherwise rows fill the available height.
    const availW = screen.clientWidth || screen.parentElement?.clientWidth || window.innerWidth;
    const availH = screen.parentElement?.clientHeight || window.innerHeight;
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
    screen.style.height = Math.round(rows * cell.h) + 'px';
  }

  // Auto-stick-to-bottom. A suppression flag distinguishes our programmatic
  // scroll (set just before writing scrollTop, consumed by the synchronous
  // scroll event) from a real user scroll.
  let stick = true;
  let suppress = false;
  screen.addEventListener('scroll', () => {
    if (suppress) {
      suppress = false;
      return;
    }
    stick = screen.scrollHeight - screen.scrollTop - screen.clientHeight < 8;
  });
  new MutationObserver(() => {
    if (stick && screen.scrollTop !== screen.scrollHeight - screen.clientHeight) {
      suppress = true;
      screen.scrollTop = screen.scrollHeight;
    }
  }).observe(grid, { childList: true, subtree: true, characterData: true });

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

  window.addEventListener('resize', () => reflow(false));
  // Catch pane-geometry changes that don't fire window resize: the sidebar
  // or canvas resizing in the sessions surface, topbar growth, etc.
  if (screen.parentElement && typeof ResizeObserver !== 'undefined') {
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
