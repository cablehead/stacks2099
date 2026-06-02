# ADR 0006: Client-owned cursor

## Status

Draft.

## Context

Selection today is server-authoritative and shared across all connections. A
click or `j`/`k` POSTs `/nav`, which publishes `clip.select` to the in-process
bus; the `/sse` fold turns that into `selectedClipId`, runs `reconcile-selection`,
and patches `selectedSid` back to every client. So:

- The cursor round-trips: click -> `/nav` -> bus -> fold -> `selectedSid` patch
  -> highlight moves. A keystroke's feedback waits on the server.
- Selection is **shared**: tab A's `j`/`k` moves tab B's highlight, because every
  connection folds the same `clip.select` frames.
- The cursor does double duty -- it is both the per-viewport "where's my
  highlight" AND structural projection state (per-stack cursor memory,
  auto-select-new-clip, default-stack-on-connect).

Two problems. The round-trip is the focus-transition race ADR 0005 ran into
(keys after `mod+Enter` evaluated against stale state). And shared selection is
wrong for the model: focus is per-viewport -- two tabs on one session should
each have their own cursor, not drag each other around.

## Decision

The cursor is **client-owned and per-tab**. The client moves it instantly and
locally; the server is no longer in the selection loop. The server keeps only
the parts of "selection" that are genuinely workspace memory, fed by a
best-effort ping.

1. **`$selectedSid` is client state.** `j`/`k`, click, add, delete, and
   stack-arrival all set it locally via one `setCursor(id)` entry point. The
   highlight and the navigate-mode dim already react to it (`data-class:active`
   on panes). No POST gates the move.

2. **The highlight is reactive everywhere.** Today the `#doc` panes use a
   client-evaluated `data-class:active="$selectedSid == '<id>'"` expression, but
   the clips sidebar (`render-clip-row`) bakes a `selected` class into the HTML
   server-side. Make the sidebar use the same reactive expression, so the server
   never needs the cursor to render either surface. (Net deletion: the server
   stops threading `sel` into `render-clips`.)

3. **The server stops owning live selection.** Delete the `clip.select` bus
   publish + fold, the `selectedSid` patches from `/sse`, `reconcile-selection`'s
   live-cursor repair, and `/nav` as a selection route.

4. **Per-stack cursor memory stays server-side, fed by the ping.** The server
   still remembers each stack's last cursor (`clipCursors`), but sourced from the
   client's reported cursor rather than from `clip.select` frames. Switching
   stacks goes through the server (it changes the subscribed space); on arrival
   the server replays that stack's remembered cursor, and the client adopts it.
   So the cursor's authority is **client during a stack, server at the
   stack-switch boundary**.

5. **The cursor rides existing POSTs; no dedicated ping route.** The cursor is a
   Datastar signal, so it is already in the signals payload of any POST the
   client makes (focus-enter, clip add, stack switch, pty input...). The server
   reads it off whatever handler the client already hit and records it
   (`save-focused-sid` + `clipCursors`). Pure cursor movement (`j`/`k` with no
   other intent) sends nothing; `/api/state` is therefore best-effort -- it
   reflects the cursor as of the last server interaction, which is an acceptable
   answer to "what clip is in front."

6. **The client owns reconciliation.** When the focused clip is closed, the
   client picks the neighbour and moves its own cursor -- it has the rendered
   clip list and its own cursor, so it does this instantly without waiting for a
   server fold. Adding a clip sets the cursor to the new clip in the same action.

## What moves where

**Server keeps:** the workspace projection (stacks + their clips); per-stack
cursor memory (`clipCursors`), now fed by the reported cursor and replayed on
stack switch; `save-focused-sid` for `/api/state` and reconnect-landing.

**Server loses:** live selection authority -- `clip.select` fold + bus,
`selectedSid` patches, `reconcile-selection`'s live-cursor repair, `/nav` as a
selection route, and the server-baked `selected` class in `render-clip-row`
(becomes a reactive expression).

**Client gains:** `setCursor(id)` owning `$selectedSid`, called on
`j`/`k`/click/add/delete/stack-arrival; pick-next-on-delete; reporting its cursor
on the POSTs it already makes.

## Consequences

- **No focus-transition race.** The cursor never waits on the server, so keys
  after a transition evaluate against the cursor the client already moved.
- **Per-tab focus.** Two tabs on one session have independent cursors. Selection
  no longer broadcasts across connections.
- **Net deletion.** The projection shrinks to the workspace; the bus loses a
  topic; `/nav` goes away; both highlight surfaces collapse to one reactive
  mechanism.
- **`/api/state` is best-effort.** It is an out-of-band convenience, not a live
  UI driver, so a cursor that lags one server interaction is fine.
- **Stack switch is the one cursor round-trip**, and correctly so -- it changes
  the subscribed space, which only the server can do.

## Migration

1. Make the clips-sidebar highlight a reactive `data-class` expression; drop the
   `selected` arg from `render-clip-row` / `render-clips`.
2. Add client `setCursor(id)`; route `j`/`k`/click/add/delete through it.
3. Client picks next clip on close. (Add stays server-set: the id is
   server-minted, and the cursor patch must ride the same `/sse` stream as the
   new clip's markup so it can't race ahead of the pane existing. Only the
   per-tab scoping of that cursor patch changes -- deferred to step 5.)
4. Carry the cursor signal on existing POSTs; server reads it for `clipCursors`
   and `save-focused-sid`. Replay the stack's cursor on stack switch.
5. Delete `/nav` and the `clip.select` fold + bus publish; scope the add-cursor
   patch to the originating connection (no broadcast); remove live
   `reconcile-selection`.
6. Keep `clipCursors` and the stack-default reconcile (the non-cursor parts).
