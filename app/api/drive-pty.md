# Drive a pty

A terminal clip is backed by a live pty. Drive it with one self-contained
`{{ bin | safe }} eval -c` block: find the sid, write to its stdin, read it back.
(Each `eval -c` is its own process, so resolve the sid in the same block you
use it.)

## Find a terminal's sid

```nushell
{{ bin | safe }} eval -c 'http get {{ base | safe }}/api/state | get terminals'
```

`terminals` has `sid` (pass this to the `/pty/*` routes), `label` (the rename,
or null), `clip` (the owning clip id -- not the sid; passing it yields
`404 no pty session`), and `cwd` (the shell's directory via OSC 7, or null).

## Send keystrokes and read the result

The request body is written straight to the pty's stdin -- live keystrokes
into whatever that terminal is running. Don't send to a terminal running an
interactive program you care about (an editor, or a shell you are operating in
yourself); read it with `/pty/snap` first if you're unsure what's in it. In a
Nushell string `\r` is Enter and `\e` is Esc.

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  let sid = (http get $"($base)/api/state" | get terminals.0.sid)
  http post $"($base)/pty/input?sid=($sid)" "echo hello\r"
  sleep 1sec
  http get $"($base)/pty/snap?sid=($sid)"
'
```

## Resize

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  let sid = (http get $"($base)/api/state" | get terminals.0.sid)
  {cols: 120, rows: 40} | to json | http post $"($base)/pty/resize?sid=($sid)" --content-type application/json
'
```

## Read the live raw stream

A tee of the raw output bytes (escape sequences and all) -- it streams until
the session closes, and is dropped when you disconnect:

```nushell
{{ bin | safe }} eval -c '
  let base = "{{ base | safe }}"
  let sid = (http get $"($base)/api/state" | get terminals.0.sid)
  http get $"($base)/pty/raw?sid=($sid)"
'
```
