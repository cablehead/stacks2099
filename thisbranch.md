# Spike: replace wezterm-term with libghostty-vt

Evaluation only. No production code changed on this branch. Decision: **stay
with wezterm-term for now.**

## What libghostty-vt is

`libghostty-vt` (the crate) is a Rust binding, not the engine. Two layers:

- The engine is Ghostty's VT library, extracted from `ghostty-org/ghostty` (a
  `ghostty/vt.h` C API). That part is official Ghostty.
- The crate (`github.com/uzaaft/libghostty-rs`) is generated FFI plus ~6,600
  lines of safe wrappers, written by one person (Uzair Aftab / Uzaaft).

So: official Ghostty internals, wrapped by an independent community contributor.
It is not under the `ghostty-org` org.

## Maturity

- Version `0.1.1`, first published 2026-03-28. Repo created 2026-03-21.
- 335 stars, 26 forks, ~6,850 downloads, actively maintained, single contributor.
- Pre-1.0. README is explicit: bindings move with the pinned Ghostty source,
  no API compatibility guarantee across revisions. No release tags.

## Build cost

Requires Zig on PATH (the `-sys` build script fetches and compiles Ghostty from
a pinned commit, then statically links `libghostty-vt.a`).

- The pinned ghostty commit needs **Zig 0.15.2** (the README says "0.15.x";
  0.15.1 fails the version gate with a compile error).
- Cold build of the VT dep: ~40s (Zig compiles ghostty). Wezterm is pure cargo.
- Warm rebuild after editing our Rust: ~1s. The Zig artifact is cached in
  `target/`; only a clean build, CI, or a pinned-commit bump pays the Zig cost.
- Disk: +483 MB in the build dir, 33 MB static `.a`.
- CI impact: every runner (ubuntu/macos/windows) would need Zig 0.15.2
  installed, and clean CI builds get ~40s slower.

## API parity

Verified the rendering and I/O primitives against the real library with a
standalone probe that drives a ghostty `Terminal` and renders cells to the same
HTML grid `pty.rs` emits. Bold/faint/italic/underline/reverse flags,
16-palette-to-CSS-class, 256/truecolor-to-inline-rgb, wide CJK glyphs,
graphemes, cursor position, and DA1 auto-replies all came out correct.

Direct equivalents:

| pty.rs today (wezterm)            | libghostty-vt                          |
| --------------------------------- | -------------------------------------- |
| `advance_bytes`                   | `vt_write`                             |
| `resize(TerminalSize)`            | `resize(cols, rows)`                   |
| `cursor_pos()`                    | `cursor_viewport()` / `cursor_x/y()`   |
| `is_alt_screen_active()`          | `active_screen() == Alternate`         |
| SGR attrs, fg/bg ColorAttribute   | `style()` flags + `StyleColor`         |
| OSC 7 cwd `get_current_dir()`     | `pwd()`                                |
| OSC 8 links `hyperlink().uri()`   | `has_hyperlink()` + `hyperlink_uri()`  |
| DA/DSR replies via SharedWriter   | `on_pty_write` callback                |
| `screen_to_text` snapshot         | row/cell iterators                     |

## The three gaps that make it not a drop-in

1. **Multi-subscriber diffing.** `pty view` supports many concurrent SSE
   viewers, each with its own diff cursor. That works because wezterm's
   `current_seqno()` + `get_changed_stable_rows(range, since)` is a pure read
   against a monotonic counter. Ghostty's change tracking is mutable
   consume-once dirty bits (`Dirty::Partial/Full`, per-row `dirty()` /
   `set_dirty()`), built for one renderer. N independent viewers don't fit it.
   We would rebuild a seqno-style model ourselves (per-row content hashes) or
   send full frames to every viewer.

2. **Scrollback addressing + stable row ids.** We push all retained rows (up to
   3000) to the browser and address them by `StableRowIndex` to compute
   trims/appends. Ghostty's `RenderState` is viewport-only (rows = visible
   rows). Scrollback is reachable only via per-cell `grid_ref(Point::Screen)`
   calls or `TrackedGridRef` anchors. Full-buffer rendering becomes chattier
   (FFI per cell) and stable ids become our bookkeeping, not the library's.

3. **Implicit (bare) URL detection.** We lean on wezterm-surface's `Rule` set +
   `Line::apply_hyperlink_rules` so a printed `http://...` becomes clickable.
   libghostty-vt has none of this; Ghostty does URL regex in its app layer, not
   the VT lib. We would reimplement URL scanning over rendered text. OSC 8
   explicit links are unaffected.

Smaller note: ghostty split a `woman-astronaut` ZWJ emoji into two cells where
wezterm keeps it as one grapheme cluster. Minor rendering-model difference, but
real.

## What would be nicer with ghostty's API

- `on_pty_write` callback beats threading a `SharedWriter` Mutex through the
  terminal for auto-replies.
- Pre-resolved RGB per cell (`fg_color()`/`bg_color()` flatten palette+style)
  where wezterm makes us resolve the palette by hand. The raw `StyleColor` is
  still available, so the themable-16 CSS-class path survives.
- Typed callbacks for title/bell/color-scheme/device-attributes.
- `TrackedGridRef` is a nice primitive for following a cell through scrollback
  if we ever want anchored selection.

## Decision

Parity on the rendering and I/O primitives is reachable, but the live-view
architecture (`pty view`) is built directly on wezterm's seqno + stable-id
model, and ghostty offers a viewport dirty-bit model instead. A faithful port
means re-implementing that diff layer, reinstating bare-URL detection, and
carrying a Zig toolchain in CI for a pre-1.0, single-maintainer binding.

Not worth it now. Revisit if libghostty-vt reaches 1.0 / a stable C API, or if
we rework `pty view` for other reasons and the seqno coupling loosens anyway.

## Reproducing the spike

- Bindings cloned to `~/libghostty-rs` (pinned ghostty `bfe633a`).
- Rendering probe at `~/gv_probe` (`cargo run` with Zig 0.15.2 on PATH).

Both live outside the repo so the tree stays clean.
