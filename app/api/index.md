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

| Endpoint          | Returns                                           |
| ----------------- | ------------------------------------------------- |
| `GET /api`        | this overview (markdown)                          |
| `GET /api/state`  | stacks, every clip, and live terminals (snapshot) |
| `GET /api/events` | live feed of log frames (newline-delimited JSON)  |

`/api/state` returns `{focusedClip, focusedStack, stacks, clips, terminals}`.
`stacks` is `{id, name}`; `clips` is a flat list across all stacks, each tagged
with its owning `stack` -- `{id, stack, kind, label, mime, view, position}` -- so
you can find a clip by label or scope to a stack without a second call.
`terminals` carries the live pty `sid`, `clip`, and `cwd`; a terminal's label
lives on its clip, so join via `clip` into `clips`.

`/api/state` is the snapshot; `/api/events` is the live delta. It streams one
log frame per line as it's appended (history is skipped, so every line is a
change since you connected). Each line is `{id, topic, meta}` -- the frame's
scru128, its topic, and its fields. Topics are the protocol: `clip.add` /
`clip.update` / `clip.patch` / `clip.delete`, `stack.add` / `stack.update` /
`stack.delete`. Snapshot once, then react to the stream:

```nushell
{{ bin | safe }} eval -c 'http get --raw {{ base | safe }}/api/events
  | lines | each {|l| $l | from json }
  | where topic == "clip.add"'   # e.g. act on every new clip
```

From a shell, `curl -sN {{ base | safe }}/api/events` (the `-N` disables curl's
output buffering so lines arrive as they happen).

Clip `id`s are full scru128s from `/api/state` (the `clips` list). The UI crops
them to the tail for display, so don't paste what you see -- the by-id routes
(`/clip/close`, `/clip/label`, `/clip/view`, `/clip/update`, `/clip/move`) answer
`404 no such clip: <id>` for an unknown id, never a silent success.

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

## System access

These reach past the clip/stack protocol to the machine the server runs on --
same reach a pty already has (arbitrary read/write/execute as the server's
user, sudo included). No sandboxing, no configurable root: deliberate, since
these routes don't cross a trust boundary the terminal doesn't already cross.

| Endpoint           | Purpose                                                  |
| ------------------ | -------------------------------------------------------- |
| `GET /file/<path>` | read an absolute path's raw bytes                        |
| `PUT /file/<path>` | write the request body to an absolute path (mode 0600)   |
| `POST /exec`       | run Nushell code, get back `{stdout, stderr, exit_code}` |

`<path>` is everything after `/file/`, used directly -- `GET /file/etc/hosts`
reads `/etc/hosts`. A relative or empty path answers `400`; a missing file on
`GET` answers `404`.

`POST /exec` runs the request body as Nushell in a fresh subprocess (the same
`eval -c` these docs use) and always answers `200` with the result as JSON --
check `exit_code`, not the HTTP status, for whether the code succeeded. The
subprocess has no `--store`, so it can't touch `.cat`/`.append` directly; code
that needs clip/stack state calls this server's own HTTP API instead, same as
any other caller.

## Howtos

Fetch a howto the same way, e.g.
`{{ bin | safe }} eval -c 'http get {{ base | safe }}/api/howto/drive-pty'`.

- [Drive a pty]({{ base | safe }}/api/howto/drive-pty) -- open a terminal, send keystrokes, read it back
- [Snapshot a pty]({{ base | safe }}/api/howto/snapshot-pty) -- read a terminal's screen as text
- [Read, write, and exec]({{ base | safe }}/api/howto/files-and-exec) -- touch the filesystem and run commands directly
- [Nushell in five minutes]({{ base | safe }}/api/howto/nushell-tutorial) -- enough syntax to write `/exec` payloads
