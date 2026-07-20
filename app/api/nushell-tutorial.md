# Nushell in five minutes

This server, its shell (`{{ bin | safe }} eval -c`), and `POST /exec` all speak
Nushell -- a shell where every value is structured data (strings, numbers,
records, tables, binary), not just text. This is enough to read and write
useful `/exec` payloads and CLI one-liners; it is not the full language.

## Pipelines, not text streams

`|` passes a typed value, not bytes. `ls` returns a table; `where`, `sort-by`,
`get` operate on it directly instead of parsing columns out of text:

```nushell
ls /tmp | where size > 1mb | sort-by modified | get name
open /etc/hosts | lines | length
```

## Running real commands

A bare word runs an external command if it isn't a Nushell builtin (`ls`,
`open`, `sort-by`, `where` above are builtins). To force an external even when
a builtin shadows the name, prefix `^`:

```nushell
^ls -la /tmp        # the real /bin/ls, not Nushell's builtin
git status
docker ps | lines
```

Capture an external's output, error, and exit code together with `complete`
-- this is exactly the shape `POST /exec` hands back:

```nushell
(^some-command --flag | complete)
# {stdout: "...", stderr: "...", exit_code: 0}
```

## Quoting

| Form         | Example             | Escapes       | Use for                     |
| ------------ | ------------------- | ------------- | --------------------------- |
| Single       | `'hello'`           | none          | literal text, Windows paths |
| Double       | `"a\nb"`            | `\n \t \" \\` | strings needing escapes     |
| Raw          | `r#'he said "hi"'#` | none          | mixed quotes, multi-line    |
| Bare word    | `hello`             | none          | command args (word chars)   |
| Backtick     | `` `my file.txt` `` | none          | paths/globs with spaces     |
| Interpolated | `$"x=($var)"`       | per-quote     | embedding variables         |

Interpolation needs `$"..."` **and** parens around the expression:

```nushell
let name = "world"
"hello $name"        # literal: "hello $name"   -- WRONG
$"hello ($name)"      # "hello world"           -- RIGHT
```

For `POST /exec` itself: whatever wraps the request body (curl, `eval -c
'...'`, a heredoc) is a separate quoting layer outside the Nushell you're
sending -- keep that outer layer literal (single-quoted) so it doesn't try to
interpolate your Nushell's own `$vars` before they get here.

## Redirection -- not `2>&1`

| Bash                     | Nushell                           |
| ------------------------ | --------------------------------- |
| `cmd > file`             | `cmd o> file`                     |
| `cmd >> file`            | `cmd o>> file`                    |
| `cmd > /dev/null`        | `cmd \| ignore`                   |
| `cmd 2>&1`               | `cmd o+e>\| next_cmd`             |
| `cmd > /dev/null 2>&1`   | `cmd o+e>\| ignore`               |
| `cmd \| tee log \| next` | `cmd \| tee { save log } \| next` |

## Structured data literals

```nushell
{name: "clip", kind: "note"}          # record
[1 2 3]                                # list
[{id: 1} {id: 2}]                      # table (list of records)
{a: 1} | to json                       # -> {"a":1}
'{"a":1}' | from json                  # -> {a: 1}
```

## Control flow and blocks

```nushell
if $n > 0 { "positive" } else { "non-positive" }
for x in [1 2 3] { print $x }
[1 2 3] | each {|x| $x * 2 }
[1 2 3] | where {|x| $x > 1 }
try { open /no/such/file } catch {|e| $"failed: ($e.msg)" }
```

`{|x| ...}` blocks are closures; the pipe-delimited names are parameters,
matching however many the caller passes.

## Bash equivalents

| Bash                      | Nushell                              |
| ------------------------- | ------------------------------------ |
| `mkdir -p path`           | `mkdir path`                         |
| `rm -rf path`             | `rm -r path`                         |
| `cat file`                | `open --raw file`                    |
| `grep pat`                | `where $it =~ pat` / `find pat`      |
| `sed 's/a/b/'`            | `str replace a b`                    |
| `head -5` / `tail -5`     | `first 5` / `last 5`                 |
| `for f in *.md; do..done` | `ls *.md \| each {\|r\| ... }`       |
| `$(cmd)`                  | `(cmd)`                              |
| `echo $PATH`              | `$env.PATH` (`$env.Path` on Windows) |
| `echo $?`                 | `$env.LAST_EXIT_CODE`                |
| `FOO=bar ./bin`           | `FOO=bar ./bin`                      |
| `type foo`                | `which foo`                          |
| `cmd1 && cmd2`            | `cmd1; cmd2`                         |
| `${FOO:-fallback}`        | `$env.FOO? \| default "fallback"`    |

## HTTP, since this server is one

```nushell
http get {{ base | safe }}/api/state
{cols: 1, rows: 1} | to json | http post {{ base | safe }}/pty/resize?sid=abc --content-type application/json
"raw bytes" | http put {{ base | safe }}/file/tmp/x
```

`http get`/`post`/`put` parse a JSON response body automatically into a
record/table -- don't pipe them to `from json`. Pass `--raw` to get the plain
response string instead. `--content-type` wants the full MIME type
(`application/json`, not `json`).

## Finding files

Prefer `glob` (or `ls **/*`) over external `find` -- `ls **/*` still walks
hidden directories, so scope a glob instead of shelling out.

## Parallelism

`par-each` runs a closure across threads when order doesn't matter:

```nushell
ls **/*.rs | par-each {|f| open $f.name | lines | length }
```

## Gotchas specific to this API

- `{{ bin | safe }} eval -c '<code>'` runs `<code>` as a fresh process with no
  stdin hookup -- piping data into `eval -c` does **not** populate `$in`
  inside it. Put the `http get`/`open` call _inside_ the `-c` string.
- **No persistence across calls.** Each `POST /exec` is a brand-new
  subprocess: `let` bindings, `cd`, and `$env` changes from one call are gone
  by the next. Do everything a task needs inside the one script you send, or
  keep state on disk (`/file`) or in this server's own clip/stack store
  (`http post` back to it) instead of in variables. This is unlike Nushell's
  own upstream `nu --mcp`, which keeps one long-lived REPL (and a `$history`
  ring buffer) across calls -- this API deliberately doesn't, to stay a plain
  stateless HTTP route.
- **No output cap or history.** `/exec` returns your full `stdout`/`stderr` in
  the JSON response, uncapped -- there's no `$history` safety net to fall back
  on if you dump something huge. For a large result, write it to a file with
  `save` (or the `/file` route) and read back only the slice you need, rather
  than printing all of it.
- `$nu`, `$env`, and externals all work inside `/exec`, but there is no
  `--store`, so `.cat` / `.append` aren't available -- reach the store through
  this server's HTTP routes instead (see
  [Read, write, and exec]({{ base | safe }}/api/howto/files-and-exec)).
- `job spawn`/`job recv` don't help here the way they do in a persistent
  shell: the subprocess exits when your script returns, taking any spawned
  job with it. For something that should keep running and be checked on
  later, open a terminal clip instead (`POST /clip/new?type=terminal`, then
  drive it via `/pty/*` -- see [Drive a
  pty]({{ base | safe }}/api/howto/drive-pty)) -- that's a real, independently
  observable process.

## Where to go deeper

`{{ bin | safe }}` bundles the same engine as upstream Nushell, so its own
docs apply: <https://www.nushell.sh/book/>. For quick lookups without leaving
the shell, `help commands`, `help <command>`, and `<command> --help` all work
inside `eval -c` and `/exec` alike.
