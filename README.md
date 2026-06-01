# stacks2099

[Stacks](https://stacks.cross.stream) is a tool for thought: a collection of
**stacks** of **clips** for managing your personal context. A **clip** is any
byte sequence with a mime type -- a note, an image, a JSON blob, a screenshot, a
README. Clips gather into **stacks**, one per task or train of thought.

stacks2099 is that thesis, expanded. The original
[stacks](https://github.com/cablehead/stacks) ran on a crude event stream and a
throwaway first-draft UI. Its event stream was spun out and matured into
[cross.stream](https://github.com/cablehead/xs)
([stacks#46](https://github.com/cablehead/stacks/issues/46)); the UI it was
missing arrived as [Datastar](https://data-star.dev)
([stacks#58](https://github.com/cablehead/stacks/issues/58)). stacks2099 is
stacks rebuilt on both.

It also widens what a clip can be. Besides notes and images, a clip can be a
running terminal or an embedded URL, so a stack holds the working context itself
-- the shells you're in, the site you're building. The page is a pure projection
of the event log: selection, layout, and the visible HTML are computed on the
server and patched over Datastar SSE. Terminals included, rendered from
[wezterm-term](https://github.com/wezterm/wezterm) as
[an HTML grid (no WASM, no client-side VT emulator)](journey.md).

<img alt="A terminal clip rendered as an HTML cell grid" width="760" src="docs/assets/terminal.png">

## Install

Each release ships prebuilt binaries for macOS (Apple Silicon), Linux (x86_64),
and Windows (x86_64).

### [eget](https://github.com/zyedidia/eget)

Grabs the right binary for your platform from the latest release:

```bash
eget cablehead/stacks2099
```

### Homebrew (macOS)

```bash
brew install cablehead/tap/stacks2099
```

### Direct download

Pick an archive from the
[releases](https://github.com/cablehead/stacks2099/releases) page; the binary
sits at the root.

### cargo

Not published to crates.io. Install from git, or build a checkout:

```bash
cargo install --git https://github.com/cablehead/stacks2099
# or, in a clone:
cargo build --release      # -> target/release/stacks2099
```

The binary is self-contained -- the app (Nushell handler, assets, fonts) and the
Nushell engine, store, and Datastar bundle are all baked in. There is no
external `nu` to install and nothing fetched from a CDN at runtime.

## Run

You choose where it listens (`ADDR`) and where its state lives (`--store`); both
are required.

```bash
stacks2099 127.0.0.1:5099 --store ./store      # runs the app baked into the binary
```

For development, `--dev` runs the app (`app/serve.nu` + `app/www`) straight from
the source tree with hot-reload -- edit the request closure, the `sessions.html`
template, CSS, or JS and refresh; no Rust rebuild:

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
  editable **note** (`text/*`), an inline **image** (`image/*`), a live
  **terminal**, a live **embed** (a URL in an `<iframe>`), or -- for anything
  else -- a read-only / downloadable preview. An unknown mime type still holds
  and previews; rendering it nicely is a later add, not a prerequisite.
- Some clips offer **alternate views**, toggled from a button on the pane: a
  markdown note flips **edit ⇄ rendered**; a note whose body is a URL flips
  **edit ⇄ embedded** (the live iframe). A `text/uri-list` clip starts embedded.
- A **stack** groups clips into a context. The top-left **breadcrumb** names the
  current stack and opens a switcher to jump between stacks or create one
  (`Alt+\`; `Alt+[` / `Alt+]` cycle). It stays reachable when the scrollable
  layout hides the rail.
- Clips order **`auto`** (by activity -- newest edits float up) or **`manual`**
  (curated). The clips-header badge toggles the mode;
  `Alt+Shift+J`/`Alt+Shift+K` move the selected clip down/up (the first move
  freezes the current order into `manual`).
- Each stack picks a **layout**: `flow` (a vertical column of panes) or `niri`
  (a horizontal scrollable strip). The top-bar Layout button or `Alt+L` toggles
  it.
- **Terminal clips** bind to an embedded-Nushell pty. The binary re-execs itself
  to run the shell, so there is no external `nu` to find, and placement survives
  a restart -- the pty respawns where it was, zellij-style.

The top bar carries the cross-clip handles -- the stack breadcrumb, Sort,
Layout, Theme, Actions, and New. The **Theme** button swaps the terminal palette
(client-side: Default, Nord, Solarized, Railscasts, and friends).

<img alt="Theme picker open beside a focused, themed terminal" width="640" src="docs/assets/theme.png">

## Add assets

Paste an image into the page (`Cmd`/`Ctrl+V`) to drop it into the current stack.
From the command line, POST any asset to the running server:

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

Re-post to an existing clip to replace its bytes -- its pane refreshes in place,
so a regenerated asset updates live:

```bash
curl --data-binary @diagram.png 'localhost:5099/clip/update?clip=<id>'
```

`?stack=` takes a stack id or name; omit it for the current stack. `/api/state`
lists the stacks (ids, names, clip counts) for scripting.

## API and events

The HTTP routes are thin wrappers: each appends a frame to the log (selection
aside -- that rides the in-process bus). The store serves an `xs` API on its
socket, so you can write the same frames yourself; the API is just sugar over
the event log.

```bash
# add a markdown clip via the HTTP API
curl --data-binary @notes.md -H 'content-type: text/markdown' localhost:5099/clip/add

# the identical effect, appended straight to the log with the xs client
# (STACK_ID from `curl localhost:5099/api/state`):
cat notes.md | xs append ./store clip.add --ttl forever \
  --meta '{"stack_id":"STACK_ID","kind":"content","mime_type":"text/markdown"}'
```

In a store-connected Nushell (`xs` gives you one) the builtin form is
`<body> | .append <topic> --meta {...}` -- exactly what each route runs.

| Action          | HTTP                          | Frame appended                                   |
| --------------- | ----------------------------- | ------------------------------------------------ |
| New stack       | `POST /stack/new`             | `stack.add {sort}`                               |
| Rename stack    | `POST /stack/rename`          | `stack.update {id, name}`                        |
| Delete stack    | `POST /stack/close?stack=`    | `stack.delete {id}`                              |
| Add clip        | `POST /clip/add`              | `clip.add {stack_id, kind, mime_type}` + body    |
| Update clip     | `POST /clip/update?clip=`     | `clip.update {id}` + body                        |
| Rename clip     | `POST /pty/label`             | `clip.patch {id, label}`                         |
| Set view        | `POST /clip/view?clip=&view=` | `clip.patch {id, view}`                          |
| Close clip      | `POST /clip/close?clip=`      | `clip.delete {id}`                               |
| Move clip       | `POST /clip/move?dir=&clip=`  | `clip.patch {id, position}` (renumber on freeze) |
| Toggle sort     | `POST /stack/sort?stack=`     | `stack.update {id, sort}`                        |
| Toggle layout   | `POST /stack/layout?stack=`   | `stack.update {id, layout}`                      |
| Select / switch | `POST /nav`, `/stack/select`  | bus `clip.select` / `stack.select`               |

The topics and fields _are_ the protocol -- defined in `app/projection.nu`.
Terminal clips are the exception: their pty is spawned by a `POST` to
`/clip/new?type=terminal`, so create those through the API.

## Keys

Two modes. **Navigate** browses (read-only, dimmed); **focus** drives the
selected pane (a terminal gets your keystrokes, a note opens its editor). A
focused clip owns every key except the two carve-outs below, so composed
characters (`|`, `~`, `\`) reach the terminal untouched. App chords live in
navigate mode; from a focused clip, `mod+Enter` out first. See
[docs/adr/0005-mode-projected-keymap.md](docs/adr/0005-mode-projected-keymap.md).

Carve-outs (work even with a clip focused):

| Chord       | Action                                 |
| ----------- | -------------------------------------- |
| `mod+Enter` | Toggle focus (Cmd on macOS, Ctrl else) |
| `mod+K`     | Clip actions (rename / close / move)   |

Navigate-mode chords:

| Chord                         | Action                             |
| ----------------------------- | ---------------------------------- |
| `Alt+T`                       | New clip (note / terminal picker)  |
| `Alt+D`                       | Close current clip                 |
| `Alt+J` / `Alt+K`             | Next / previous clip               |
| `Alt+Shift+J` / `Alt+Shift+K` | Move clip down / up                |
| `Alt+\`                       | Switch stack (open the switcher)   |
| `Alt+[` / `Alt+]`             | Previous / next stack              |
| `Alt+S`                       | Toggle stack sort (auto / manual)  |
| `Alt+L`                       | Toggle stack layout (flow / niri)  |
| `Alt+R`                       | Rename current clip                |
| `Alt+Shift+R`                 | Rename window title                |
| `Alt+O`                       | Cycle current terminal pane height |

The top bar carries the same actions as clickable handles (breadcrumb, Sort,
Layout, Theme, Actions, New); the status bar lists the active mode's chords.

## Built on

A fork of [http-nu](https://github.com/cablehead/http-nu) -- one self-contained
binary embedding the [Nushell](https://www.nushell.sh) engine, the
[cross.stream](https://github.com/cablehead/xs) (`xs`) event log, and the
[Datastar](https://data-star.dev) bundle. Clips and request handlers are
Nushell; the app leans on a handful of builtins:

- `pty open` / `pty view` -- terminals, modelled by
  [wezterm-term](https://github.com/wezterm/wezterm) and projected to an HTML
  cell grid.
- `.cat` / `.append` / `.cas` -- the `xs` event log this fork is built around.
  `.bus` (pub/sub) is http-nu's own in-process event bus, not xs.
- `.mj` ([minijinja](https://github.com/mitsuhiko/minijinja)) for templates,
  `.highlight` ([syntect](https://github.com/trishume/syntect)) for syntax
  highlighting, `.md`
  ([pulldown-cmark](https://github.com/pulldown-cmark/pulldown-cmark)) for
  markdown.

## Status

Experimental, moving fast. Interfaces and the event protocol are not stable.
