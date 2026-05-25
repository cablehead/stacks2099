# ADR 0003: Server-Rendered HTML Projection

Supersedes [0001](0001-focus-owner-model.md) and
[0002](0002-customize-vendored-ghostty-web.md).

## Context

Until now the browser ran a full VT emulator: ghostty-web (a WASM + canvas
build of Ghostty's terminal) parsed the pty byte stream and painted cells.
The server kept a parallel `wezterm_term::Terminal` only as a snapshot
source so a reattach could replay clean. Two terminals modelling the same
screen, one in Rust and one in WASM.

That arrangement carried recurring costs: a ~400KB WASM blob vendored into
the repo (ADR 0002 documented patching it in-tree for the scrollbar
gutter); a canvas with no real DOM, so selection, accessibility, and
"inspect the text" were all bespoke; and a focus model (ADR 0001) built
around keeping the xterm-style textarea focused.

The server already holds the canonical screen in wezterm-term. If the
browser renders *that* instead of re-deriving it, the second emulator
disappears.

## Decision

The browser does not emulate a terminal. It renders an HTML cell grid that
the server produces from its wezterm-term screen, and morphs it in place
with Datastar.

- **`pty view`** (http-nu) streams the visible screen + scrollback as
  `<div id="grid">` with one `<div class="row" id="r-N">` per line, cells
  run-length encoded into `<span>` runs. Frames are
  `datastar-patch-elements` SSE events; idiomorph keeps stable rows and
  rewrites only what changed. A per-sid condvar wakes subscribers when the
  reader thread advances the terminal; renders coalesce on a 16ms window.
- **Input** is the irreducible browser half: a `<key-buffer>` web component
  translates `KeyboardEvent`s to pty bytes and POSTs `/pty/input`, shows
  in-flight keys as ghosts, and handles copy/paste. This is "events up";
  the grid is "props down".
- **Server-driven display state** (dimensions, OSC title) rides as
  `datastar-patch-signals` (`termCols/termRows/termTitle`), bound
  declaratively. The client measures the monospace cell to compute
  cols/rows and POSTs `/pty/resize`.
- **Alignment** depends on uniform glyph advance, so the grid uses a single
  complete monospace face (vendored JetBrains Mono NL Nerd Font, Mono
  variant). No multi-font fallback: a fallback would advance box-drawing
  glyphs at a different width and break columns.

### Why 0001 is superseded

The focus-owner model existed because the terminal was a focusable element
that had to *hold* focus to receive keys. key-buffer listens on `window`,
so the terminal owns no focus at all -- keystrokes reach the pty regardless
of `document.activeElement`. The only element that legitimately takes focus
is the rename-modal input, and the modal's own `data-effect` focuses it.
The policy collapses to one rule, enforced where the key is read:
key-buffer ignores keydowns whose target is an editable element. The
`focusOwner()/enforceFocus()` machinery and the `:focus-within` dimming are
gone.

### Why 0002 is superseded

ADR 0002 was about patching the vendored ghostty-web build (the scrollbar
gutter overlapped text on its canvas). There is no vendored ghostty-web
anymore, and scrolling is a native browser scrollbar on the `#screen`
container. The decision and its maintenance burden no longer apply.

## Consequences

- **No WASM, no second emulator.** The vendored ghostty-web files are
  deleted. The client is HTML + Datastar + one small input component.
- **Text is real DOM.** Browser selection, find, accessibility, and "copy
  what you see" work without bespoke code. Trailing-cell padding is the one
  wrinkle, handled by a trim-on-copy listener.
- **Latency profile is unchanged.** Both models already round-tripped every
  keystroke to the pty for echo; there was never local echo to lose. The
  render step is HTML morph instead of canvas blit -- comparable on
  localhost, and brotli on the SSE stream keeps the morph payload small
  (200:1 is typical for this shape of HTML).
- **Output bursts cost server CPU + DOM morph** rather than canvas writes.
  Coalescing renders at 16ms bounds it; a `cat` of a huge file is the
  stress case to watch.
- **Glyph coverage is now our responsibility.** A program emitting a glyph
  the vendored font lacks gets browser substitution and a width drift.
  Mitigation: the Nerd Font is "completely fleshed out" (~11.7k glyphs).
- **Both surfaces share the projection.** Single-pane (`index.html`) and
  multi-session (`sessions.html`) use the same `grid.css` + `terminal.js` +
  `key-buffer.js`; the session surface adds the sidebar/canvas/keymap shell
  around the same `#screen`/`#grid` pane.
