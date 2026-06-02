# ADR 0008: Leader keymap -- client-resident, two-tier, derived per-clip

## Status

Implemented. Builds on [0005](0005-mode-projected-keymap.md) (page is the mode;
server projects the keymap), [0006](0006-client-owned-cursor.md) (cursor is
client-owned and instant), and [0007](0007-mod-k-leader.md) (`mod+K` is the
leader; the clip-actions panel is its which-key hint).

`mod+K` gives the clip-actions modal continuous keyboard ownership; the panel
paints after a 300ms hint delay but key handling is identical before/after.
Panel rows carry `data-key` (`j`/`k` navigate, `r`/`d`/`o`/`J`/`K` the actions);
a key clicks its row and ownership ends, transferring to where the action lands.
`makePicker`'s separate handler for the actions panel is gone. The global
cross-stack tier is in (`n` new clip, `N` new stack, `R` rename stack, `s` sort,
`l` layout, in a "Stack" group), and the redundant navigate-mode `Alt` chords it
replaced were removed (bare `j`/`k` navigate, `Shift+J`/`Shift+K` move; stack
nav keeps `Alt+[`/`Alt+]`/`Alt+\`). Still pending: pulling content-type toggles
(Rendered/Embed) from the cursored pane as extra rows (the per-clip tier is
currently the universal actions only); plus the 0007 deferred items.

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

`mod+K` makes the clip-actions modal **own the keyboard, immediately and
continuously, until an action runs or it is dismissed.** The keymap is **two
-tier**, and the clip tier is **derived on demand from the cursored pane** --
never stored, never patched per-clip. The panel is a delayed _visual_ of a modal
that is already in control; painting it changes nothing about key handling.

1. **One owner; the panel is cosmetic.** `mod+K` transfers keyboard ownership to
   the modal at once and starts a show-timer for the panel. Ownership does not
   depend on whether the panel has painted -- there is no "leader pending vs
   panel open" split, no two keymaps. One modal handler owns every key from the
   `mod+K` press until ownership ends. `r` behaves identically before and after
   the panel appears (this is the bug being fixed: today `makePicker` only takes
   over once the panel opens, and only knows n/p/arrows/enter/esc).

2. **Any action ends ownership; ownership transfers to where the action lands.**
   A bound key runs its action and the modal releases the keyboard -- it never
   stays open after doing something. The action routes focus onward: `r`
   (rename) hands ownership to the rename modal's input; `j`/`k` (navigate) hand
   it to the newly-selected clip (cycle -> the cursor moves -> the new clip is
   focused). `Esc` / blur / click-out end ownership with no action. Pure
   in-menu navigation that invokes nothing -- arrows, `ctrl+n`/`ctrl+p` moving
   the `.sel` cursor -- keeps ownership; `Enter` invokes the selected row, which
   is an action, so it ends ownership. An unbound key is swallowed (the modal
   owns the keyboard).

3. **Two tiers.**
   - **Global / cross-stack** actions (new clip, new stack, rename stack, switch
     stack) -- constant, cursor-independent. Page-level, server-rendered once.
   - **Clip-specific** actions (rename, close; height for a terminal;
     rendered/embed toggle for a note/URL) -- depend on the cursored clip.

4. **The clip tier is derived from the cursored pane, on demand.** Intrinsic
   per-clip facts are ALREADY projected per-pane: `data-render` /
   content-type, and the conditional mini-buttons the server already renders
   (`Rendered`, `Embed`, `raw`, `Edit`). The leader reads the cursored pane at
   the moment a key fires: `document.querySelector(".pane.active")`. Because the
   cursor is instant (0006), the active pane is always current -- there is no
   slot to keep in sync, nothing patched per-clip, no race. "Which actions
   apply" is a pure function of `clip == cursor` + the clip's content-type.

5. **Reuse the buttons; do not reformalize.** Each per-pane action is the
   existing mini-button. Give each a **`data-key` attribute**; the leader
   resolves a key by `pane.querySelector('[data-key="r"]')?.click()`. The button
   stays the single source of truth -- label, `data-on:click`, and key on one
   element -- and the existing `data-on:click` JS is reused as-is. No parallel
   server-emitted action table, no per-pane keymap JSON. `data-key` is unique
   within a pane's visible action set, and the leader resolves against the
   cursored pane only, so `r` means "the active pane's r-action" -- correct,
   since the set is content-type-specific by construction.

6. **The panel groups by tier.** Global actions in one group, the cursored
   clip's actions in another, so the hint shows both and their keys work whether
   the panel is open or not.

### Why DOM, not signals (the right reason)

Not "DOM beats signals" as a style. The data the leader needs is already
projected per-pane; the leader reads it where it lives and derives the menu on
demand. That is the deletion-over-addition win: zero new state, no per-clip
namespaces, no rewrite-on-cursor slot. Storing the clip tier anywhere -- a bag
or a global slot -- would reintroduce the sync coupling 0006 removed.

## Consequences

- **One owner, continuous.** `mod+K` owns the keyboard from the press; `r`
  behaves the same whether or not the panel has painted. The
  makePicker-vs-leader split (the bug) is gone.
- **The menu follows the cursor for free.** Move the cursor (instant, 0006),
  press `mod+K`, and the clip tier reflects the new clip -- because it is read
  from the active pane at press time, not stored.
- **Net deletion.** The clip-actions path keeps ONE handler (own-keyboard +
  dispatch) instead of the leader handler plus `makePicker`'s separate
  keyHandler. Clip actions reuse the existing mini-buttons via `data-key`.
- **Scope:** only the clip-actions modal (`mod+K`) moves to this model. The
  new-clip / theme / stacks pickers keep their own `makePicker` for now.
- **Depends on the content-type model**, which is intentionally partial (serve.nu
  notes the content-type axes "arrive in later phases"). Build against what
  exists today -- terminal / note / markdown / URL / image -- not an assumed
  richer type system.

## Migration

1. `mod+K` takes keyboard ownership for the clip-actions modal at once and
   starts the panel show-timer (instead of "leader pending"). One handler owns
   keydown while active.
2. Give the per-pane action mini-buttons (`Rename`, `Close`, `Height`,
   `Rendered`/`Embed` toggles) a `data-key` attribute each.
3. Dispatch a key while owned: global keymap first (new clip/stack, rename/switch
   stack); else
   `document.querySelector(".pane.active")?.querySelector('[data-key=...]')?.click()`;
   else built-in nav (arrows/`ctrl+n`/`ctrl+p` move `.sel`, `Enter` invokes,
   `Esc` dismisses). A bound action ends ownership; nav keeps it; unbound keys
   are swallowed.
4. Delete the separate `makePicker` keyHandler for the actions panel; this one
   owned-keyboard handler replaces it. Keep `.sel` cursor + hover for mouse and
   arrow navigation.
5. Add `j`/`k` (navigate) as panel rows; group rows by tier (global vs
   this-clip) and label each with its bare key.
6. Decide later: the 0007 deferred items (pass-through escape; whether the
   leader subsumes the navigate-mode `Alt` chords).
