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
#   stacks2099.focus {sid}                         last-focused clip (ttl last:1; out-of-proc /canvas)
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
use ./render.nu *   # pure render helpers (html-escape, is-url, clip-render-type, ...)

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
# clip in front. `stacks2099.focus` frames, ttl last:1 -- the store keeps only
# the most recent, so this latest-wins value never accumulates in the log.
def load-focused-sid []: nothing -> string {
  let f = (.last "stacks2099.focus")
  if ($f | is-empty) { "" } else { ($f.meta.sid? | default "") }
}

def save-focused-sid [sid: string]: nothing -> nothing {
  null | .append "stacks2099.focus" --meta {sid: $sid} --ttl last:1 | ignore
}

# --- stacks / clips ----------------------------------------------------------
# Phase 1: a single implicit stack. sort="manual" means `sorted-clips` orders
# by [position, id]; with positions unset that is just id order == creation
# order, matching the pre-projection behaviour.
def default-stack-id []: nothing -> string {
  let s = (.cat | where {|f| $f.topic == "stack.add" } | get 0?)
  if ($s | is-empty) {
    let f = (null | .append "stack.add" --meta {sort: "manual"} --ttl forever)
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

# Replace a clip's body (clip.update -> CAS). Body piped in as any bytes -- a
# note's text on blur, or an asset re-posted from the CLI. Mime is unchanged.
def set-clip-body [cid: string]: any -> nothing {
  $in | .append "clip.update" --meta {id: $cid} --ttl forever | ignore
}

# Reassign spaced positions to a stack's clips in the given order. Used to
# "freeze" an auto stack into manual, and to rebalance when a gap runs out.
def renumber-stack [order: list]: nothing -> nothing {
  $order | enumerate | each {|it|
    null | .append "clip.patch" --meta {id: $it.item.id, position: (($it.index + 1) * 65536)} --ttl forever
  } | ignore
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

# The URL an embed clip points at: first non-comment line of its body
# (text/uri-list is one URI per line, # comments; a plain URL note is one line).
def embed-url [c: record]: nothing -> string {
  (clip-body $c)
  | lines
  | where {|l| (($l | str trim | str length) > 0) and (not ($l | str trim | str starts-with "#")) }
  | get 0?
  | default ""
  | str trim
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
# Pure helpers (html-escape, is-url, clip-render-type, clip-display-label,
# icon-svg) live in ./render.nu; the body/pty-touching renderers stay here.

# Render a content clip's body by render type. Images use a blob URL (binary
# can't ride in the HTML string); text/markdown stay editable notes; text/html
# is trusted raw; other text is shown read-only; binary offers a download.
def render-content [c: record]: nothing -> string {
  let v = ($c.hash? | default "")
  match (clip-render-type $c) {
    "image" => $"<div class='clip-media'><img class='clip-img' src='/clip/blob?clip=($c.id)&v=($v)' alt='image clip'></div>"
    "embed" => {
      let url = (embed-url $c)
      let src = ((html-escape $url) | str replace -a "'" "%27")
      let bar = $"<div class='embed-bar'><a class='embed-url' href='($src)' target='_blank' rel='noopener'>(html-escape $url)</a><button type='button' class='mini-btn' data-on:click=\"@post\('/clip/view?clip=($c.id)&view=raw'\)\">raw</button></div>"
      $"<div class='clip-embed-wrap'>($bar)<iframe class='clip-embed' src='($src)' referrerpolicy='no-referrer'></iframe></div>"
    }
    "doc" => {
      # Rendered markdown (read-only). `.md` -> highlighted HTML; styled by
      # /md.css. "Edit" flips back to the raw editor.
      let html = (clip-body $c | .md | get __html)
      let edit = $"<button type='button' class='mini-btn' data-on:click=\"@post\('/clip/view?clip=($c.id)&view=raw'\)\">Edit</button>"
      $"<div class='clip-md'>($html)</div><div class='note-actions'>($edit)</div>"
    }
    "note" => {
      let body = (clip-body $c)
      let esc = (html-escape $body)
      # A markdown note offers a "Rendered" view; a note that's just a URL
      # offers an "Embed" view (live iframe).
      let btns = ([
        (if (($c.mime_type? | default "") == "text/markdown") { $"<button type='button' class='mini-btn' data-on:click=\"@post\('/clip/view?clip=($c.id)&view=rendered'\)\">Rendered ↗</button>" } else { "" })
        (if (is-url $body) { $"<button type='button' class='mini-btn' data-on:click=\"@post\('/clip/view?clip=($c.id)&view=embed'\)\">Embed ↗</button>" } else { "" })
      ] | where {|b| $b != "" } | str join " ")
      let actions = if ($btns == "") { "" } else { $"<div class='note-actions'>($btns)</div>" }
      # Display <pre> and editor <textarea> are siblings keyed by clip id. The
      # <pre> re-renders live on every clip.update; its visibility is reactive
      # on $noteEditing (the clip id being edited) so morph never fights an
      # inline display toggle. The textarea carries data-ignore-morph: morph
      # leaves it (and an unsaved draft) untouched, and the editor reseeds it
      # from the live <pre> on focus (see wireNotePane in sessions.html).
      $"<div class='note-body'><pre class='note-pre' id='note-pre-($c.id)' data-show=\"$noteEditing != '($c.id)'\">($esc)</pre><textarea class='note-edit' id='note-edit-($c.id)' data-ignore-morph spellcheck='false' style='display:none'>($esc)</textarea>($actions)</div>"
    }
    _ => {
      let m = ($c.mime_type? | default "")
      if $m == "text/html" {
        (clip-body $c)
      } else if ($m | str starts-with "text/") or $m == "application/json" {
        $"<pre class='clip-pre'>(html-escape (clip-body $c))</pre>"
      } else {
        $"<div class='clip-media'><a class='clip-file' href='/clip/blob?clip=($c.id)&v=($v)' download>($m | default 'download')</a></div>"
      }
    }
  }
}

def render-clip-row [c: record, selected: string]: nothing -> string {
  let label = (html-escape (clip-display-label $c))
  let cls = if $c.id == $selected { "selected" } else { "" }
  let onclick = $"$sid = '($c.id)'; @post\('/nav'\)"
  let onclose = $"@post\('/clip/close?clip=($c.id)'\)"
  $"<li class='($cls)'><button type='button' class='row' data-on:click=\"($onclick)\">(icon-svg (clip-render-type $c))($label)<small>($c.id | str substring 0..8)</small></button><button type='button' class='close' data-on:click=\"($onclose)\" title='Close'>×</button></li>"
}

# A stack row: click switches (stack.select), double-click renames (reuses the
# rename modal in 'stack' mode), × deletes. Name is carried in data-* so the
# dblclick handler reads it off the element rather than via string interpolation.
def render-stack-row [s: record, selected: string]: nothing -> string {
  let cls = if $s.id == $selected { "selected" } else { "" }
  # Stored name may be null; display falls back to the scru128 id. data-name
  # carries the *real* name (empty when unset) so rename starts from blank.
  let real = ($s.name? | default "")
  let display = (html-escape (if ($real | is-empty) { $s.id } else { $real }))
  let nm_attr = ((html-escape $real) | str replace -a "'" '&#39;')
  let onclick = $"@post\('/stack/select?stack=($s.id)'\)"
  let ondbl = "$draft = el.dataset.name; $renameStackId = el.dataset.stack; $renameMode = 'stack'; $renaming = true"
  let onclose = $"@post\('/stack/close?stack=($s.id)'\)"
  $"<li class='($cls)'><button type='button' class='row' data-stack='($s.id)' data-name='($nm_attr)' data-on:click=\"($onclick)\" data-on:dblclick=\"($ondbl)\">($display)</button><button type='button' class='close' data-on:click=\"($onclose)\" title='Delete stack'>×</button></li>"
}

# Far-left column: the stacks switcher. Stacks render most-recently-touched
# first (matching projection's selection order).
def render-stacks [proj: record]: nothing -> string {
  let sel_stack = ($proj.selectedStackId | default "")
  let items = ($proj.stacks | sort-by lastTouched | reverse | each {|s| render-stack-row $s $sel_stack } | str join "")
  $"<aside id='stacks-list'><header>Stacks <button type='button' class='new-btn' data-on:click=\"@post\('/stack/new'\)\" title='New stack'>+</button></header><ul class='stacks'>($items)</ul></aside>"
}

# Middle column: the selected stack's clip list (a navigator over the #doc).
# The header shows the stack's sort mode as a toggle (auto = activity order;
# manual = curated, set by moves).
def render-clips [proj: record]: nothing -> string {
  let v = (view-of $proj)
  let stack = ($proj.stacks | where id == $proj.selectedStackId | get 0?)
  let sort = if ($stack | is-empty) { "auto" } else { ($stack.sort | default "auto") }
  let sid = ($proj.selectedStackId | default "")
  let sort_btn = $"<button type='button' class='sort-btn' data-on:click=\"@post\('/stack/sort?stack=($sid)'\)\" title='Sort: ($sort) -- click to toggle'>($sort)</button>"
  let items = ($v.clips | each {|c| render-clip-row $c $v.sel } | str join "")
  $"<aside id='clips-list'><header>Clips ($sort_btn)<button type='button' class='new-btn' data-on:click=\"$picking = true\" title='New clip'>+</button></header><ul class='clips'>($items)</ul></aside>"
}

# Render one continuous-document pane for a clip, keyed by clip id. A terminal
# clip renders a live grid (view stream by its bound sid, into #grid-<clip>); a
# content clip renders an editable body (textarea on focus, <pre> otherwise --
# managed client-side). Active highlight is reactive on $selectedSid.
def render-pane [c: record]: nothing -> string {
  let cid = $c.id
  let label = (clip-display-label $c)
  # The pane-head has its own id so a label-only clip.patch on a terminal
  # can update just this header rather than re-morph the whole <section>
  # (which would wipe the live `<div id='grid-{cid}'>` underneath).
  let head = $"<header class='pane-head' id='pane-head-($cid)'>($label)<small>($cid | str substring 0..8)</small></header>"
  let onsel = $"$sid = '($cid)'; @post\('/nav'\); window.__focusClip && window.__focusClip\('($cid)'\)"
  let rtype = (clip-render-type $c)
  let body = if $c.kind == "terminal" {
    let sid = (sid-for-clip $cid)
    if $sid == "" {
      "<div class='pane-screen pane-dead'>[exited]</div>"
    } else {
      let view = $"@get\('/pty/view?sid=($sid)&target=grid-($cid)&nosig=1', {openWhenHidden: true}\)"
      $"<div id='screen-($cid)' class='pane-screen' data-sid='($sid)' data-effect=\"($view)\"><div id='grid-($cid)'></div></div>"
    }
  } else {
    (render-content $c)
  }
  # data-render tells the client how to mount: terminal grid, editable note, or
  # a static preview (image/file/html) it leaves alone.
  let render_attr = match $rtype { "terminal" => "terminal", "note" => "note", _ => "static" }
  $"<section class='pane' id='pane-($cid)' data-clip='($cid)' data-kind='($c.kind)' data-render='($render_attr)' data-class:active=\"$selectedSid == '($cid)'\" data-on:click=\"($onsel)\">($head)($body)</section>"
}

# Full continuous document, every clip's pane in render order. The layout-niri
# class is reactive on $docLayout, so a layout toggle reflows without re-morphing
# #doc (which would drop live grids) -- it just swaps the container's flex axis.
def render-doc [clips: list]: nothing -> string {
  let panes = $clips | each {|c| render-pane $c } | str join ""
  $"<div id='doc' class='doc' data-class:layout-niri=\"$docLayout === 'niri'\">($panes)</div>"
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

# The selected stack's pane layout ("flow" | "niri"); drives the #doc class.
def layout-of [proj: record]: nothing -> string {
  let stack = ($proj.stacks | where id == $proj.selectedStackId | get 0?)
  if ($stack | is-empty) { "flow" } else { ($stack.layout? | default "flow") }
}

# Display label of the currently selected clip. Driven into the `$label`
# signal so the rename modal can seed `$draft` from a signal instead of
# scraping the DOM.
def label-of [proj: record]: nothing -> string {
  let v = (view-of $proj)
  let c = ($v.clips | where id == $v.sel | get 0?)
  if ($c | is-empty) { "" } else { (clip-display-label $c) }
}

# Clip ids that should have a mounted pane right now: content clips always,
# terminal clips only once their pty is alive (so a just-added terminal whose
# pty is still spawning waits for the next tick rather than rendering dead).
def mountable [clips: list]: nothing -> list {
  $clips | where {|c| $c.kind == "content" or (sid-for-clip $c.id) != "" } | get id
}

# The stack id owning a clip (or null). Used to resolve "the current stack" for
# command-line adds from the persisted last-focused clip.
def clip-stack-of [proj: record, cid: string]: nothing -> any {
  let owner = ($proj.stacks | where {|s| ($s.clips | any {|c| $c.id == $cid }) } | get 0?)
  if ($owner | is-empty) { null } else { $owner.id }
}

# Resolve a target stack for an add. `want` may be a stack id, a stack name, or
# "" -- in which case fall back to the last-focused clip's stack, else the
# default stack. Unknown ids/names also fall back (never silently misfile).
def resolve-stack [proj: record, want: string]: nothing -> string {
  if $want != "" {
    if ($proj.stacks | any {|s| $s.id == $want }) { return $want }
    let byname = ($proj.stacks | where {|s| ($s.name? | default "") == $want } | get 0?)
    if ($byname | is-not-empty) { return $byname.id }
  }
  let fstack = (clip-stack-of $proj (load-focused-sid))
  if $fstack != null { $fstack } else { (default-stack-id) }
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
            let doc_order = (mountable $clips)

            let sel_stack = ($proj.selectedStackId | default "")
            let layout = (layout-of $proj)
            let label = (label-of $proj)
            let stacks_patch = (render-stacks $proj | to datastar-patch-elements --selector "#stacks-list")
            let clips_patch = (render-clips $proj | to datastar-patch-elements --selector "#clips-list")
            let doc_patch = if (not $doc_ready) {
              (render-doc $clips | to datastar-patch-elements --selector "#doc")
            } else { null }
            # docOrder: the sorted pane order the client applies by relocating
            # existing #doc nodes (preserves live terminal grids).
            let sel_patch = ({selectedSid: $sel, selectedStack: $sel_stack, connId: $conn_id, docReady: true, docOrder: ($doc_order | to json), docLayout: $layout, label: $label} | to datastar-patch-signals)
            let dims_patch = ({focusedDims: $dims} | to datastar-patch-signals)
            let title_patch = ({title: $title} | to datastar-patch-signals)
            let canvas_patch = (render-canvas $canvas | to datastar-patch-elements --selector "#canvas")

            let out = ([$sel_patch $dims_patch $title_patch $stacks_patch $clips_patch $canvas_patch $doc_patch] | where {|x| $x != null })
            {out: $out, next: {proj: $proj, ready: true, rendered: $doc_order, doc_order: $doc_order, title: $title, canvas: $canvas, sel: $sel, sel_stack: $sel_stack, dims: $dims, layout: $layout, label: $label}}

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
              # Sidebars: re-render only when a projection frame changed them.
              let stacks_patch = if $is_proj {
                (render-stacks $proj | to datastar-patch-elements --selector "#stacks-list")
              } else { null }
              let clips_patch = if $is_proj {
                (render-clips $proj | to datastar-patch-elements --selector "#clips-list")
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

              # Order changed (a move, a sort flip, or a new clip's slot): push
              # the sorted pane order; the client relocates existing #doc nodes.
              let docorder_patch = if $want != $st.doc_order { ({docOrder: ($want | to json)} | to datastar-patch-signals) } else { null }

              # Layout flip (flow <-> niri): toggle the #doc class reactively.
              let layout = (layout-of $proj)
              let layout_patch = if $layout != $st.layout { ({docLayout: $layout} | to datastar-patch-signals) } else { null }

              # Selected-clip display label: the rename modal seeds its draft
              # input from $label, so this signal has to track selection
              # changes and any clip.patch{label} that renamed the current
              # clip.
              let label = (label-of $proj)
              let label_patch = if $label != $st.label { ({label: $label} | to datastar-patch-signals) } else { null }

              # Re-render a clip's pane in place when its content or type
              # changes -- the add/remove above only tracks presence. A note
              # pane re-renders live too: its <pre> picks up the new body while
              # the editor textarea (data-ignore-morph) keeps any unsaved draft.
              # Special-case gates:
              #   * position-only clip.patch (renumber-stack, single move):
              #     skip; position is a sort key with no visible effect.
              #   * terminal clip (any kind): never re-emit the whole pane,
              #     because the body is `<div id='grid-{cid}'></div>` and
              #     idiomorph would morph that into the existing grid,
              #     wiping the live scrollback until /pty/view reconnects.
              #     Instead, when a terminal's label changed, patch just
              #     the `<header id='pane-head-{cid}'>` so the title
              #     updates without touching the screen.
              let repane = if ($topic in ["clip.update" "clip.patch"]) {
                let rid = ($ev.meta?.id? | default "")
                let rc = ($clips | where id == $rid | get 0?)
                let position_only = ($topic == "clip.patch") and (($ev.meta? | default {} | columns | where {|k| not ($k in ["id" "position"]) } | is-empty))
                let is_terminal = ($rc | is-not-empty) and ($rc.kind == "terminal")
                let label_touched = ($topic == "clip.patch") and (($ev.meta?.label? | default null) != null)
                if ($rc | is-not-empty) and ($rid in $rendered2) and (not $position_only) {
                  if $is_terminal {
                    if $label_touched {
                      let lbl = (html-escape (clip-display-label $rc))
                      ($"<header class='pane-head' id='pane-head-($rid)'>($lbl)<small>($rid | str substring 0..8)</small></header>" | to datastar-patch-elements --selector $"#pane-head-($rid)")
                    } else { null }
                  } else {
                    (render-pane $rc | to datastar-patch-elements --selector $"#pane-($rid)")
                  }
                } else { null }
              } else { null }

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

              let out = ([$stacks_patch $clips_patch]
                | append $add_patches
                | append $rm_patches
                | append [$repane $docorder_patch $layout_patch $label_patch $sel_patch $selstk_patch $dims_patch $canvas_patch $title_patch]
                | where {|x| $x != null })
              {out: $out, next: {proj: $proj, ready: true, rendered: $rendered2, doc_order: $want, title: $title, canvas: $canvas, sel: $sel, sel_stack: $sel_stack, dims: $dims, layout: $layout, label: $label}}
            }
          }
        } {proj: (projection empty), ready: false, rendered: [], doc_order: [], title: "", canvas: "", sel: "", sel_stack: "", dims: "", layout: "flow", label: ""}
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
      # Create a new (manual-sort) stack and switch to it. No name -- the UI
      # shows the stack's scru128 id until it's renamed.
      let f = (null | .append "stack.add" --meta {sort: "manual"} --ttl forever)
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

    [POST, "/stack/sort"] => {
      # Toggle a stack between auto (activity order) and manual (curated). When
      # switching to manual, freeze the current visual order into positions so
      # nothing jumps; switching to auto just flips the flag (positions ignored).
      let sid = ($req.query.stack? | default "")
      let proj = (.cat | projection project)
      let stack = ($proj.stacks | where id == $sid | get 0?)
      if ($stack | is-not-empty) {
        if $stack.sort == "auto" {
          renumber-stack (projection sorted-clips $stack)
          null | .append "stack.update" --meta {id: $sid, sort: "manual"} --ttl forever | ignore
        } else {
          null | .append "stack.update" --meta {id: $sid, sort: "auto"} --ttl forever | ignore
        }
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/stack/layout"] => {
      # Toggle a stack's pane layout between flow (vertical document column) and
      # niri (horizontal scrollable strip). Presentation only -- no reorder.
      let sid = ($req.query.stack? | default "")
      let proj = (.cat | projection project)
      let stack = ($proj.stacks | where id == $sid | get 0?)
      if ($stack | is-not-empty) {
        let next = if ($stack.layout? | default "flow") == "niri" { "flow" } else { "niri" }
        null | .append "stack.update" --meta {id: $sid, layout: $next} --ttl forever | ignore
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [POST, "/clip/move"] => {
      # Move the selected clip up/down within its stack. The first move in an
      # auto stack (or a manual one with unset positions) renumbers the whole
      # stack in the new order; after that each move is one position patch.
      let dir = ($req.query.dir? | default "")
      let cid = ($req.query.clip? | default "")
      let sid_stack = ($req.query.stack? | default "")
      let proj = (.cat | projection project)
      let stack = ($proj.stacks | where id == $sid_stack | get 0?)
      if $cid != "" and ($dir in ["up" "down"]) and ($stack | is-not-empty) {
        let clips = (projection sorted-clips $stack)
        let idx = ($clips | enumerate | where item.id == $cid | get 0?.index)
        let tgt = if $idx == null { -1 } else if $dir == "up" { $idx - 1 } else { $idx + 1 }
        if $idx != null and $tgt >= 0 and $tgt < ($clips | length) {
          let moved = ($clips | get $idx)
          let rest = ($clips | drop nth $idx)
          let new_order = ($rest | first $tgt | append $moved | append ($rest | skip $tgt))
          let needs_renumber = ($stack.sort != "manual") or ($clips | any {|c| ($c.position? | default null) == null })
          if $needs_renumber {
            if $stack.sort != "manual" { null | .append "stack.update" --meta {id: $stack.id, sort: "manual"} --ttl forever | ignore }
            renumber-stack $new_order
          } else {
            let ni = ($new_order | enumerate | where item.id == $cid | get 0.index)
            let prev = if $ni == 0 { null } else { ($new_order | get ($ni - 1) | get position?) }
            let next = if $ni == (($new_order | length) - 1) { null } else { ($new_order | get ($ni + 1) | get position?) }
            let newpos = (projection position-between $prev $next)
            if $newpos == null {
              renumber-stack $new_order
            } else {
              null | .append "clip.patch" --meta {id: $cid, position: $newpos} --ttl forever | ignore
            }
          }
        }
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [GET, "/clip/blob"] => {
      # Serve a clip's CAS body with its mime_type -- used by <img src> for
      # image clips and download links for other binaries.
      let cid = ($req.query.clip? | default "")
      let proj = (.cat | projection project)
      let c = ($proj.stacks | each {|s| $s.clips } | flatten | where id == $cid | get 0?)
      if ($c | is-empty) or (($c.hash? | default "") == "") {
        "not found" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        .cas $c.hash | metadata set --content-type ($c.mime_type? | default "application/octet-stream")
      }
    }

    [POST, "/clip/add"] => {
      # Add an asset to a stack from the raw request body -- the primary
      # command-line entry point. Mime comes from ?mime_type= or the
      # Content-Type header (so `curl -H 'content-type: image/png'` just
      # works); the target stack from ?stack= (id OR name), else the current
      # (last-focused) stack, else the default. Returns the new clip id.
      #
      #   curl --data-binary @diagram.png -H 'content-type: image/png' :5099/clip/add
      #   cat notes.md | curl --data-binary @- -H 'content-type: text/markdown' :5099/clip/add
      #   curl --data-binary @logo.svg -H 'content-type: image/svg+xml' ':5099/clip/add?stack=design'
      let ct = (($req.headers | get "content-type" | default "") | split row ";" | get 0 | str trim | str downcase)
      let mime = ($req.query.mime_type? | default (if $ct == "" { "application/octet-stream" } else { $ct }))
      let proj = (.cat | projection project)
      let stack = (resolve-stack $proj ($req.query.stack? | default ""))
      let cid = ($body | add-clip $stack "content" $mime)
      save-focused-sid $cid
      {} | .bus pub "clip.events"
      {id: $cid} | .bus pub "clip.select"
      $cid | metadata set { merge {'http.response': {status: 201}} }
    }

    [POST, "/clip/view"] => {
      # Toggle a clip's view between 'embed' (live <iframe>) and 'raw' (render
      # by mime). Persisted as clip.patch {view}; propagates via `.cat -f`.
      let cid = ($req.query.clip? | default "")
      let view = ($req.query.view? | default "")
      if $cid != "" and ($view in ["embed" "raw" "rendered"]) {
        null | .append "clip.patch" --meta {id: $cid, view: $view} --ttl forever | ignore
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    }

    [GET, "/api/state"] => {
      # Discovery for command-line tooling: stack ids/names + the current
      # (last-focused) stack, so scripts can target ?stack=<id|name>.
      let proj = (.cat | projection project)
      {
        focusedClip: (load-focused-sid)
        focusedStack: (clip-stack-of $proj (load-focused-sid))
        stacks: ($proj.stacks | each {|s| {id: $s.id, name: ($s.name? | default null), clips: ($s.clips | length)} })
      } | to json | metadata set --content-type "application/json"
    }

    [POST, "/clip/update"] => {
      # Replace an existing clip's body (clip.update -> CAS): a note's text on
      # blur, or any asset re-posted from the CLI --
      #   curl --data-binary @diagram.png 'localhost:5099/clip/update?clip=<id>'
      # Mime is unchanged; the clip's pane refreshes live. A note's editor
      # textarea is data-ignore-morph, so an open draft survives the refresh
      # (the <pre> picks up the new body underneath).
      let cid = ($req.query.clip? | default "")
      if $cid != "" { $body | set-clip-body $cid }
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

    [GET, "/md.css"] => {
      # Markdown-clip styling: the syntect highlight theme (generated by the
      # `.highlight` builtin, so it matches `.md`'s code classes) plus element
      # rules scoped to `.clip-md`. Vendored from the theme, not hand-painted.
      let theme = (try { .highlight theme "Monokai Extended" } catch { "" })
      let md = "
.clip-md { padding: .5rem 1rem; color: var(--term-fg); line-height: 1.6; overflow: auto; max-height: 42rem; }
.clip-md > :first-child { margin-top: 0; }
.clip-md h1, .clip-md h2, .clip-md h3, .clip-md h4 { line-height: 1.25; margin: 1.2rem 0 .6rem; font-weight: 600; }
.clip-md h1 { font-size: 1.5em; border-bottom: 1px solid var(--pane-border); padding-bottom: .2em; }
.clip-md h2 { font-size: 1.3em; border-bottom: 1px solid var(--pane-border); padding-bottom: .2em; }
.clip-md h3 { font-size: 1.15em; }
.clip-md p, .clip-md ul, .clip-md ol, .clip-md blockquote, .clip-md pre, .clip-md table { margin: .6rem 0; }
.clip-md a { color: #7cb7ff; }
.clip-md ul, .clip-md ol { padding-left: 1.5rem; }
.clip-md li { margin: .2rem 0; }
.clip-md code { font-family: var(--term-font); background: rgba(255,255,255,.08); padding: .1em .35em; border-radius: 3px; font-size: .9em; }
.clip-md pre { background: #0d0d0d; padding: .7rem .9rem; border-radius: 4px; overflow: auto; }
.clip-md pre code { background: none; padding: 0; }
.clip-md blockquote { padding-left: .9rem; border-left: 3px solid var(--pane-border); color: var(--dim); }
.clip-md table { border-collapse: collapse; }
.clip-md th, .clip-md td { border: 1px solid var(--pane-border); padding: .3em .6em; }
.clip-md img { max-width: 100%; }
.clip-md hr { border: 0; border-top: 1px solid var(--pane-border); }
"
      $"($theme)\n($md)" | metadata set --content-type "text/css"
    }

    _ => {
      let path = if $req.path == "/" { "/sessions.html" } else { $req.path }
      .static $STATIC $path
    }
  }
}
