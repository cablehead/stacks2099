# stacks2099 HTTP API

A clip manager served over HTTP. A clip of kind `terminal` is backed by a live
pty you can drive and read over this API. This page and the howtos it links
travel with the binary:
`{{ bin | safe }} eval -c 'http get {{ base | safe }}/api'`.

## Running the examples

The examples are Nushell. Run a complete pipeline with `{{ bin | safe }} eval -c` (a
Nushell with these commands; no `--store` needed for HTTP, so nothing to lock):

```nushell
{{ bin | safe }} eval -c 'http get {{ base | safe }}/api/state'
```

Put `http get` _inside_ the call. Piping data into `eval -c` (or `nu -c`) does
not populate `$in`, so `curl ... | {{ bin | safe }} eval -c '$in | from json'` sees
`nothing` and fails. Fetch inside; don't pipe in.

## Discovery

| Endpoint         | Returns                                |
| ---------------- | -------------------------------------- |
| `GET /api`       | this overview (markdown)               |
| `GET /api/state` | stacks, every clip, and live terminals |

`/api/state` returns `{focusedClip, focusedStack, stacks, clips, terminals}`.
`stacks` is `{id, name}`; `clips` is a flat list across all stacks, each tagged
with its owning `stack` -- `{id, stack, kind, label, mime, view, position}` -- so
you can find a clip by label or scope to a stack without a second call.
`terminals` carries the live pty `sid`, `label`, `clip`, and `cwd`.

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

Fetch a howto the same way, e.g.
`{{ bin | safe }} eval -c 'http get {{ base | safe }}/api/howto/drive-pty'`.

- [Drive a pty]({{ base | safe }}/api/howto/drive-pty) -- open a terminal, send keystrokes, read it back
- [Snapshot a pty]({{ base | safe }}/api/howto/snapshot-pty) -- read a terminal's screen as text
