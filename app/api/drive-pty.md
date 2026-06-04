# Drive a pty

A terminal clip is backed by a live pty. Find its session id, then write to its
stdin and read it back. Examples assume `BASE=http://127.0.0.1:5099`.

## 1. Find the session id

    SID=$(curl -s "$BASE/api/state" | jq -r '.terminals[0].sid')

`GET /api/state` lists `terminals[]`, each with:

- `sid` -- pass this to the `/pty/*` routes
- `label` -- the rename, or null until renamed
- `clip` -- the owning clip id; NOT the sid (a common mix-up that yields
  `404 no pty session`)

## 2. Send keystrokes

Input is raw bytes on the request body. `\r` is Enter, `\x1b` is Esc.

    printf 'ls\r' | curl -s -X POST "$BASE/pty/input?sid=$SID" --data-binary @-
    printf '\x1b' | curl -s -X POST "$BASE/pty/input?sid=$SID" --data-binary @-

## 3. Resize (optional)

    curl -s -X POST "$BASE/pty/resize?sid=$SID" \
      -H 'content-type: application/json' --data '{"cols":120,"rows":40}'

## 4. Read it back

- One-shot snapshot: see [Snapshot a pty](/api/howto/snapshot-pty).
- Live raw bytes (escape sequences and all):

      curl -sN "$BASE/pty/raw?sid=$SID"

  This is a tee: it streams output from the moment you connect (it does not
  replay existing scrollback), ends when the session closes, and is dropped
  when you close the connection.

## Example: run a command and read the result

    SID=$(curl -s "$BASE/api/state" | jq -r '.terminals[0].sid')
    printf 'echo hello\r' | curl -s -X POST "$BASE/pty/input?sid=$SID" --data-binary @-
    sleep 1
    curl -s "$BASE/pty/snap?sid=$SID"
