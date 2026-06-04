# stacks2099 HTTP API

A clip manager served over HTTP. A "clip" of kind `terminal` is backed by a
live pty you can drive and read over this API. This page and the howtos it
links travel with the binary: `curl <base>/api` on any running instance.

Base URL is wherever the server listens, e.g. `http://127.0.0.1:5099`. The
examples assume `BASE=http://127.0.0.1:5099` and `jq`.

## Discovery

- `GET /api` this overview (markdown)
- `GET /api/state` JSON: stacks and live terminals (their `sid`, `label`, `clip`)

## Terminals

- `GET  /pty/snap?sid=` one-shot plain-text snapshot of a terminal's buffer
- `GET  /pty/raw?sid=` live tee of a terminal's raw output bytes
- `GET  /pty/view?sid=` live datastar/SSE stream of the rendered grid
- `POST /pty/input?sid=` write raw bytes to a terminal's stdin
- `POST /pty/resize?sid=` resize a terminal (JSON body `{cols, rows}`)

`sid` values come from `GET /api/state`. An unknown `sid` returns
`404 no pty session: <sid>`.

## Howtos

- [Drive a pty](/api/howto/drive-pty) -- find a terminal, send keystrokes, read it back
- [Snapshot a pty](/api/howto/snapshot-pty) -- read a terminal's current screen as text
