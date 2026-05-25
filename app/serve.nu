# stacks2099 sessions: server-projected UI, driven by the event log.
#
# Phase 1 of the stacks.nu parity port: the UI is now folded from the event
# log via ./projection.nu (single global state) instead of ad-hoc `.cat`
# re-queries. A "clip" gains a `kind` ("content" | "terminal"); terminal
# clips bind to a live pty (the only piece projection stays ignorant of).
#
# For Phase 1 there is ONE implicit stack (sort="manual", so render order ==
# creation order by id until Phase 3 introduces positions). Stacks grouping,
# auto-sort, and the content-type axes arrive in later phases.
#
# Run:
#   stacks2099 --dev 127.0.0.1:5099 --store ./dev-store
#
# Persistent topics (see ./projection.nu for the full schema):
#   stack.add {name, sort}                         frame.id = stack id
#   clip.add  {stack_id, kind, mime_type}          frame.id = clip id; body = CAS
#   clip.update {id}                               body -> new hash (note edits)
#   clip.patch  {id, label?, ...}                  field merge (rename, ...)
#   clip.delete {id}
#   ghostty.title {val}                            window title; latest wins
#   ghostty.canvas {sid}                           per-clip canvas html; body = CAS
#   ghostty.focused {sid}                          last-focused clip (out-of-proc /canvas)
# Ephemeral bus topics:
#   clip.select {id}|{action}                      global selection cursor
#   clip.events {}                                 "re-evaluate panes" nudge (post-spawn)
#   title.events {connId, title}                   live title echo (connId-filtered)
#   canvas.events {sid}                            canvas changed for a clip
#
# Endpoints:
#   GET  /                  -> static sessions.html shell
#   GET  /sse               -> projected UX state stream (datastar patches)
#   POST /nav               -> move the selection cursor (clip.select)
#   POST /clip/new?type=    -> create a clip (terminal | note) and select it
#   POST /clip/update?clip= -> persist a note body
#   POST /clip/close?clip=  -> tombstone a clip (+ kill its pty)
#   POST /pty/label         -> rename the selected clip
#   POST /title             -> set the window title
#   POST /canvas            -> external canvas-pane content (per clip)
#   POST /pty/input?sid=    -> raw input bytes to pty stdin
#   POST /pty/resize?sid=   -> resize pty (cols, rows in JSON body)
#   GET  /pty/view?sid=     -> SSE of HTML grid frames (datastar morph)

use http-nu/datastar *
use ./projection.nu

const STATIC = (path self | path dirname | path join "www")

# Window title: one evolving value as `ghostty.title` frames; latest wins.
const TITLE_ADJ = [calm bold brave bright crisp eager fierce gentle happy keen lucky merry quiet swift wild]
const TITLE_NOUN = [otter sparrow fox heron stag panda lynx hare badger marten falcon ferret weasel mink]

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

# Per-clip canvas content: `ghostty.canvas` frames keyed by meta.sid, body is
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

# Last clip the user selected, so out-of-process /canvas posters land on the
# clip in front. `ghostty.focused` frames; latest wins.
def load-focused-sid []: nothing -> string {
  let f = (.last "ghostty.focused")
  if ($f | is-empty) { "" } else { ($f.meta.sid? | default "") }
}

def save-focused-sid [sid: string]: nothing -> nothing {
  null | .append "ghostty.focused" --meta {sid: $sid} --ttl forever | ignore
}

# --- stacks / clips ----------------------------------------------------------
# Phase 1: a single implicit stack. sort="manual" means `sorted-clips` orders
# by [position, id]; with positions unset that is just id order == creation
# order, matching the pre-projection behaviour.
def default-stack-id []: nothing -> string {
  let s = (.cat | where {|f| $f.topic == "stack.add" } | get 0?)
  if ($s | is-empty) {
    let f = (null | .append "stack.add" --meta {name: "stack", sort: "manual"} --ttl forever)
    $f.id
  } else {
    $s.id
  }
}

# Add a clip of the given kind to a stack. A content clip's initial body
# (piped in) is CAS-stored on the frame. Returns the new clip id.
def add-clip [stack_id: string, kind: string, mime: string]: any -> string {
  let body = $in
  let meta = {stack_id: $stack_id, kind: $kind, mime_type: $mime}
  let f = if ($body | is-empty) {
    null | .append "clip.add" --meta $meta --ttl forever
  } else {
    $body | .append "clip.add" --meta $meta --ttl forever
  }
  $f.id
}

def delete-clip [cid: string]: nothing -> nothing {
  null | .append "clip.delete" --meta {id: $cid} --ttl forever | ignore
}

def set-note-body [cid: string, body: string]: nothing -> nothing {
  $body | .append "clip.update" --meta {id: $cid} --ttl forever | ignore
}

def set-clip-label [cid: string, label: string]: nothing -> nothing {
  null | .append "clip.patch" --meta {id: $cid, label: $label} --ttl forever | ignore
}

# A clip's persisted label (latest clip.patch{id,label}); "" if none. Used at
# spawn time, before projection state is in hand.
def clip-label [cid: string]: nothing -> string {
  let f = (.cat
    | where {|f| $f.topic == "clip.patch" and (($f.meta.id? | default "") == $cid) and (($f.meta.label? | default null) != null) }
    | last)
  if ($f | is-empty) { "" } else { ($f.meta.label? | default "") }
}

# A content clip's body: the CAS blob at its current hash, or "" for none.
def clip-body [c: record]: nothing -> string {
  if (($c.hash? | default "") == "") { "" } else { (.cas $c.hash) }
}

# Resolve the live pty sid bound to a terminal clip (meta.clip_id tag), or ""
# if none is alive. The bootstrap respawns one per terminal clip, so a
# terminal clip normally resolves; a clip whose child exited stays "" until
# the next reload (zellij-style: placement persists, process respawns).
def sid-for-clip [cid: string]: nothing -> string {
  let m = (pty list | where {|p| ($p.meta.clip_id? | default "") == $cid })
  if ($m | is-empty) { "" } else { $m | first | get sid }
}

# Spawn a pty for a clip and tag it (meta.clip_id) so it can be rebound to the
# same clip after a restart. Re-applies the clip's persisted label.
def spawn-for-clip [cid: string]: nothing -> string {
  let cmd = $env.GHOSTTY_WEB_NU_CMD? | default "nu"
  let sid = if $cmd == "nu" { pty open --embedded } else { pty open $cmd }
  pty meta set $sid "clip_id" $cid
  let lbl = (clip-label $cid)
  if ($lbl | is-not-empty) { pty meta set $sid "label" $lbl }
  $sid
}

# --- rendering ---------------------------------------------------------------
def html-escape [s: string]: nothing -> string {
  $s | str replace -a '&' '&amp;' | str replace -a '<' '&lt;' | str replace -a '>' '&gt;'
}

# A clip's display label: its set label, else a kind default.
def clip-display-label [c: record]: nothing -> string {
  let l = ($c.label? | default "")
  if ($l | is-not-empty) { $l } else if ($c.kind == "terminal") { "nu" } else { "note" }
}

# Inline SVG (vendored lucide icons) for a clip kind.
def icon-svg [kind: string]: nothing -> string {
  let a = "class='row-icon' xmlns='http://www.w3.org/2000/svg' width='1em' height='1em' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'"
  if $kind == "terminal" {
    $"<svg ($a)><path d='m7 11 2-2-2-2'/><path d='M11 13h4'/><rect width='18' height='18' x='3' y='3' rx='2'/></svg>"
  } else {
    $"<svg ($a)><path d='M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z'/><path d='M14 2v4a2 2 0 0 0 2 2h4'/><path d='M10 9H8'/><path d='M16 13H8'/><path d='M16 17H8'/></svg>"
  }
}

def render-clip-row [c: record, selected: string]: nothing -> string {
  let label = (html-escape (clip-display-label $c))
  let cls = if $c.id == $selected { "selected" } else { "" }
  let onclick = $"$sid = '($c.id)'; @post\('/nav'\)"
  let onclose = $"@post\('/clip/close?clip=($c.id)'\)"
  $"<li class='($cls)'><button type='button' class='row' data-on:click=\"($onclick)\">(icon-svg $c.kind)($label)<small>($c.id | str substring 0..8)</small></button><button type='button' class='close' data-on:click=\"($onclose)\" title='Close'>×</button></li>"
}

# A stack row: click switches (stack.select), double-click renames (reuses the
# rename modal in 'stack' mode), × deletes. Name is carried in data-* so the
# dblclick handler reads it off the element rather than via string interpolation.
def render-stack-row [s: record, selected: string]: nothing -> string {
  let cls = if $s.id == $selected { "selected" } else { "" }
  let nm = (html-escape ($s.name? | default "stack"))
  let nm_attr = ($nm | str replace -a "'" '&#39;')
  let onclick = $"@post\('/stack/select?stack=($s.id)'\)"
  let ondbl = "$draft = el.dataset.name; $renameStackId = el.dataset.stack; $renameMode = 'stack'; $renaming = true"
  let onclose = $"@post\('/stack/close?stack=($s.id)'\)"
  $"<li class='($cls)'><button type='button' class='row' data-stack='($s.id)' data-name='($nm_attr)' data-on:click=\"($onclick)\" data-on:dblclick=\"($ondbl)\">($nm)</button><button type='button' class='close' data-on:click=\"($onclose)\" title='Delete stack'>×</button></li>"
}

# The sidebar: a stacks switcher over the selected stack's clip list. Stacks
# render most-recently-touched first (matching projection's selection order).
def render-sidebar [proj: record]: nothing -> string {
  let sel_stack = ($proj.selectedStackId | default "")
  let v = (view-of $proj)
  let stack_items = ($proj.stacks | sort-by lastTouched | reverse | each {|s| render-stack-row $s $sel_stack } | str join "")
  let clip_items = ($v.clips | each {|c| render-clip-row $c $v.sel } | str join "")
  $"<aside id='sessions-list'><header>Stacks <button type='button' class='new-btn' data-on:click=\"@post\('/stack/new'\)\" title='New stack'>+</button></header><ul class='stacks'>($stack_items)</ul><header>Clips <button type='button' class='new-btn' data-on:click=\"$picking = true\" title='New clip'>+</button></header><ul class='clips'>($clip_items)</ul></aside>"
}

# Render one continuous-document pane for a clip, keyed by clip id. A terminal
# clip renders a live grid (view stream by its bound sid, into #grid-<clip>); a
# content clip renders an editable body (textarea on focus, <pre> otherwise --
# managed client-side). Active highlight is reactive on $selectedSid.
def render-pane [c: record]: nothing -> string {
  let cid = $c.id
  let label = (clip-display-label $c)
  let head = $"<header class='pane-head'>($label)<small>($cid | str substring 0..8)</small></header>"
  let onsel = $"$sid = '($cid)'; @post\('/nav'\); window.__focusClip && window.__focusClip\('($cid)'\)"
  let body = if $c.kind == "terminal" {
    let sid = (sid-for-clip $cid)
    if $sid == "" {
      "<div class='pane-screen pane-dead'>[exited]</div>"
    } else {
      let view = $"@get\('/pty/view?sid=($sid)&target=grid-($cid)&nosig=1', {openWhenHidden: true}\)"
      $"<div id='screen-($cid)' class='pane-screen' data-sid='($sid)' data-effect=\"($view)\"><div id='grid-($cid)'></div></div>"
    }
  } else {
    let esc = (html-escape (clip-body $c))
    $"<div class='note-body'><pre class='note-pre'>($esc)</pre><textarea class='note-edit' spellcheck='false' style='display:none'>($esc)</textarea></div>"
  }
  $"<section class='pane' id='pane-($cid)' data-clip='($cid)' data-kind='($c.kind)' data-class:active=\"$selectedSid == '($cid)'\" data-on:click=\"($onsel)\">($head)($body)</section>"
}

# Full continuous document, every clip's pane stacked in render order.
def render-doc [clips: list]: nothing -> string {
  let panes = $clips | each {|c| render-pane $c } | str join ""
  $"<div id='doc' class='doc'>($panes)</div>"
}

# Outer-replace markup for the #canvas pane. Empty html -> bare section
# (matches CSS :empty, collapses the column).
def render-canvas [html: string]: nothing -> string {
  let inner = if $html == "" {
    ""
  } else {
    $"<div class='canvas-resizer'></div><div class='canvas-content'>($html)</div>"
  }
  $"<section id='canvas' class='canvas'>($inner)</section>"
}

# "cols x rows" of the selected clip's terminal, or "" for content / none.
def focused-dims [clips: list, selected: string]: nothing -> string {
  if $selected == "" { return "" }
  let c = ($clips | where id == $selected | get 0?)
  if ($c | is-empty) or ($c.kind != "terminal") { return "" }
  let sid = (sid-for-clip $selected)
  if $sid == "" { return "" }
  let p = pty list | where sid == $sid | get 0?
  if ($p | is-empty) { "" } else { $"($p.cols)x($p.rows)" }
}

# The selected stack's clips in render order, plus the selected clip id.
def view-of [proj: record]: nothing -> record {
  let stack = ($proj.stacks | where id == $proj.selectedStackId | get 0?)
  let clips = if ($stack | is-empty) { [] } else { projection sorted-clips $stack }
  {clips: $clips, sel: ($proj.selectedClipId | default "")}
}

# Clip ids that should have a mounted pane right now: content clips always,
# terminal clips only once their pty is alive (so a just-added terminal whose
# pty is still spawning waits for the next tick rather than rendering dead).
def mountable [clips: list]: nothing -> list {
  $clips | where {|c| $c.kind == "content" or (sid-for-clip $c.id) != "" } | get id
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
      let signals = ("" | from datastar-signals $req)
      let prior_conn = ($signals.connId? | default "")
      let conn_id = if $prior_conn == "" { random uuid } else { $prior_conn }
      let requested_sid = ($signals.selectedSid? | default "")
      # docReady is replayed true on a reconnect (tab away/back): the panes and
      # their (openWhenHidden) view streams are still live client-side, so we
      # skip re-rendering #doc, which would clobber the live grids.
      let doc_ready = ($signals.docReady? | default false)

      # Bootstrap (synchronous, at connect). Ensure the default stack exists,
      # then if the pty map is empty (fresh server) respawn a pty per live
      # terminal clip; if there are no clips at all, seed one terminal.
      let stack_id = (default-stack-id)
      let boot = (.cat | projection project)
      let all_clips = ($boot.stacks | each {|s| $s.clips } | flatten)
      if (pty list | is-empty) {
        if ($all_clips | is-empty) {
          spawn-for-clip (add-clip $stack_id "terminal" "application/x-stacks-terminal") | ignore
        } else {
          for c in ($all_clips | where kind == "terminal") { spawn-for-clip $c.id | ignore }
        }
      }

      # Persistent frames come from `.cat -f` (history + xs.threshold + live
      # appends). Ephemeral nudges (selection, canvas/title pings, the post-
      # spawn "re-evaluate panes" tick) come from the in-process bus, wrapped
      # frame-shaped so apply-frame folds them uniformly.
      (null | interleave
        { .cat -f }
        { .bus sub | each {|e| {topic: $e.topic, id: (.id), hash: null, meta: $e.value}} })
      | generate {|ev, st|
          let topic = $ev.topic

          if $topic == "xs.threshold" {
            # Cold replay done. Wipe selection and reconcile to a default
            # (most-recently-touched), then honour the client's requested
            # selection if it still exists. Then emit the full initial render.
            let reset = ($st.proj
              | update selectedStackId null
              | update selectedClipId null
              | update selectionExplicit false
              | projection reconcile-selection)
            let proj = if $requested_sid != "" {
              (projection apply-frame $reset {topic: "clip.select", id: "req", hash: null, meta: {id: $requested_sid}}
               | projection reconcile-selection)
            } else { $reset }

            let v = (view-of $proj)
            let clips = $v.clips
            let sel = $v.sel
            let dims = (focused-dims $clips $sel)
            let title = (load-title)
            let canvas = (load-canvas $sel)

            let sel_stack = ($proj.selectedStackId | default "")
            let list_patch = (render-sidebar $proj | to datastar-patch-elements --selector "#sessions-list")
            let doc_patch = if (not $doc_ready) {
              (render-doc $clips | to datastar-patch-elements --selector "#doc")
            } else { null }
            let sel_patch = ({selectedSid: $sel, selectedStack: $sel_stack, connId: $conn_id, docReady: true} | to datastar-patch-signals)
            let dims_patch = ({focusedDims: $dims} | to datastar-patch-signals)
            let title_patch = ({title: $title} | to datastar-patch-signals)
            let canvas_patch = (render-canvas $canvas | to datastar-patch-elements --selector "#canvas")

            let out = ([$sel_patch $dims_patch $title_patch $list_patch $canvas_patch $doc_patch] | where {|x| $x != null })
            {out: $out, next: {proj: $proj, ready: true, rendered: (mountable $clips), title: $title, canvas: $canvas, sel: $sel, sel_stack: $sel_stack, dims: $dims}}

          } else if ($topic | str starts-with "xs.") {
            # Heartbeats and other system noise.
            {next: $st}

          } else {
            let proj_topics = [clip.add clip.update clip.delete clip.patch stack.add stack.update stack.delete clip.select stack.select clip.restore stack.restore]
            let is_proj = ($topic in $proj_topics)

            if (not $st.ready) {
              # Still buffering cold replay -- accumulate state, emit nothing.
              let proj = if $is_proj { (projection apply-frame $st.proj $ev) } else { $st.proj }
              {next: ($st | update proj $proj)}
            } else {
              let proj = if $is_proj { (projection apply-frame $st.proj $ev | projection reconcile-selection) } else { $st.proj }
              let v = (view-of $proj)
              let clips = $v.clips
              let sel = $v.sel
              let all_ids = ($clips | get id)

              let sel_stack = ($proj.selectedStackId | default "")
              # Sidebar: re-render only when a projection frame changed it.
              let list_patch = if $is_proj {
                (render-sidebar $proj | to datastar-patch-elements --selector "#sessions-list")
              } else { null }
              let selstk_patch = if $sel_stack != $st.sel_stack { ({selectedStack: $sel_stack} | to datastar-patch-signals) } else { null }

              # #doc reconcile (surgical -- never re-morph, to protect live
              # grids). Mount newly-ready clips; drop panes for gone clips.
              let want = (mountable $clips)
              let to_add = ($want | where {|id| $id not-in $st.rendered })
              let to_remove = ($st.rendered | where {|id| $id not-in $all_ids })
              let add_patches = ($to_add | each {|id|
                let c = ($clips | where id == $id | first)
                (render-pane $c | to datastar-patch-elements --selector "#doc" --mode "append")
              })
              let rm_patches = ($to_remove | each {|id|
                ("<span></span>" | to datastar-patch-elements --selector $"#pane-($id)" --mode "remove")
              })
              let rendered2 = (($st.rendered | where {|id| $id in $all_ids }) | append $to_add | uniq)

              # Reactive selection highlight + client focus.
              let sel_patch = if $sel != $st.sel { ({selectedSid: $sel} | to datastar-patch-signals) } else { null }

              let dims = (focused-dims $clips $sel)
              let dims_patch = if $dims != $st.dims { ({focusedDims: $dims} | to datastar-patch-signals) } else { null }

              # Canvas: reload on selection change or a canvas.events ping.
              let reload_canvas = ($sel != $st.sel) or ($topic == "canvas.events")
              let canvas = if $reload_canvas { (load-canvas $sel) } else { $st.canvas }
              let canvas_patch = if $canvas != $st.canvas {
                (render-canvas $canvas | to datastar-patch-elements --selector "#canvas")
              } else { null }

              # Title: live cross-tab echo via title.events, filtered so the
              # typer's own connection doesn't clobber its focused <input>.
              let title = if ($topic == "title.events") and (($ev.meta.connId? | default "") != $conn_id) {
                ($ev.meta.title? | default $st.title)
              } else { $st.title }
              let title_patch = if $title != $st.title { ({title: $title} | to datastar-patch-signals) } else { null }

              let out = ([$list_patch]
                | append $add_patches
                | append $rm_patches
                | append [$sel_patch $selstk_patch $dims_patch $canvas_patch $title_patch]
                | where {|x| $x != null })
              {out: $out, next: {proj: $proj, ready: true, rendered: $rendered2, title: $title, canvas: $canvas, sel: $sel, sel_stack: $sel_stack, dims: $dims}}
            }
          }
        } {proj: (projection empty), ready: false, rendered: [], title: "", canvas: "", sel: "", sel_stack: "", dims: ""}
      | flatten
      | to sse
      | metadata set --content-type "text/event-stream"
    }

    [POST, "/nav"] => {
      # Move the global selection cursor. clip.select is ephemeral (bus); the
      # /sse fold turns it into selectedClipId. Also persist ghostty.focused so
      # out-of-process /canvas posters land on the clip in front.
      let signals = $body | from datastar-signals $req
      let sid = ($signals.sid? | default "")
      if $sid != "" {
        save-focused-sid $sid
        {id: $sid} | .bus pub "clip.select"
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/new"] => {
      # Create a clip of ?type= (note | terminal) in the currently-selected
      # stack (carried in the $selectedStack signal; live selection isn't
      # persisted, so the client tells us). The clip.add frame propagates to
      # every /sse via `.cat -f`. A terminal also gets a freshly-spawned pty
      # bound to it; a `clip.events` nudge then prompts the streams to mount
      # its pane once the pty is live. Select the new clip.
      let signals = $body | from datastar-signals $req
      let target = ($signals.selectedStack? | default "")
      let stack = if $target == "" { (default-stack-id) } else { $target }
      let type = ($req.query.type? | default "note")
      let cid = if $type == "terminal" {
        let c = (add-clip $stack "terminal" "application/x-stacks-terminal")
        spawn-for-clip $c | ignore
        $c
      } else {
        "" | add-clip $stack "content" "text/markdown"
      }
      save-focused-sid $cid
      {} | .bus pub "clip.events"
      {id: $cid} | .bus pub "clip.select"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/stack/new"] => {
      # Create a new (manual-sort) stack and switch to it.
      let f = (null | .append "stack.add" --meta {name: "stack", sort: "manual"} --ttl forever)
      {id: $f.id} | .bus pub "stack.select"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/stack/select"] => {
      # Switch the global stack cursor (ephemeral; folded by /sse).
      let sid = ($req.query.stack? | default "")
      if $sid != "" { {id: $sid} | .bus pub "stack.select" }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/stack/rename"] => {
      # Rename a stack (persisted stack.update; propagates via `.cat -f`).
      let signals = $body | from datastar-signals $req
      let sid = ($signals.renameStackId? | default "")
      let nm = ($signals.draft? | default "" | str trim)
      if $sid != "" and $nm != "" {
        null | .append "stack.update" --meta {id: $sid, name: $nm} --ttl forever | ignore
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/stack/close"] => {
      # Delete a stack (and kill its terminal clips' ptys). Guarded so the last
      # stack can't be removed -- there must always be somewhere for clips.
      let sid = ($req.query.stack? | default "")
      let proj = (.cat | projection project)
      if $sid != "" and (($proj.stacks | length) > 1) {
        let st = ($proj.stacks | where id == $sid | get 0?)
        if ($st | is-not-empty) {
          for c in ($st.clips | where kind == "terminal") {
            let psid = (sid-for-clip $c.id)
            if $psid != "" { pty close $psid }
          }
        }
        null | .append "stack.delete" --meta {id: $sid} --ttl forever | ignore
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/update"] => {
      # Persist a note's body (clip.update -> CAS). Sent on blur.
      let cid = ($req.query.clip? | default "")
      let body = ($body | default "")
      if $cid != "" { set-note-body $cid $body }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/close"] => {
      # Tombstone the clip (won't respawn) and, if it's a terminal, kill its
      # pty. The clip.delete frame propagates via `.cat -f`; each /sse drops
      # the pane in its #doc reconcile.
      let cid = ($req.query.clip? | default "")
      if $cid != "" {
        let sid = (sid-for-clip $cid)
        if $sid != "" { pty close $sid }
        delete-clip $cid
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/pty/label"] => {
      # Rename the selected clip. The label persists on the clip (clip.patch),
      # which propagates via `.cat -f` so every sidebar re-renders. Mirror onto
      # the live pty's meta if it's a terminal with a bound pty.
      let signals = $body | from datastar-signals $req
      let cid = ($signals.selectedSid? | default "")
      let new = ($signals.label? | default "" | str trim)
      if $cid != "" {
        set-clip-label $cid $new
        let sid = (sid-for-clip $cid)
        if $sid != "" { pty meta set $sid "label" $new }
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/title"] => {
      # Set the per-server window title. Persist (ghostty.title) for reconnects
      # and broadcast (title.events, connId-tagged) so other tabs update live
      # without echoing back into the typer's focused <input>.
      let signals = $body | from datastar-signals $req
      let new = ($signals.title? | default "" | str trim)
      save-title $new
      {connId: ($signals.connId? | default ""), title: $new} | .bus pub "title.events"
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/canvas"] => {
      # External entry point for the canvas pane. Body becomes the canvas
      # content for the sid in ?sid=<sid> (empty body clears it); without it,
      # falls back to the last-focused clip. Dispatch on Content-Type:
      #
      #   text/markdown               -> .md
      #   text/html (or unset)        -> raw HTML
      #   text/plain  + ?lang=<l>     -> .highlight <l>, wrapped in <pre>
      #   text/plain                  -> wrapped in <pre> as-is
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
            _ => $body_s
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
      let sid = $req.query.sid
      let target = ($req.query.target? | default "grid")
      let nosig = (($req.query.nosig? | default "") != "")
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
