# ADR 0008: Leader keymap -- client-resident, two-tier, derived per-clip

## Status

Draft. Builds on [0005](0005-mode-projected-keymap.md) (page is the mode; server
projects the keymap), [0006](0006-client-owned-cursor.md) (cursor is
client-owned and instant), and [0007](0007-mod-k-leader.md) (`mod+K` is the
leader; the clip-actions panel is its which-key hint).

## Context

0007 made `mod+K` a leader but left two seams:

1. **The open panel and the leader are two keymaps.** `makePicker` hard-codes
   the panel's keys (n/p/arrows/enter/esc) in client JS and swallows everything
   else. The leader knows `r`/`j`/`k`/`d`/`o`. So once the panel opens, bare `r`
   does nothing -- `makePicker` eats it. "Menu's up but the keys don't work."
2. **The leader's command set is fixed**, but clip commands depend on the clip:
   a markdown note has a rendered/edit toggle, a URL has an embed toggle, a
   terminal has height, an image has neither. The set must follow the cursor.

The instinct to chase -- and reject -- is a per-clip signal bag, or a global
`$leaderActions` slot rewritten on cursor move. The latter is the
rewrite-a-global-slot-on-selection pattern that caused the morph race 0005/0006
spent two ADRs unwinding. `label`/`noteEditing`/`focusedDims` use it; it is a
smell we removed, not a grain to emulate. `focusedDims` in particular went
_client-side_ precisely because 0006 deleted the server-projected per-clip
version -- so it is evidence against storing derived per-clip state, not for it.

## Decision

The leader keymap is **always live on the client** and **two-tier**, and the
clip tier is **derived on demand from the cursored pane** -- never stored,
never patched per-clip.

1. **The keymap is always present; the panel is cosmetic.** `mod+K` enters
   leader-pending (0007). The next key resolves against the live keymap whether
   or not the panel has appeared. The panel is a delayed visualization of the
   already-live keymap -- a which-key hint -- not a separate menu with its own
   bindings. Bare `r` after the panel opens completes the same leader.
   (`makePicker`'s hard-coded handler goes away; there are no longer two
   keymaps to keep in sync.)

2. **Two tiers.**
   - **Global / cross-stack** actions (new clip, new stack, rename stack, switch
     stack) -- constant, cursor-independent. Page-level, server-rendered once.
   - **Clip-specific** actions (rename, close; height for a terminal;
     rendered/embed toggle for a note/URL) -- depend on the cursored clip.

3. **The clip tier is derived from the cursored pane, on demand.** Intrinsic
   per-clip facts are ALREADY projected per-pane: `data-render` /
   content-type, and the conditional mini-buttons the server already renders
   (`Rendered`, `Embed`, `raw`, `Edit`). The leader reads the cursored pane at
   the moment a key fires: `document.querySelector(".pane.active")`. Because the
   cursor is instant (0006), the active pane is always current -- there is no
   slot to keep in sync, nothing patched per-clip, no race. "Which actions
   apply" is a pure function of `clip == cursor` + the clip's content-type.

4. **Reuse the buttons; do not reformalize.** Each per-pane action is the
   existing mini-button. Give each a **`data-key` attribute**; the leader
   resolves a key by `pane.querySelector('[data-key="r"]')?.click()`. The button
   stays the single source of truth -- label, `data-on:click`, and key on one
   element -- and the existing `data-on:click` JS is reused as-is. No parallel
   server-emitted action table, no per-pane keymap JSON. `data-key` is unique
   within a pane's visible action set, and the leader resolves against the
   cursored pane only, so `r` means "the active pane's r-action" -- correct,
   since the set is content-type-specific by construction.

5. **The panel groups by tier.** Global actions in one group, the cursored
   clip's actions in another, so the hint shows both and their keys work whether
   the panel is open or not.

### Why DOM, not signals (the right reason)

Not "DOM beats signals" as a style. The data the leader needs is already
projected per-pane; the leader reads it where it lives and derives the menu on
demand. That is the deletion-over-addition win: zero new state, no per-clip
namespaces, no rewrite-on-cursor slot. Storing the clip tier anywhere -- a bag
or a global slot -- would reintroduce the sync coupling 0006 removed.

## Consequences

- **One keymap, always live.** `mod+K r` works before the panel; `r` works once
  it is open. The makePicker-vs-leader split (the bug) is gone.
- **The menu follows the cursor for free.** Move the cursor (instant, 0006),
  press `mod+K`, and the clip tier reflects the new clip -- because it is read
  from the active pane at press time, not stored.
- **Net deletion.** `makePicker`'s hard-coded key handler is replaced by a
  lookup over the live keymap; clip actions reuse the existing mini-buttons via
  `data-key`.
- **Depends on the content-type model**, which is intentionally partial (serve.nu
  notes the content-type axes "arrive in later phases"). Build against what
  exists today -- terminal / note / markdown / URL / image -- not an assumed
  richer type system.

## Migration

1. Give the per-pane action mini-buttons (`Rename`, `Close`, `Height`,
   `Rendered`/`Embed` toggles) a `data-key` attribute each.
2. Add a global keymap (new clip, new stack, rename/switch stack) at page level.
3. Leader dispatch: on the second key, look up global first; else
   `document.querySelector(".pane.active")?.querySelector('[data-key=...]')?.click()`.
4. Delete `makePicker`'s hard-coded key handler; the open panel is driven by the
   same live leader (bare key completes it). Keep the `.sel` cursor / hover for
   mouse + arrow navigation if still wanted, but keys route through the leader.
5. Group the panel rows by tier (global vs this-clip) and label each with its
   bare key.
6. Decide later: the 0007 deferred items (pass-through escape; whether the
   leader subsumes the navigate-mode `Alt` chords).
