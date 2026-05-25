# ADR 0004: Keyspace

## Context

The sessions surface keeps growing keyboard chords (new/close/cycle/rename,
focus/escape, and now pane sizing). We need one place that says which chords
are taken, how they're scoped, and what makes a chord safe to add -- so new
bindings don't collide with each other, with the terminal, or with the
browser.

Two hard constraints shape the space:

- **The terminal owns most keys in focus mode.** When a pane is focused,
  key-buffer forwards almost everything to the pty, including plain `Esc`
  (TUIs need it) and `Ctrl`-letters. So app chords can't live on bare keys
  or `Ctrl` combos without stealing them from programs.
- **Browsers and the OS reserve `Cmd`/`Ctrl` widely** (Cmd+T new tab, Cmd+W
  close, Ctrl+L address bar, ...). Intercepting those fights the browser and
  surprises users.

## Decision

App chords use **`Alt`** (Option on macOS) and fire in **every mode** --
navigate, a focused terminal, or while editing a note. The capture-phase
keymap handler consults the `Alt` keymap regardless of mode and
`stopPropagation`s a match so it never also reaches the focused pty via
key-buffer. Non-`Alt` keys stay context-scoped: a focused terminal forwards
them to the pty, a note's textarea owns them (Enter = newline, Esc = end
edit), and navigate honors the non-`Alt` keymap (Enter = focus).

- **`Alt` is the app modifier.** It's largely free of browser/OS reservation.
  Making the `Alt` chords global means clip management (new/close/cycle/
  rename/height) never requires first leaving a focused pane -- you can
  `Alt+J`/`Alt+K` straight from one focused terminal into the next. The cost
  is that the terminal layer no longer sees `Alt`+letter (some TUIs use
  Meta-bindings); we accept that for the seamless management flow, and
  `Cmd`/`Ctrl` are still left entirely to the browser/OS and to TUIs.
- **Selection carries focus.** In focus mode, moving the selection (`Alt+J`/
  `Alt+K`, or clicking a sidebar clip) auto-focuses the newly selected pane:
  a terminal gets key-buffer/pty, a note opens its editor. Navigate mode
  never auto-focuses -- it's read-only browsing.
- **`mod+Enter` is the only focus toggle.** It both enters focus (on the
  selected clip) and leaves it, from any mode. Plain `Esc` and plain `Enter`
  go entirely to the focused pty -- there is no bare-key or `Alt+Esc` focus
  shortcut. `mod` is `Cmd` on macOS, `Ctrl` elsewhere; both are mapped.
- **macOS Option produces glyphs** (Option+O -> "o-slash"). `comboKey`
  normalizes via `e.code` (`KeyO` -> `o`) and the handlers `preventDefault`,
  so detection is consistent across Chrome/Firefox/Safari and nothing gets
  typed. Any new `Alt+letter` chord inherits this for free.
- **Safety bar for a new chord:** must not be a default browser accelerator
  in Chrome/Firefox/Safari, must be detectable via `e.code` under Option, and
  (since `Alt` chords are now global) must be an action you're willing to
  shadow from a focused TUI. `Alt+letter` combos clear the first two; bare
  `Alt` taps (Firefox/Windows menu bar) do not.

### Current chords

App chords (fire in any mode):

| Chord         | Action                         |
| ------------- | ------------------------------ |
| `Alt+T`       | New clip (note/terminal picker)|
| `Alt+D`       | Close current clip             |
| `Alt+J`/`Alt+K` | Next / previous clip         |
| `Alt+R`       | Rename current tab             |
| `Alt+Shift+R` | Rename window title            |
| `Alt+O`       | Cycle current terminal pane height |
| `mod+Enter`   | Toggle focus (enter/leave); `mod` = Cmd on macOS, Ctrl else |

`mod+Enter` is the only focus toggle. It is safe in any mode because
key-buffer drops every Meta combo (so Cmd+Enter never reaches the pty) and a
plain terminal cannot distinguish Ctrl+Enter from Enter (so intercepting it
costs the pty nothing). Both `cmd+enter` and `ctrl+enter` are mapped.

Fall-through (no chord -- the pty/textarea owns these):

| Chord     | Mode     | Action                              |
| --------- | -------- | ----------------------------------- |
| `Esc`/`Enter` | focus | forwarded to the focused pty        |
| (non-Alt) | focus    | forwarded to the focused pty / note |

The status bar lists the active mode's chords and they are clickable, so the
keyspace is also discoverable without this document.

## Consequences

- **New bindings have a recipe:** an unused `Alt+letter`, registered in the
  keymap + `window.app` action + the shared `appChords` status-bar list.
  Three edits, one row in the table above.
- **We never compete with the browser**, at the cost of every app chord
  needing the `Alt` prefix and shadowing `Alt`+letter from focused TUIs. If we
  want vim-style bare `j`/`k` in navigate mode later, that's a new decision --
  navigate mode has key-buffer off, so it's available, but it would diverge
  from the `Alt`-prefixed set.
- **The table can drift** from the code. Mitigation: the status bar is
  generated from the same actions, so the live UI is the source of truth;
  this table is the rationale + reservation list.
