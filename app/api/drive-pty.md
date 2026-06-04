# Drive a pty

A terminal clip is backed by a live pty. Find its session id, then write to its
stdin and read it back. Examples are Nushell.

```nushell
let base = "{{ base | safe }}"
```

## 1. Find the session id

```nushell
let sid = (http get $"($base)/api/state" | get terminals.0.sid)
```

`GET /api/state` lists `terminals`, each with `sid` (pass this to the `/pty/*`
routes), `label` (the rename, or null), and `clip` (the owning clip id -- not
the sid; passing it yields `404 no pty session`).

## 2. Send keystrokes

The request body is written straight to the pty's stdin. In a Nushell string
`\r` is Enter and `\e` is Esc.

```nushell
http post $"($base)/pty/input?sid=($sid)" "ls\r"
http post $"($base)/pty/input?sid=($sid)" "\e"
```

## 3. Resize (optional)

```nushell
{cols: 120, rows: 40} | to json | http post $"($base)/pty/resize?sid=($sid)" --content-type application/json
```

## 4. Read it back

A one-shot snapshot (see [Snapshot a pty]({{ base | safe }}/api/howto/snapshot-pty)):

```nushell
http get $"($base)/pty/snap?sid=($sid)"
```

Or a live tee of the raw output bytes (escape sequences and all) -- it streams
until the session closes, and is dropped when you disconnect:

```nushell
http get $"($base)/pty/raw?sid=($sid)"
```

## Run a command and read the result

```nushell
let base = "{{ base | safe }}"
let sid = (http get $"($base)/api/state" | get terminals.0.sid)
http post $"($base)/pty/input?sid=($sid)" "echo hello\r"
sleep 1sec
http get $"($base)/pty/snap?sid=($sid)"
```
