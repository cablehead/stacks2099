# Snapshot a pty

`GET /pty/snap?sid=` returns the terminal's current buffer as plain text in one
shot -- no streaming. It includes the full retained scrollback plus the visible
screen, with trailing blank rows trimmed. Examples are Nushell.

```nushell
let base = "{{ base | safe }}"
let sid = (http get $"($base)/api/state" | get terminals.0.sid)
http get $"($base)/pty/snap?sid=($sid)"
```

Use this when you just want to read a terminal's state. For a live feed instead
of a one-shot read, use `GET /pty/raw?sid=` (raw bytes) or `GET /pty/view?sid=`
(rendered grid as a datastar/SSE stream).

An unknown `sid` returns `404 no pty session: <sid>`. Get a valid one from
`GET /api/state` and use the `sid` field, not `clip`.
