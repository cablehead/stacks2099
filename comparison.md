# Comparison

How stacks2099 relates to neighbouring projects, read through
[the journey](./journey.md). Each project keeps the terminal's canonical
state in a different place, and that one choice drives most of the
differences below.

## Cate

[Cate](https://github.com/0-AI-UG/cate) is an Electron app with a
zoomable canvas of floating editor, terminal, and browser panels. Like
stacks2099, it treats a spatial surface as where your work lives. It
differs on where the terminal's canonical state is held.

|                   | stacks2099                | Cate                                                                 |
| ----------------- | ------------------------- | -------------------------------------------------------------------- |
| Terminal emulator | server (wezterm-term)     | client (xterm.js)                                                    |
| Canonical grid    | server                    | client                                                               |
| Over the wire     | HTML morph patches        | raw pty bytes                                                        |
| Remote unit       | the whole UI              | a headless byte-shipping daemon                                      |
| After a drop      | reattach to the live grid | old log replayed as inert text, drops you in a new pty (no reattach) |

**Where the grid lives.** Each terminal is an
[xterm.js](https://xtermjs.org) instance in Cate's renderer; the pty
(local, or remote via a daemon) proxies raw bytes up to it, so the
screen is built client-side. That is
[the proxy the journey starts from](./journey.md#xtermjs-plus-a-pty-proxy-no-buffer)
plus a [replay buffer](./journey.md#adding-a-replay-buffer): a rolling
on-disk log (1 to 2 MB, two-file rotation) replayed into a fresh
xterm.js on reconnect. So Cate sits at approach #2, and carries its
desync risk: the log replays from an arbitrary rotation boundary, which
can land mid-escape-sequence. stacks2099 left #2 for exactly this,
walking on to a
[server-side grid](./journey.md#a-small-vt100-proxy-on-the-server) and
then [projection](./journey.md#projecting-the-grid).

**Reaching it remotely.** stacks2099 serves its UI over HTTP, so you
open it in a browser. Cate's UI is a local desktop app, so the container
holds only a byte-shipping daemon and there is no URL to open.

**Across a disconnect.**

- **stacks2099** keeps the grid on the server next to the pty, so the
  session runs whether or not anyone is attached. A build finishes while
  your laptop is shut, and you reopen on the live result.
- **Cate** cannot reattach, and the work does not survive. The daemon is
  a child of the SSH channel (no `nohup`/`setsid`), so once the dropped
  connection is noticed it and its ptys are killed and the job stops.
  Reconnecting spawns a new pty and replays the on-disk log as inert
  text, so you come back to a transcript of a dead session.
