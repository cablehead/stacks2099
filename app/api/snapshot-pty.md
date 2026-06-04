# Snapshot a pty

`GET /pty/snap?sid=` returns a terminal's current buffer as plain text in one
shot -- no streaming. It includes the full retained scrollback plus the visible
screen, with trailing blank rows trimmed. Examples assume
`BASE=http://127.0.0.1:5099`.

    SID=$(curl -s "$BASE/api/state" | jq -r '.terminals[0].sid')
    curl -s "$BASE/pty/snap?sid=$SID"

Use this when you just want to read a terminal's state. For a live feed instead
of a one-shot read:

- `GET /pty/raw?sid=` -- raw output bytes from the moment you connect
- `GET /pty/view?sid=` -- the rendered grid as a datastar/SSE stream

An unknown `sid` returns `404 no pty session: <sid>`. Get a valid one from
`GET /api/state` and use the `sid` field (not `clip`).
