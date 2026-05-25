# stacks2099

A server-projected terminal + notes workspace in a single
[Nushell](https://www.nushell.sh)-powered binary.

Stacks of clips. A clip is a **live terminal** -- rendered server-side from
[wezterm-term](https://github.com/wezterm/wezterm) as an HTML cell grid and
morphed into the browser over [Datastar](https://data-star.dev) SSE -- or a
**note**. The browser holds no state: selection, mode, and the visible HTML are
all projected from an append-only event log.

No WASM, no client-side VT emulator. The terminal is just HTML the server keeps
in sync.

## Install

macOS (Apple Silicon):

```bash
brew install cablehead/tap/stacks2099
```

Linux and Windows: grab a binary from the
[releases](https://github.com/cablehead/stacks2099/releases).

From source (any platform with a Rust toolchain):

```bash
cargo build --release      # -> target/release/stacks2099
```

The binary is self-contained -- the app (Nushell handler, assets, fonts) and
the Nushell engine, store, and Datastar bundle are all baked in. There is no
external `nu` to install and nothing fetched from a CDN at runtime.

## Run

You choose where it listens (`ADDR`) and where its state lives (`--store`);
both are required.

```bash
stacks2099 127.0.0.1:5099 --store ./store      # runs the app baked into the binary
```

For development, `--dev` runs the app (`app/serve.nu` + `app/www`) straight
from the source tree with hot-reload -- edit the request closure, templates,
CSS, or JS and refresh; no Rust rebuild:

```bash
cargo run -- --dev 127.0.0.1:5099 --store ./dev-store
```

Only changing the Rust (the pty projection, new builtins) needs `cargo build`.
`--dev` implies `--watch`, so you never pass both.

## Model

- **Clips** live in the [cross.stream](https://cross.stream) event log
  (`clip.add` / `clip.update` / `clip.patch` / `clip.delete`). The page is a
  pure projection of those frames, patched over one SSE stream.
- **Terminal clips** bind to an embedded-Nushell pty. The binary re-execs
  itself to run the shell, so there is no external `nu` to find; placement
  survives a restart (the pty respawns, zellij-style).
- **Note clips** are content-addressed text -- edit in place, render as `<pre>`
  on blur.

## Keys

Two modes. **Navigate** browses (read-only, dimmed); **focus** drives the
selected pane (a terminal gets your keystrokes, a note opens its editor). App
chords are `Alt`-prefixed and fire in every mode; see
[docs/adr/0004-keyspace.md](docs/adr/0004-keyspace.md).

| Chord           | Action                                   |
| --------------- | ---------------------------------------- |
| `mod+Enter`     | Toggle focus (Cmd on macOS, Ctrl else)   |
| `Alt+T`         | New clip (note / terminal picker)        |
| `Alt+D`         | Close current clip                       |
| `Alt+J` / `Alt+K` | Next / previous clip                   |
| `Alt+R`         | Rename current clip                      |
| `Alt+O`         | Cycle current terminal pane height       |
| `Alt+Esc`       | Leave focus                              |

The status bar lists the active mode's chords and they are clickable.

## Built on

A fork of [http-nu](https://github.com/cablehead/http-nu), which embeds the
Nushell engine, the cross.stream store, and the Datastar bundle. This fork adds
the `pty view` projection (wezterm-term -> HTML grid). The result is one
self-contained binary.

## Status

Experimental, moving fast. Interfaces and the event protocol are not stable.
