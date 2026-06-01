# Browser harness

Drives a real chromium against stacks2099 -- for the things only a browser can
assert (live SSE render, the pty grid, image/embed/markdown panes). The
unit-testable projection logic lives in `tests/test_projection.nu`; this layer
is on top of that.

`playwright-core` is vendored in `node_modules` (committed via `package-lock`);
chromium is the system browser at `/usr/bin/chromium` (override `CHROMIUM_PATH`,
which CI sets from its installed Chrome).

## Tests

```
npm test
```

`smoke.test.mjs` spawns an isolated server (`spawnApp` in `lib.mjs`: fresh temp
store, unique port, the `--dev` debug binary) and asserts the rendered UI. Runs
as its own CI job. Build the binary first (`cargo build`) or set
`STACKS2099_BIN`.

## Screenshot a running instance

```
node shoot.mjs                      # dev default 127.0.0.1:5099 -> /tmp/stacks2099-shot.png
node shoot.mjs /tmp/foo.png         # custom output path
node shoot.mjs --add                # also file the shot into the running stack
BASE=http://127.0.0.1:5300 node shoot.mjs   # a different instance
```

`--add` POSTs the PNG to `/clip/add`, dropping it as an image clip in the
current (last-focused) stack -- so a session driving the browser can surface
what it rendered back into the workspace, no manual grab or paste.

A dev/debugging aid, not a test. Unlike the test harness it does NOT spawn its
own server -- it shoots whatever is already running and reads that server's
store, so the PNG is the real, current UI. It captures the same stacks, clips,
and live pty grids you see, minus transient client-only state (which clip your
window has focused, scroll position, an unsubmitted edit). For exactly your
viewport, grab an OS screenshot instead.

Prints a one-line `summary {...}` (title, pane/clip counts, whether a pty grid
streamed) and the output path. The default `127.0.0.1:5099` is where
`target/debug/stacks2099 --dev` listens.

## Record a session to video

```
node record.mjs                     # record 20s -> /tmp/stacks2099-cast.mp4
node record.mjs --secs 60           # fixed 60s
node record.mjs --until-enter       # record until you press Enter here
node record.mjs /tmp/foo.mp4        # custom output path
node record.mjs --master            # also keep a ProRes editing master (.mov)
node record.mjs --webm-only         # skip ffmpeg, keep the raw playwright webm
BASE=http://127.0.0.1:5300 node record.mjs   # a different instance
```

Like `shoot.mjs`, this drives chromium against an already-running server -- it
does not spawn one. A real browser speaks every stream the app uses (the page
load, `/sse`, and an `/pty/view` per terminal pane), so the capture is the live
UI with no replay harness. The terminals are server-rendered DOM text, so
headless chromium records them with no GPU or canvas handling.

Pipeline: playwright `recordVideo` (webm/VP8 at 2x scale for crisp text) ->
ffmpeg transcode to an H.264 mp4 with 1s keyframes (frame-accurate trims) and
`+faststart`. The mp4 is the delivery/editing copy. `--master` adds an all-intra
ProRes 4:2:2 `.mov` to re-encode from without loss. The webm is removed after a
successful transcode unless `--webm-only`.

`ffmpeg` must be on PATH for the transcode (`brew install ffmpeg`); without it
the raw webm is kept and you are told. Drive the session yourself while it
records: use `--until-enter` for manual takes, `--secs` for a fixed length.
