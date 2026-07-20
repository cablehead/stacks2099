# Read, write, and exec

Three routes give a script (or an LLM driving this server) direct reach into
the machine, without going through a pty: `GET`/`PUT /file/<path>` for the
filesystem, `POST /exec` for running code. Same reach a pty already has --
arbitrary read/write/execute as the server's user, sudo included -- just a
clean request/response shape instead of shell-escaping a command through a
VT100 stream and scraping the rendered screen for the result.

## Read and write a file

The path after `/file/` is used directly, so it must be absolute:

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  "hello from the API" | http put $"($base)/file/tmp/greeting.txt"
  http get $"($base)/file/tmp/greeting.txt"
'
```

`PUT` creates parent directories as needed and always writes mode `0600`
(there is no owner/mode param -- there is no other user on this machine to own
it as). `GET` answers `404 no such file: <path>` if it doesn't exist, and
either route answers `400` for a relative path.

Binary content round-trips intact -- pass `--content-type
application/octet-stream` (or any type) and the body is written and read
byte-for-byte, no encoding step needed.

## Run code

`POST /exec` runs the request body as Nushell and answers with a JSON record:

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  "ls /tmp | length" | http post $"($base)/exec"
'
# {"stdout": "3\n", "stderr": "", "exit_code": 0}
```

The HTTP status is always `200` once the code ran at all -- a failing command
still gets you a response, with the failure visible in `exit_code` and
`stderr`. A `400` only means the request itself was malformed (an empty
body).

`/exec` runs in a fresh subprocess (`{{ bin | safe }} eval -c` under the
hood), so it does not share this server's store connection -- code run there
can't call `.cat` / `.append` directly. To read or change clip/stack state
from `/exec`, call this server's own HTTP API instead, the same way any other
caller would -- the body you `POST` is itself Nushell, so it can `http get`
right back at the server it's running on:

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  $"http get ($base)/api/state | get stacks | length" | http post $"($base)/exec"
'
```

If you haven't written Nushell before, see [Nushell in five
minutes]({{ base | safe }}/api/howto/nushell-tutorial) -- enough syntax to
write `/exec` payloads without guessing.
