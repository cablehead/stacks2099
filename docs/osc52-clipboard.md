# Research: OSC 52 clipboard (copy/paste) in wezterm-term

Status: research notes, not a decision. Captures what the wezterm-term we embed
exposes for clipboard escape sequences, the OSC 52 spec, and what wiring it into
stacks2099 would take. Nothing is wired today.

Pinned engine: `wezterm-term` git rev `577474d` (see `Cargo.toml`). Source paths
below are in the wezterm checkout (`~/wezterm`).

## What wezterm-term gives us

A `Clipboard` trait you implement and register on the `Terminal`:

```rust
// term/src/terminal.rs
pub enum ClipboardSelection { Clipboard, PrimarySelection }

pub trait Clipboard: Send + Sync {
    fn set_contents(&self, selection: ClipboardSelection, data: Option<String>)
        -> anyhow::Result<()>;
}
```

- Register with `Terminal::set_clipboard(&Arc<dyn Clipboard>)`
  (`term/src/terminalstate/mod.rs:608`). With none registered, OSC 52 set/clear
  are silent no-ops (`set_clipboard_contents`, `mod.rs:707`).
- On OSC 52 the performer (`term/src/terminalstate/performer.rs`) calls
  `set_contents`: `Some(text)` to SET, `None` to CLEAR.
- It collapses the richer selection set down to `Clipboard` / `PrimarySelection`
  via `selection_to_selection` (`performer.rs:1098`; anything that isn't `p`
  maps to `Clipboard`).

### Paste/query is NOT handled

`OperatingSystemCommand::QuerySelection(_) => {}` (`performer.rs:790`) -- a
`?` (read) request is dropped, no reply. So a program asking the terminal to
paste its clipboard gets nothing from wezterm-term. Supporting it means
intercepting the query ourselves and writing the base64 reply back to the pty.
This is the security-sensitive direction most terminals disable by default.

### Parsing

`wezterm-escape-parser/src/osc.rs` (`parse_selection`, ~line 169):

- base64-decodes the payload, yields `SetSelection(Selection, String)`.
- empty data field -> `ClearSelection`.
- `?` -> `QuerySelection`.
- `Selection` bitflags map the `Pc` chars: `c`=Clipboard, `p`=Primary,
  `s`=Select, `0`-`9`=cut buffers; empty `Pc` defaults to `s` + `0`
  (`osc.rs:78`, `Selection::try_parse` ~line 99). No `q` (secondary).
- It can also emit OSC 52 (`osc.rs:582`: `52;{Pc};{base64}`), useful if we ever
  answer a query.

## The OSC 52 spec (xterm)

```
OSC 52 ; Pc ; Pd ST
```

- `OSC` = `ESC ]` (or 0x9D); `ST` = `ESC \` (or BEL 0x07).
- `Pc` = clipboard selection: `c` clipboard, `p` primary, `q` secondary,
  `s` select, `0`-`7` cut buffers. Default `s0`.
- `Pd` = the operation:
  - base64 string -> SET the named clipboard(s) to that data.
  - `?` -> QUERY (paste): terminal replies `OSC 52 ; Pc ; <base64 of clipboard> ST`.
  - empty / invalid base64 -> CLEAR.

So: copy = base64 payload, paste = `?` (base64 reply), clear = empty.

## stacks2099 today

`src/pty.rs` registers no `Clipboard` (no `set_clipboard` call), so a program in
a pty emitting OSC 52 has no effect. The browser is the real clipboard owner in
projection mode.

### Sketch: program-driven copy -> browser clipboard

1. Implement `Clipboard::set_contents` to forward the text out of the pty
   session rather than to a system clipboard -- e.g. publish on the bus
   (`.bus pub "<sid>.clipboard"`) or stash it so a `/sse` patch can run
   `navigator.clipboard.writeText(...)` in the browser (needs a user gesture or
   the async Clipboard API permission).
2. Call `term.set_clipboard(Arc::new(...))` when the session is built
   (alongside the reader-thread setup in `open_*`).

### Paste (OSC 52 `?`)

Extra work: wezterm-term ignores the query, so we would intercept OSC 52 `?` and
write `OSC 52 ; Pc ; <base64> ST` back to the pty stdin ourselves. Gate it
(off by default) given the read-clipboard exfiltration risk.

## Related

- The pty raw-byte tee (`pty raw` / `GET /pty/raw`) is the easiest way to watch
  whether a program actually emits OSC 52: `\e]52;...` shows up in the stream.
- `/api/howto/drive-pty` documents driving a pty over HTTP.
