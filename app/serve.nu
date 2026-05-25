# ghostty-web-nu sessions: server-projected 2-pane UI.
#
# Run:
#   http-nu --datastar --store ./store :5003 ~/ghostty-web-nu/serve-sessions.nu
#
# --store is required: durable UI state (title, per-tab canvas, last-focused
# sid) lives in the xs event log, not http-nu's in-memory `stor`.
#
# Endpoints:
#   GET  /                  -> static sessions.html shell
#   GET  /sse?connId=...    -> projected UX state stream (datastar patches)
#   POST /nav               -> publish selected sid on nav.events bus topic
#   POST /title             -> set the server-wide window title (signal: title)
#   POST /pty/create        -> mint a new pty + return sid
#   POST /pty/new           -> spawn a pty for the calling tab and select it
#   POST /pty/label         -> set the selected pty's label (meta.label)
#   POST /pty/close?sid=... -> destroy pty
#   POST /pty/input?sid=... -> raw input bytes to pty stdin
#   POST /pty/resize?sid=...-> resize pty (cols, rows in JSON body)
#   GET  /pty/view?sid=...  -> SSE of HTML grid frames (datastar morph)

use http-nu/datastar *

const STATIC = (path self | path dirname | path join "www")

# Durable UI state lives in the xs store (run with `--store ./store`), not
# `stor`. Each concern is a topic; the latest frame wins. This is the first
# step toward modelling sessions as clips in a stack (see ADR direction):
# the title becomes a stack property, canvases and focus become frames.
const TITLE_ADJ = [calm bold brave bright crisp eager fierce gentle happy keen lucky merry quiet swift wild]
const TITLE_NOUN = [otter sparrow fox heron stag panda lynx hare badger marten falcon ferret weasel mink]

# Window title: one evolving value as `ghostty.title` frames; latest wins.
# First read with no frame seeds a random adj-noun and persists it, so
# multiple hosts start out distinguishable.
def load-title []: nothing -> string {
  let f = (.last "ghostty.title")
  if ($f | is-empty) {
    let t = $"($TITLE_ADJ | shuffle | first)-($TITLE_NOUN | shuffle | first)"
    save-title $t
    $t
  } else {
    $f.meta.val
  }
}

def save-title [new: string]: nothing -> nothing {
  null | .append "ghostty.title" --meta {val: $new} --ttl forever | ignore
}

# Per-tab canvas content: `ghostty.canvas` frames keyed by meta.sid, body is
# the HTML (empty body = cleared). The latest frame for a sid wins.
def load-canvas [sid: string]: nothing -> string {
  if $sid == "" { return "" }
  let f = (.cat | where {|f| $f.topic == "ghostty.canvas" and (($f.meta.sid? | default "") == $sid) } | last)
  if ($f | is-empty) { return "" }
  if ($f.hash? | is-empty) { "" } else { (.cas $f.hash) }
}

def save-canvas [sid: string, html: string]: nothing -> nothing {
  if $sid == "" { return }
  $html | .append "ghostty.canvas" --meta {sid: $sid} --ttl forever | ignore
}

# Last sid the user navigated to, so out-of-process /canvas posters land on
# whichever tab is in front. `ghostty.focused` frames; latest wins.
def load-focused-sid []: nothing -> string {
  let f = (.last "ghostty.focused")
  if ($f | is-empty) { "" } else { ($f.meta.sid? | default "") }
}

def save-focused-sid [sid: string]: nothing -> nothing {
  null | .append "ghostty.focused" --meta {sid: $sid} --ttl forever | ignore
}

# --- terminal clips ----------------------------------------------------------
# A terminal "clip" is a durable marker in the log that a terminal belongs in
# this window. The live pty is ephemeral: bound to the clip by a clip_id tag
# in the pty's meta, and respawned fresh if the process is gone (e.g. after a
# server restart) -- zellij-style "remember where the panes were". Session
# state (scrollback) is not persisted; only the placement is.
#
#   clip.add     meta {type}        frame.id = clip_id
#   clip.delete  meta {clip_id}

# Clips still live: clip.add frames whose id has no matching clip.delete.
def live-clips []: nothing -> list {
  let deleted = (.cat | where {|f| $f.topic == "clip.delete" } | each {|f| $f.meta.clip_id? } | compact)
  .cat
  | where {|f| $f.topic == "clip.add" }
  | where {|f| $f.id not-in $deleted }
  | each {|f| {id: $f.id, type: ($f.meta.type? | default "terminal")} }
}

# Add a clip of the given type (terminal | note). A note's initial body
# (piped in) is CAS-stored on the frame. Returns the new clip id.
def add-clip [type: string = "terminal"]: any -> string {
  let body = $in
  let f = if ($body | is-empty) {
    null | .append "clip.add" --meta {type: $type} --ttl forever
  } else {
    $body | .append "clip.add" --meta {type: $type} --ttl forever
  }
  $f.id
}

def delete-clip [cid: string]: nothing -> nothing {
  null | .append "clip.delete" --meta {clip_id: $cid} --ttl forever | ignore
}

# Note body: the latest CAS body across the clip's add/update frames.
def note-body [cid: string]: nothing -> string {
  let f = (.cat
    | where {|f| ($f.topic == "clip.add" and $f.id == $cid) or ($f.topic == "clip.update" and (($f.meta.clip_id? | default "") == $cid)) }
    | last)
  if ($f | is-empty) { "" } else if (($f.hash? | default "") == "") { "" } else { (.cas $f.hash) }
}

def set-note-body [cid: string, body: string]: nothing -> nothing {
  $body | .append "clip.update" --meta {clip_id: $cid} --ttl forever | ignore
}

# Resolve the live pty sid bound to a terminal clip (meta.clip_id tag), or
# "" if none is alive. The bootstrap respawns one per terminal clip, so a
# terminal clip normally resolves; a clip whose child exited stays "" until
# the next reload (zellij-style: placement persists, process respawns).
def sid-for-clip [cid: string]: nothing -> string {
  let m = (pty list | where {|p| ($p.meta.clip_id? | default "") == $cid })
  if ($m | is-empty) { "" } else { $m | first | get sid }
}

# A clip's label persists as clip.patch {clip_id, label} frames; latest wins.
# This is what survives a respawn (the live pty's meta.label is ephemeral).
def clip-label [cid: string]: nothing -> string {
  let f = (.cat
    | where {|f| $f.topic == "clip.patch" and (($f.meta.clip_id? | default "") == $cid) }
    | last)
  if ($f | is-empty) { "" } else { ($f.meta.label? | default "") }
}

def set-clip-label [cid: string, label: string]: nothing -> nothing {
  null | .append "clip.patch" --meta {clip_id: $cid, label: $label} --ttl forever | ignore
}

# Spawn a pty for a clip and tag it (meta.clip_id) so it can be rebound to
# the same clip after a restart. Re-applies the clip's persisted label.
def spawn-for-clip [cid: string]: nothing -> string {
  let cmd = $env.GHOSTTY_WEB_NU_CMD? | default "nu"
  let sid = if $cmd == "nu" { pty open --embedded } else { pty open $cmd }
  pty meta set $sid "clip_id" $cid
  let lbl = (clip-label $cid)
  if ($lbl | is-not-empty) { pty meta set $sid "label" $lbl }
  $sid
}

# Render the left-pane session list as plain HTML. Returns a string suitable
# for `to datastar-patch-elements`. Dimensions live in the bottom-right meta
# corner of the focused pane (driven by the $focusedDims signal), not the
# sidebar labels.
def html-escape [s: string]: nothing -> string {
  $s | str replace -a '&' '&amp;' | str replace -a '<' '&lt;' | str replace -a '>' '&gt;'
}

# A clip's display label: its set label, else a type default.
def clip-display-label [c: record]: nothing -> string {
  let l = (clip-label $c.id)
  if ($l | is-not-empty) { $l } else if ($c.type == "note") { "note" } else { "nu" }
}

# Left-pane clip list, in creation order. Selection is keyed by clip id
# ($selectedSid holds the selected clip's id). Re-rendered on clip.events.
def render-list [clips: list, selected: string]: nothing -> string {
  let items = $clips | each {|c|
    let label = (clip-display-label $c)
    let cls = if $c.id == $selected { "selected" } else { "" }
    let icon = if ($c.type == "note") { "lucide:file-text" } else { "lucide:square-terminal" }
    let onclick = $"$sid = '($c.id)'; @post\('/nav'\)"
    let onclose = $"@post\('/clip/close?clip=($c.id)'\)"
    $"<li class='($cls)'><button type='button' class='row' data-on:click=\"($onclick)\"><iconify-icon icon='($icon)' class='row-icon'></iconify-icon>($label)<small>($c.id | str substring 0..8)</small></button><button type='button' class='close' data-on:click=\"($onclose)\" title='Close'>×</button></li>"
  } | str join ""
  $"<aside id='sessions-list'><header>Clips <button type='button' class='new-btn' data-on:click=\"$picking = true\" title='New clip'>+</button></header><ul>($items)</ul></aside>"
}

# Render one continuous-document pane for a clip, keyed by clip id. A
# terminal clip renders a fixed 24-row live grid (view stream by its bound
# sid, into #grid-<clip>); a note clip renders an editable body (textarea on
# focus, <pre> otherwise -- managed client-side). The active highlight is
# reactive on $selectedSid (the selected clip id).
def render-pane [c: record]: nothing -> string {
  let cid = $c.id
  let label = (clip-display-label $c)
  let head = $"<header class='pane-head'>($label)<small>($cid | str substring 0..8)</small></header>"
  let onsel = $"$sid = '($cid)'; @post\('/nav'\); window.__focusClip && window.__focusClip\('($cid)'\)"
  let body = if $c.type == "note" {
    let txt = (note-body $cid)
    let esc = (html-escape $txt)
    $"<div class='note-body'><pre class='note-pre'>($esc)</pre><textarea class='note-edit' spellcheck='false' style='display:none'>($esc)</textarea></div>"
  } else {
    let sid = (sid-for-clip $cid)
    if $sid == "" {
      "<div class='pane-screen pane-dead'>[exited]</div>"
    } else {
      let view = $"@get\('/pty/view?sid=($sid)&target=grid-($cid)&nosig=1', {openWhenHidden: true}\)"
      $"<div id='screen-($cid)' class='pane-screen' data-sid='($sid)' data-effect=\"($view)\"><div id='grid-($cid)'></div></div>"
    }
  }
  $"<section class='pane' id='pane-($cid)' data-clip='($cid)' data-kind='($c.type)' data-class:active=\"$selectedSid == '($cid)'\" data-on:click=\"($onsel)\">($head)($body)</section>"
}

# Full continuous document, every clip's pane stacked in creation order.
def render-doc [clips: list]: nothing -> string {
  let panes = $clips | each {|c| render-pane $c } | str join ""
  $"<div id='doc' class='doc'>($panes)</div>"
}

# "cols x rows" of the selected clip's terminal, or "" for notes / none.
def focused-dims [clips: list, selected: string]: nothing -> string {
  if $selected == "" { return "" }
  let sid = (sid-for-clip $selected)
  if $sid == "" { return "" }
  let p = pty list | where sid == $sid | first
  if $p == null { "" } else { $"($p.cols)x($p.rows)" }
}

{|req|
  let body = $in
  match [$req.method, $req.path] {

    [GET, "/"] => {
      {
        datastar_js_path: $DATASTAR_JS_PATH
        title: (load-title)
      } | .mj ($STATIC | path join "sessions.html")
    }

    [GET, "/sse"] => {
      # Datastar packs all signals into ?datastar={...} on GETs. Reconnects
      # (visibility-driven on v1.0+) replay current signal state, so we can
      # trust $signals.selectedSid to reflect the user's last selection.
      let signals = ("" | from datastar-signals $req)
      let prior_conn = ($signals.connId? | default "")
      let conn_id = if $prior_conn == "" { random uuid } else { $prior_conn }
      let requested_sid = ($signals.selectedSid? | default "")
      # docReady is replayed true on a reconnect (tab away/back). When true,
      # the client already has the panes and their view streams stayed open
      # (openWhenHidden), so re-rendering #doc would clobber the live grids
      # with empty ones. Only render the full #doc on a first connect.
      let doc_ready = ($signals.docReady? | default false)

      # Bootstrap. If the pty map is empty (fresh server start), respawn a
      # pty for every live *terminal* clip so they come back where they were;
      # if there are no clips at all, seed one terminal. Notes need no pty.
      # Selection is keyed by clip id: honor the requested one if it still
      # exists, else the first clip.
      if (pty list | is-empty) {
        if (live-clips | is-empty) {
          spawn-for-clip (add-clip "terminal") | ignore
        } else {
          for c in (live-clips | where type == "terminal") { spawn-for-clip $c.id | ignore }
        }
      }
      let clips0 = (live-clips)
      let clip_ids = ($clips0 | get id)
      let initial_sel = if ($requested_sid in $clip_ids) {
        $requested_sid
      } else {
        $clips0 | get id? | get 0? | default ""
      }
      save-focused-sid $initial_sel

      # Build a single stream: a synthetic init event first, then bus events
      # tagged by kind. (Using `prepend` rather than `append` so we don't
      # block on the bus before yielding the init -- append's input side is
      # eagerly drained by `interleave`'s schedulers, which would never
      # yield until something hits the bus.)
      (interleave
        { .bus sub "clip.events" | each {|e| {kind: "clip", val: $e.value}} }
        { .bus sub "nav.events"
            | where {|e| ($e.value.connId? | default "") == $conn_id}
            | each {|e| {kind: "nav", val: $e.value}} }
        { .bus sub "title.events"
            | where {|e| ($e.value.connId? | default "") != $conn_id}
            | each {|e| {kind: "title", val: $e.value}} }
        { .bus sub "canvas.events" | each {|e| {kind: "canvas", val: $e.value}} })
      | prepend {kind: "init", val: {}}
      | generate {|ev, state|
          let live = (live-clips)
          let live_ids = $live | get id
          # 1. Nav explicitly requested -- honor it.
          # 2. Otherwise, if our currently-selected clip disappeared (close),
          #    fall back to the first remaining clip (or "" for none).
          let new_sel = if $ev.kind == "nav" {
            $ev.val.sid
          } else if ($state.sel in $live_ids) {
            $state.sel
          } else {
            $live | get id? | get 0? | default ""
          }
          let new_dims = (focused-dims $live $new_sel)
          let new_title = if $ev.kind == "title" { $ev.val.title } else { $state.title }
          let list_patch = (render-list $live $new_sel
            | to datastar-patch-elements --selector "#sessions-list")
          let need_sel = ($ev.kind == "init") or ($new_sel != $state.sel)
          let sel_patch = if $need_sel {
            # Mark docReady on init so a later reconnect replays it and we skip
            # the #doc re-render (which would clobber the live grids).
            let base = {selectedSid: $new_sel, connId: $conn_id}
            let payload = if $ev.kind == "init" { $base | merge {docReady: true} } else { $base }
            ($payload | to datastar-patch-signals)
          } else { null }
          # Emit the focused-dims signal only when it actually changes so the
          # wire stays quiet during selection-only churn.
          let need_dims = ($ev.kind == "init") or ($new_dims != $state.dims)
          let dims_patch = if $need_dims {
            ({focusedDims: $new_dims} | to datastar-patch-signals)
          } else { null }
          # $title is the one-per-server window title. title.events is filtered
          # above so the typer's own connection doesn't get an echo back into
          # a focused <input>. Init seeds the signal so reconnects pick up the
          # current /tmp value.
          let need_title = ($ev.kind == "init") or ($new_title != $state.title)
          let title_patch = if $need_title {
            ({title: $new_title} | to datastar-patch-signals)
          } else { null }
          # Canvas: re-load from `stor` whenever the selected sid changes or
          # a canvas.events ping arrives. Other event kinds (pty/title) skip
          # the query. Patch outer-replaces #canvas; empty html -> bare
          # section (matches CSS :empty, collapses the column). Non-empty
          # wraps the html in a .canvas-content sibling so the resizer drag
          # strip has a stable home -- see .canvas-resizer in sessions.html.
          let should_reload = ($ev.kind == "init") or ($ev.kind == "canvas") or ($new_sel != $state.sel)
          let new_canvas = if $should_reload { load-canvas $new_sel } else { $state.canvas }
          let need_canvas = ($ev.kind == "init") or ($new_canvas != $state.canvas)
          let canvas_patch = if $need_canvas {
            let inner = if $new_canvas == "" {
              ""
            } else {
              $"<div class='canvas-resizer'></div><div class='canvas-content'>($new_canvas)</div>"
            }
            ($"<section id='canvas' class='canvas'>($inner)</section>"
             | to datastar-patch-elements --selector "#canvas")
          } else { null }
          # Continuous document. Init renders the whole #doc; a created
          # session appends just its pane; a died/deleted session removes
          # its pane. Never re-render the whole #doc on other events -- that
          # would morph empty grids over the live ones. Selection highlight
          # is reactive (data-class on $selectedSid), so nav needs no patch.
          let doc_patch = if ($ev.kind == "init" and (not $doc_ready)) {
            (render-doc $live | to datastar-patch-elements --selector "#doc")
          } else if ($ev.kind == "clip" and ($ev.val.event? == "added")) {
            let c = ($live | where id == ($ev.val.clip_id? | default "") | get 0?)
            if $c == null { null } else {
              (render-pane $c | to datastar-patch-elements --selector "#doc" --mode "append")
            }
          } else if ($ev.kind == "clip" and (($ev.val.event? | default "") == "deleted")) {
            ("<span></span>" | to datastar-patch-elements --selector $"#pane-($ev.val.clip_id)" --mode "remove")
          } else { null }
          let out = ([$sel_patch $dims_patch $title_patch $list_patch $canvas_patch $doc_patch] | where {|x| $x != null})
          {out: $out, next: {sel: $new_sel, dims: $new_dims, title: $new_title, canvas: $new_canvas}}
        } {sel: $initial_sel, dims: "", title: (load-title), canvas: (load-canvas $initial_sel)}
      | flatten
      | to sse
      | metadata set --content-type "text/event-stream"
    }

    [POST, "/nav"] => {
      let signals = $body | from datastar-signals $req
      let sid = ($signals.sid? | default "")
      if $sid != "" { save-focused-sid $sid }
      {
        connId: ($signals.connId? | default "")
        sid: $sid
      } | .bus pub "nav.events"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/new"] => {
      # Create a clip of ?type= (note | terminal), append its pane to every
      # connected doc (clip.events added), and select it for this connection.
      # A terminal also gets a freshly-spawned pty bound to it; a note lands
      # focused in its editable textarea (client-side, on select).
      let signals = $body | from datastar-signals $req
      let type = ($req.query.type? | default "note")
      let cid = if $type == "terminal" {
        let c = (add-clip "terminal")
        spawn-for-clip $c | ignore
        $c
      } else {
        "" | add-clip "note"
      }
      save-focused-sid $cid
      {event: "added", clip_id: $cid} | .bus pub "clip.events"
      {connId: ($signals.connId? | default ""), sid: $cid} | .bus pub "nav.events"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/update"] => {
      # Persist a note's body (clip.update -> CAS). Body is the raw textarea
      # contents; sent on blur.
      let cid = ($req.query.clip? | default "")
      let body = ($body | default "")
      if $cid != "" { set-note-body $cid $body }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/close"] => {
      # Tombstone the clip (won't respawn) and, if it's a terminal, kill its
      # pty. Broadcast clip.events deleted so every doc drops the pane.
      let cid = ($req.query.clip? | default "")
      if $cid != "" {
        let sid = (sid-for-clip $cid)
        if $sid != "" { pty close $sid }
        delete-clip $cid
        {event: "deleted", clip_id: $cid} | .bus pub "clip.events"
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/title"] => {
      # Set the per-server window title. Persist via `stor` so SSE reconnects
      # in the same server run see the right value; broadcast via
      # title.events so other tabs update document.title live. title.events
      # carries the originating connId; the /sse subscription filters out
      # matches so the typer doesn't get its own echo clobbering a focused
      # <input>.
      let signals = $body | from datastar-signals $req
      let new = ($signals.title? | default "" | str trim)
      save-title $new
      {connId: ($signals.connId? | default ""), title: $new} | .bus pub "title.events"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/pty/label"] => {
      # Rename a pty's left-pane label. The label lives in the pty session's
      # meta map; `pty meta set` mutates it and publishes a `pty.events {event:
      # meta}` ping, which the /sse handler already re-renders the list on.
      # No connId filtering needed -- the list is server-projected (button
      # text), not an input the typer is focused on.
      # $selectedSid is the selected clip id. Persist the label on the clip
      # (survives respawn) and mirror onto the live pty's meta if it's a
      # terminal with a bound pty. A clip.events ping re-renders the list.
      let signals = $body | from datastar-signals $req
      let cid = ($signals.selectedSid? | default "")
      let new = ($signals.label? | default "" | str trim)
      if $cid != "" {
        set-clip-label $cid $new
        let sid = (sid-for-clip $cid)
        if $sid != "" { pty meta set $sid "label" $new }
        {event: "labeled", clip_id: $cid} | .bus pub "clip.events"
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/canvas"] => {
      # External entry point for the canvas pane. Body becomes the canvas
      # content for the sid in ?sid=<sid>; empty body clears it. The html is
      # persisted in `stor` (per-tab, survives refresh) and `canvas.events`
      # is published so any /sse stream currently viewing that sid patches
      # immediately. In-process callers can skip the HTTP hop by calling
      # save-canvas directly and publishing {sid: ...} themselves.
      #
      # Dispatch on Content-Type so callers can lean on http-nu's renderers:
      #
      #   text/markdown               -> .md
      #   text/html (or unset)        -> raw HTML
      #   text/plain  + ?lang=<l>     -> .highlight <l>, wrapped in <pre>
      #   text/plain                  -> wrapped in <pre> as-is
      #
      #   curl -X POST -H 'content-type: text/markdown' --data-binary @r.md  localhost:5003/canvas
      #   curl -X POST -H 'content-type: text/plain' --data-binary @main.rs 'localhost:5003/canvas?lang=rust'
      #   curl -X POST localhost:5003/canvas    # clears the focused tab's canvas
      #
      # ?sid=<sid> targets a specific tab; without it, falls back to the
      # last-focused sid (updated whenever the user clicks a sidebar row or
      # spawns a tab). 400 if no tab has ever been focused.
      let qsid = ($req.query.sid? | default "" | str trim)
      let sid = if $qsid == "" { load-focused-sid } else { $qsid }
      if $sid == "" {
        "no focused sid" | metadata set { merge {'http.response': {status: 400}} }
      } else {
        let ct = (($req.headers | get "content-type" | default "") | split row ";" | get 0 | str trim | str downcase)
        let body_s = ($body | default "")
        let html = if $body_s == "" {
          ""
        } else {
          match $ct {
            "text/markdown" => ($body_s | .md | get __html)
            "text/plain" => {
              let lang = ($req.query.lang? | default "")
              if $lang != "" {
                $"<pre>($body_s | .highlight $lang)</pre>"
              } else {
                $"<pre>($body_s)</pre>"
              }
            }
            _ => $body_s   # text/html or unspecified: trust the caller
          }
        }
        save-canvas $sid $html
        {sid: $sid} | .bus pub "canvas.events"
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    }

    [POST, "/pty/input"] => {
      $body | pty write $req.query.sid
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/pty/resize"] => {
      let cfg = $body | from json
      pty resize $req.query.sid $cfg.cols $cfg.rows
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [GET, "/pty/view"] => {
      # target: morph-target element id (default 'grid'). nosig: suppress the
      # global term* signals -- set for continuous-document panes where many
      # views share the page. No params = single-focused behavior.
      let sid = $req.query.sid
      let target = ($req.query.target? | default "grid")
      let nosig = (($req.query.nosig? | default "") != "")
      # Pipe directly in each branch: binding the ByteStream to a `let` first
      # collects the (infinite) stream and hangs.
      if $nosig {
        pty view $sid --target $target --no-signals
        | metadata set --content-type "text/event-stream"
      } else {
        pty view $sid --target $target
        | metadata set --content-type "text/event-stream"
      }
    }

    _ => {
      let path = if $req.path == "/" { "/sessions.html" } else { $req.path }
      .static $STATIC $path
    }
  }
}
