# stacks2099

Stacks is a clip manager -- a tool for capturing and working with your current
context, your "locus of attention." A **clip** is any byte sequence with a mime
type: a note, an image, a JSON blob, a screenshot, a README. Clips gather into
**stacks**, one per task or train of thought.

stacks2099 takes that idea **live**: a clip can also be a running terminal or an
embedded URL -- so a stack holds not just static captures but the working
context itself, the shells you're in and the site you're building.

The browser holds no state. Selection, layout, and the visible HTML are all
projected on the server from an append-only event log and patched over
[Datastar](https://data-star.dev) SSE -- terminals included, rendered from
[wezterm-term](https://github.com/wezterm/wezterm) as HTML (no WASM, no
client-side VT emulator).

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
from the source tree with hot-reload -- edit the request closure, the
`sessions.html` template, CSS, or JS and refresh; no Rust rebuild:

```bash
cargo run -- --dev 127.0.0.1:5099 --store ./dev-store
```

Only changing the Rust (the pty projection, new builtins) needs `cargo build`.

## Model

Everything -- clips, stacks, selection, the window title -- is frames in an
append-only [cross.stream](https://cross.stream) log. The page is a pure
projection of that log, so every client sees the same state and a restart
replays it. The UI is three columns: **stacks** | **clips** | **content** (the
selected stack's clips, stacked top to bottom).

- A **clip** is any byte sequence with a mime type, rendered by what it is: an
  editable **note** (`text/*`, with a rendered view for markdown), an inline
  **image** (`image/*`), a live **embed** (`text/uri-list` or any URL note,
  shown as an `<iframe>`), a live **terminal**, or -- for anything else -- a
  read-only / downloadable preview. An unknown mime type still holds and
  previews; rendering it nicely is a later add, not a prerequisite.
- A **stack** groups clips into a context. Click to switch, double-click to
  rename, `+` to create.
- **Terminal clips** bind to an embedded-Nushell pty. The binary re-execs
  itself to run the shell, so there is no external `nu` to find, and placement
  survives a restart -- the pty respawns where it was, zellij-style.

## Add assets

Paste an image into the page (`Cmd`/`Ctrl+V`) to drop it into the current
stack. From the command line, POST any asset to the running server:

```bash
# mime from the Content-Type header; lands in the current stack; prints the clip id
curl --data-binary @diagram.png -H 'content-type: image/png' localhost:5099/clip/add
cat notes.md | curl --data-binary @- -H 'content-type: text/markdown' localhost:5099/clip/add
curl --data-binary @logo.svg -H 'content-type: image/svg+xml' 'localhost:5099/clip/add?stack=design'
```

Embed a live URL (e.g. a dev server you're watching) as an iframe clip:

```bash
echo http://localhost:3000 | curl --data-binary @- -H 'content-type: text/uri-list' localhost:5099/clip/add
```

`?stack=` takes a stack id or name; omit it for the current stack. `GET
/api/state` lists stacks for scripting.

## Keys

Two modes. **Navigate** browses (read-only, dimmed); **focus** drives the
selected pane (a terminal gets your keystrokes, a note opens its editor).
`mod+Enter` toggles between them. App chords are `Alt`-prefixed and fire in
every mode; plain `Enter`/`Esc` go to the focused pty. See
[docs/adr/0004-keyspace.md](docs/adr/0004-keyspace.md).

| Chord             | Action                                  |
| ----------------- | --------------------------------------- |
| `mod+Enter`       | Toggle focus (Cmd on macOS, Ctrl else)  |
| `Alt+T`           | New clip (note / terminal picker)       |
| `Alt+D`           | Close current clip                      |
| `Alt+J` / `Alt+K` | Next / previous clip                    |
| `Alt+R`           | Rename current clip                     |
| `Alt+Shift+R`     | Rename window title                     |
| `Alt+O`           | Cycle current terminal pane height      |

The status bar lists the active mode's chords and they are clickable.

## Built on

A fork of [http-nu](https://github.com/cablehead/http-nu) -- one self-contained
binary embedding the [Nushell](https://www.nushell.sh) engine, the
[cross.stream](https://github.com/cablehead/xs) (`xs`) event log, and the
[Datastar](https://data-star.dev) bundle. Clips and request handlers are
Nushell; the app leans on a handful of builtins:

- `pty open` / `pty view` -- terminals, modelled by
  [wezterm-term](https://github.com/wezterm/wezterm) and projected to an HTML
  cell grid.
- `.cat` / `.append` / `.cas` / `.bus` -- the `xs` event log (and its
  in-process bus) this fork is built around.
- `.mj` ([minijinja](https://github.com/mitsuhiko/minijinja)) for templates,
  `.highlight` ([syntect](https://github.com/trishume/syntect)) for syntax
  highlighting, `.md` ([pulldown-cmark](https://github.com/pulldown-cmark/pulldown-cmark))
  for markdown.

## Status

Experimental, moving fast. Interfaces and the event protocol are not stable.
