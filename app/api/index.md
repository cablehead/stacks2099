# stacks2099 HTTP API

A clip manager served over HTTP. A clip of kind `terminal` is backed by a live
pty you can drive and read over this API. This page and the howtos it links
travel with the binary: `http get {{ base | safe }}/api` on any running
instance.

Examples are Nushell. Set the base URL for this instance:

```nushell
let base = "{{ base | safe }}"
```

## Discovery

| Endpoint         | Returns                                                   |
| ---------------- | --------------------------------------------------------- |
| `GET /api`       | this overview (markdown)                                  |
| `GET /api/state` | stacks and live terminals (`sid`, `label`, `clip`, `cwd`) |

```nushell
http get $"($base)/api/state"
```

## Terminals

| Endpoint                | Purpose                                       |
| ----------------------- | --------------------------------------------- |
| `GET /pty/snap?sid=`    | one-shot plain-text snapshot of the buffer    |
| `GET /pty/raw?sid=`     | live tee of the raw output bytes              |
| `GET /pty/view?sid=`    | live datastar/SSE stream of the rendered grid |
| `POST /pty/input?sid=`  | write raw bytes to the terminal's stdin       |
| `POST /pty/resize?sid=` | resize the terminal (JSON `{cols, rows}`)     |

`sid` values come from `GET /api/state`. An unknown `sid` returns
`404 no pty session: <sid>`.

## Howtos

- [Drive a pty]({{ base | safe }}/api/howto/drive-pty) -- open a terminal, send keystrokes, read it back
- [Snapshot a pty]({{ base | safe }}/api/howto/snapshot-pty) -- read a terminal's screen as text
