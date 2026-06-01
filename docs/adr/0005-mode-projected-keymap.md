# ADR 0005: Mode-projected keymap

## Status

Accepted, partially implemented. Supersedes [0004](0004-keyspace.md).

Done: the focus-mode carve-out (a focused clip owns every key except `mod+Enter`
and `mod+K`); key-buffer forwards Option/AltGr-composed characters literally;
Alt chords are navigate-only (leave-then-navigate). This fixed the `|`/`~`/`\`
swallowing.

Still pending (migration steps 1-2, 4, 6 below): moving `mode` into the
projected stream, rendering `data-keymap` per mode from a single table,
converting the modals to modes, and deleting `comboKey`/`makePicker`/the client
`mode` variable. The keymap is still a static client-side map today; the
carve-out is enforced in the capture handler rather than by what the server
projected.

## Context

ADR 0004 made app chords global `Alt` bindings, dispatched client-side: one
static all-modes `data-keymap`, read by a capture-phase handler (`comboKey`)
that branches on mode in JS and `stopPropagation`s a match. Modals bolt on their
own imperative `keydown` listeners (`makePicker`). Three problems followed.

1. **International keyboards break.** `Alt`/Option is the character-compose
   modifier on most non-US layouts. `comboKey` normalizes via `e.code`, so an
   Option-composed character is reinterpreted as an app chord and swallowed. On
   a Danish layout `Option+I` (`|`) is sent to the pty as Meta-pipe, and the
   `~`/`Å` dead keys (physical `BracketRight`/`BracketLeft`) match
   `Alt+]`/`Alt+[` and cycle stacks instead of typing. A focused terminal never
   sees the character.
2. **Dispatch is fragmented.** `comboKey`, `makePicker`, and `key-buffer` each
   decide things in JS, each with its own mode assumptions.
3. **Mode is client state.** It lives in a `let mode` plus a `body.mode-*`
   class, not in the projected stream, so it is not the source of truth ADR 0003
   established for everything else.

The `stacks.nu` experiment prototyped the alternative and is the reference:

- `keys.js` -- one delegated `keydown` listener. Builds the combo from `e.key`
  (no `e.code`), looks it up in `main[data-keymap]`, and `if (!id) return;` --
  unbound keys are untouched. ~60 lines, no mode logic.
- `KEY_BINDINGS` table in `serve.nu` -- one row per binding with a `modes`
  column (`[combo, action, keys, label, modes]`). The keymap and the status bar
  are BOTH filtered from this table per mode, so they cannot drift.
- `actions-for [mode ctx]` -- the per-mode action registry (id -> JS string),
  rendered into `data-actions`.
- `action-panel.js` -- a modal's internal nav via a node-scoped `data-init`
  mount that self-cleans when idiomorph removes the node.

The decisive detail: in `stacks.nu`, **focus mode has exactly one binding** --
`cmd+enter -> clip.unfocus`. Every other key falls through to the focused clip.
That is the model below, already proven; we widen the carve-out slightly.

## Decision

Mode is server state, projected. The server renders the active mode's keymap
into `<main data-keymap>`; one mode-agnostic listener runs whatever is there;
**unbound keys pass through untouched.**

1. **Mode is projected.** The projection computes the current mode (navigate /
   focus / a specific modal) from the stream.
   `<main data-keymap=...
   data-signals-mode=...>` reflects it. A mode change
   is a frame, so it replays and multi-clients like the rest of the state.
2. **One keymap, one listener.** A combo is matched against `main[data-keymap]`
   and POSTed to the action's endpoint. No mode branching in the client; the
   listener never needs to know the mode because the server already put only the
   right bindings on the page. The combo is built from `e.key` (no `e.code`
   normalization), so a composed character is its literal self.
3. **Unbound keys are untouched.** `if (!action) return;` -- no
   `preventDefault`, no `stopPropagation`. The keystroke reaches whatever is
   focused as if no keybinding layer existed.
4. **Focus mode is raw passthrough plus a tiny carve-out.** When a clip is
   focused the keymap holds ONLY two bindings: `mod+Enter` (leave focus) and
   `mod+K` (clip-actions modal). Every other key MUST reach the focused clip --
   a terminal's pty or a note's textarea -- untouched. This is what makes the
   i18n failures impossible: in focus mode there is no handler on the page for
   `|`/`~`/`\`, so nothing can intercept them. Both carve-out chords are on
   `mod` (Cmd/Ctrl), which key-buffer already drops before the pty, so they cost
   the focused clip nothing and never collide with Option/AltGr composition.
   Cross-clip movement is **leave-then-navigate**: `mod+Enter` to drop to
   navigate, `j`/`k` to move, `mod+Enter` to re-focus -- matching `stacks.nu`,
   rather than keeping a next/prev chord live under focus.
5. **A modal is a mode.** Opening a modal swaps the keymap entirely; closing
   restores the base map. App chords and open/close go through the projected
   keymap. A modal's _internal_ nav (arrow/enter/filter, the `.sel` cursor) may
   use a listener **scoped to the modal node via `data-init`**, which
   self-cleans when idiomorph removes the node -- not a global listener wired on
   a signal edge (today's `makePicker`). That is the difference: the modal owns
   its keys for exactly as long as its DOM exists, with no edge bookkeeping.

### Carve-out chords

The carve-outs must not be characters any supported layout composes with
Option/AltGr, or we reintroduce the bug we are fixing. `Alt+letter` does not
qualify. The carve-out is exactly two `mod` chords, both of which `key-buffer`
already drops before the pty:

| Action             | Chord       | Why safe over a focused clip                                |
| ------------------ | ----------- | ----------------------------------------------------------- |
| Leave focus        | `mod+Enter` | key-buffer drops Meta; pty can't tell Ctrl+Enter from Enter |
| Clip-actions modal | `mod+K`     | key-buffer drops Meta                                       |

Next/prev clip is deliberately NOT in the focus carve-out. `Alt+J`/`Alt+K` is
the colliding class (Option compose), and adding a live movement chord widens
the focus keymap past the minimum. Decision: **leave-then-navigate**, matching
`stacks.nu` -- `j`/`k` live only in navigate mode; from a focused clip you
`mod+Enter` out, move, and `mod+Enter` back. This keeps the focus keymap at two
bindings and the i18n guarantee absolute.

### Two layers, both required

The keymap fixes the _interception_ axis. The pty input path is the other axis:

- **App keymap (this ADR):** mode-scoped, unbound keys untouched.
- **pty `key-buffer`:** when a key falls through in focus mode, key-buffer
  translates it to pty bytes. It must send Option-composed printables
  **literally** (`ev.key`), not as `ESC + char`. Treat Option as Meta only
  behind an explicit opt-in (xterm.js's `macOptionIsMeta`). Without this, `|`
  still arrives as Meta-pipe even once the keymap stops intercepting it.

## Consequences

- **The i18n failures vanish by construction.** Focus mode intercepts nothing
  outside the carve-out, and key-buffer sends composed characters literally.
- **One source of truth.** The keymap on the page drives both dispatch and the
  status bar; the server owns it per mode; the live UI is the rationale list.
- **Less client code.** Retire `comboKey` (the `e.code` normalization and JS
  mode checks) and `makePicker` (per-modal `addEventListener`). The New /
  Actions / Theme / Stacks modals shrink to a server-swapped keymap plus a
  projected `.sel`.
- **Cost: a POST per app action.** Terminals already round-trip every keystroke,
  so this only adds latency to chords, which is acceptable.

### Migration

1. Move `mode` into the stream and compute it in the projection.
2. Render `data-keymap` per mode (a `keymaps` table keyed by mode, like
   `stacks.nu`).
3. Port `keys.js`: one delegated listener, `e.key` combos, unbound -> untouched.
4. Convert the modals to modes: opening swaps the keymap, rows POST, internal
   nav via a node-scoped `data-init` mount. Delete `makePicker`.
5. Fix `key-buffer`'s Meta handling (composed printables sent literally).
6. Delete `comboKey` and the client `mode` variable.
