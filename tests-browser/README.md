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
as its own CI job. Build the binary first (`cargo build`) or set `STACKS2099_BIN`.

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
