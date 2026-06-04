# Snapshot a pty

`GET /pty/snap?sid=` returns the terminal's current buffer as plain text in one
shot -- the full retained scrollback plus the visible screen, with trailing
blank rows trimmed. No streaming.

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  let sid = (http get $"($base)/api/state" | get terminals.0.sid)
  http get $"($base)/pty/snap?sid=($sid)"
'
```

Use this when you just want to read a terminal's state. For a live feed instead
of a one-shot read, use `GET /pty/raw?sid=` (raw bytes) or `GET /pty/view?sid=`
(rendered grid as a datastar/SSE stream).

An unknown `sid` returns `404 no pty session: <sid>`. Use the `sid` field from
`GET /api/state`, not `clip`.
