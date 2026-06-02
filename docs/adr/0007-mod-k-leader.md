# ADR 0007: mod+K leader for clip commands

## Status

Draft. Builds on [0005](0005-mode-projected-keymap.md) (a focused clip owns
every key but a tiny carve-out) and [0006](0006-client-owned-cursor.md) (the
cursor is client-owned and instant).

## Context

ADR 0005 fixed the i18n key-swallowing by giving a focused clip every key raw,
with only `mod+Enter` (leave) and `mod+K` (clip actions) carved out. That left
one thing unsolved: **navigating between clips while a clip stays focused.** The
old `Alt+J`/`Alt+K` had to go -- on non-US layouts Alt is the compose modifier,
so those chords collided with typing `~`, `|`, accented characters. We shipped
leave-then-navigate (`mod+Enter` out, `j`/`k`, `mod+Enter` back) as the interim.

The hunt for a single chord that could pierce a focused terminal kept failing.
A safe pierce key must be all three of:

- not eaten by the OS/browser (rules out most `Cmd`+letter -- Cmd+T/W/R/L/N...),
- not a character-compose key (rules out all `Alt`/Option combos),
- not wanted by the terminal/TUI (rules out bare keys, `Ctrl`+letter readline
  codes, and -- per a separate finding -- `Cmd`/`Opt`+arrows, which TUIs want).

That intersection is nearly empty, and every survivor is contended or
platform-specific. The realization: a multiplexer hosting a terminal has exactly
this conflict, and the established answer is not a chord -- it is a **leader**.
tmux (`Ctrl+B`), screen (`Ctrl+A`), zellij all carve out one prefix and namespace
their commands behind it. We are a terminal multiplexer in a browser.

## Decision

**`mod+K` is the leader for clip commands.** It is already the one key proven
safe to pierce a focused clip (Meta -- `key-buffer` drops it before the pty, it
never reaches a TUI) and it already opens the clip-actions panel. We fold the
leader and that panel into one mechanism: **the panel is the leader's hint.**

1. **`mod+K` enters a transient "leader pending" state** (client-local,
   instant, no server round-trip -- the easy kind of mode). It starts a short
   hint-delay timer.
2. **A second key within the window runs that command** and cancels the timer;
   the panel never shows. `mod+K j` / `mod+K k` move the cursor (via 0006's
   instant `setCursor`), `mod+K r` rename, `mod+K d` close, etc. A power user
   types the pair faster than the delay and sees nothing flash.
3. **If the delay elapses with no second key, the panel opens** (today's
   behavior) and acts as the visible cheatsheet: its rows are the leader's
   command set. So the keymap and the panel are one table -- rows carry both the
   key and the action, and `j`/`k` (navigate) are just two more rows.
4. **The second key does not reach the pty.** While pending, the leader handler
   intercepts the next key; `key-buffer` never forwards it.
5. **An unbound second key is forgiving:** it opens the panel (rather than
   no-op), so a mistyped leader still lands somewhere useful.

This composes with, rather than replaces, leave-then-navigate: `mod+Enter` still
fully leaves to navigate mode. The leader is the _pierce-while-focused_ path.

### Why mod+K specifically

- **Safe by construction.** Meta combos return null from `keyEventToInput`, so
  `key-buffer` sends nothing to the pty for `mod+K` -- a focused TUI cannot lose
  it. This is the same property that makes `mod+Enter`/`mod+K` the ADR 0005
  carve-out.
- **No new globally-safe chord needed.** Every command hangs off the one prefix,
  so we never have to find N uncontended chords -- the problem that stalled us.
- **The hint already exists.** The clip-actions panel is the which-key menu; we
  do not build a new overlay, we delay the one we have.

### The hint delay

The delay is "how long before the panel appears if you pause" -- NOT a window you
must beat to chain keys. A human key-to-key gap is ~80-150ms, so a 20ms delay
would flash the panel on every `mod+K j`. which-key/tmux-style leaders wait
~250-400ms. Start around 300ms and tune by feel: long enough that a deliberate
pair never flashes, short enough that the menu feels responsive when you do
pause. (The exact number is a tuning knob, not a contract.)

### Pass-through escape

A focused program may genuinely want `mod+K` (rare for Meta+K). Follow the tmux
convention: `mod+K mod+K` (the leader twice) sends a literal `mod+K`-equivalent
to the program, or -- simpler first cut -- accept that `mod+K` is reserved and
add an escape only if a real need appears. Decide when implementing.

## Consequences

- **Navigate-while-focused returns** as `mod+K j` / `mod+K k`, with zero
  collision against the OS, compose keys, or TUIs.
- **One safe key carries all clip commands.** New commands cost a panel row, not
  a hunt for a free chord.
- **"Leader pending" is a mode** -- but client-local and instantaneous, so it
  does not reopen the projection/race tension from 0005/0006.
- **Cost:** clip commands while focused take two keystrokes (leader + key)
  instead of one chord. Acceptable for a tmux/vim-native audience, and the panel
  makes it discoverable for everyone else.
- **Open: does the leader also replace the navigate-mode `Alt` chords?** It
  could (one mechanism everywhere: `mod+K`-prefixed commands in every mode), or
  the `Alt` chords can stay in navigate mode where they are safe (no pty, no
  compose conflict). Defer; start with the leader as the focus-mode pierce.

## Migration

1. Add the "leader pending" client state: `mod+K` starts it + the hint timer
   instead of opening the panel immediately.
2. Second key within the window dispatches the matching panel-row action and
   cancels the timer; timeout opens the panel as today.
3. Add `j`/`k` (navigate via 0006 `setCursor`) as panel rows so they are both
   bound and discoverable.
4. Tune the delay (~300ms start).
5. Decide the pass-through escape and whether the leader subsumes the
   navigate-mode `Alt` chords.
