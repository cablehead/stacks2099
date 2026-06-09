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
#   stacks2099.focus {sid}                         last-focused clip (ttl last:1)
# Ephemeral bus topics:
#   clip.select {id}|{action}                      cursor on add/reconnect (client owns live moves)
#   clip.events {}                                 "re-evaluate panes" nudge (post-spawn)
#   title.events {connId, title}                   live title echo (connId-filtered)
#
# Endpoints:
#   GET  /                  -> 302 redirect to /stack/<current stack>
#   GET  /stack/:id         -> the sessions shell for one stack (MPA page)
#   GET  /sse?stack=<id>    -> projected UX state stream for that stack (datastar)
#   POST /nav               -> best-effort cursor ping (persists focused clip)
#   POST /clip/new?type=    -> create a clip (terminal | note) and select it
#   POST /clip/update?clip= -> persist a note body
#   POST /clip/close?clip=  -> tombstone a clip (+ kill its pty)
#   POST /clip/label?clip=  -> rename a clip (label=)
#   POST /title             -> set the window title
#   POST /pty/input?sid=    -> raw input bytes to pty stdin
#   POST /pty/resize?sid=   -> resize pty (cols, rows in JSON body)
#   GET  /pty/view?sid=     -> SSE of HTML grid frames (datastar morph)

use http-nu/datastar *
use http-nu/router *
use ./projection.nu
use ./render.nu *   # pure render helpers (html-escape, is-url, clip-render-type, ...)

const STATIC = (path self | path dirname | path join "www")
# Markdown API docs, served at /api and /api/howto/:topic. Baked into the
# binary alongside this script (include_dir), so they travel with it.
const API_DOCS = (path self | path dirname | path join "api")

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

# Last clip the user selected, used on reconnect to land on the right stack and
# reported by /api/state. `stacks2099.focus` frames, ttl last:1 -- the store
# keeps only the most recent, so this latest-wins value never accumulates.
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

# Add a clip of the given kind to a stack. The body (piped in) is CAS-stored on
# the frame -- streamed: .append is first in the pipe so it consumes the input
# implicitly (an empty body just appends no CAS hash). Returns the new clip id.
def add-clip [stack_id: string, kind: string, mime: string]: any -> string {
  .append "clip.add" --meta {stack_id: $stack_id, kind: $kind, mime_type: $mime} --ttl forever | get id
}

def delete-clip [cid: string]: nothing -> nothing {
  null | .append "clip.delete" --meta {id: $cid} --ttl forever | ignore
}

# Replace a clip's body (clip.update -> CAS). Body piped in as any bytes -- a
# note's text on blur, or an asset re-posted from the CLI. Mime is unchanged.
def set-clip-body [cid: string]: any -> nothing {
  .append "clip.update" --meta {id: $cid} --ttl forever | ignore
}

# Reassign spaced positions to a stack's clips in the given order. Used to
# "freeze" an auto stack into manual, and to rebalance when a gap runs out.
def renumber-stack [order: list]: nothing -> nothing {
  $order | enumerate | each {|it|
    null | .append "clip.patch" --meta {id: $it.item.id, position: (($it.index + 1) * 65536)} --ttl forever
  } | ignore
}

# Position a just-added clip directly after `after_cid` in its stack's manual
# order (below it in flow, to its right in niri). `proj` is the projection from
# BEFORE the add, so its clips are the existing order. No-op for an auto stack
# (recency decides the slot) or an unknown/empty cursor (the clip keeps the
# default slot). Mirrors the move route: renumber if positions are unset or a
# gap runs out, else a single position patch.
def place-after [proj: record, stack_id: string, new_cid: string, after_cid: string]: nothing -> nothing {
  let stack = ($proj.stacks | where id == $stack_id | get 0?)
  if ($stack | is-empty) or ($stack.sort? != "manual") or ($after_cid == "") { return }
  let existing = (projection sorted-clips $stack)
  let idx = ($existing | enumerate | where item.id == $after_cid | get 0?.index)
  if $idx == null { return }
  let new_order = (($existing | first ($idx + 1)) | append {id: $new_cid} | append ($existing | skip ($idx + 1)))
  if ($existing | any {|c| ($c.position? | default null) == null }) {
    renumber-stack $new_order
  } else {
    let prev = ($existing | get $idx | get position?)
    let next = if ($idx + 1) >= ($existing | length) { null } else { ($existing | get ($idx + 1) | get position?) }
    let newpos = (projection position-between $prev $next)
    if $newpos == null {
      renumber-stack $new_order
    } else {
      null | .append "clip.patch" --meta {id: $new_cid, position: $newpos} --ttl forever | ignore
    }
  }
}

def set-clip-label [cid: string, label: string]: nothing -> nothing {
  null | .append "clip.patch" --meta {id: $cid, label: $label} --ttl forever | ignore
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

# True when a live pty session has this sid. The /pty GET routes guard on it so
# a stale, wrong, or missing sid returns a clean 404 instead of letting the pty
# command error mid-handler (which http-nu surfaces as an opaque 500 "channel
# closed").
def pty-sid-live [sid: string]: nothing -> bool {
  ($sid != "") and (pty list | where sid == $sid | is-not-empty)
}

# This instance's base URL, derived from the request, so the served API docs
# show the address the caller actually reached us on instead of a placeholder.
# Honors X-Forwarded-Proto when fronted by a proxy; falls back to the doc's
# literal example if the Host header is somehow absent.
def api-base [req: record]: nothing -> string {
  let host = ($req.headers | get host? | default "127.0.0.1:5099")
  let scheme = ($req.headers | get "x-forwarded-proto"? | default "http")
  $"($scheme)://($host)"
}

# Spawn a pty for a clip and tag it (meta.clip_id) so it can be rebound to the
# same clip after a restart. Re-applies the clip's persisted label.
def spawn-for-clip [cid: string]: nothing -> string {
  let cmd = $env.GHOSTTY_WEB_NU_CMD? | default "nu"
  let sid = if $cmd == "nu" { pty open --embedded } else { pty open $cmd }
  pty meta set $sid "clip_id" $cid
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
    "note" => {
      # Editable text. Two orthogonal axes (see ADR/notes):
      #   view (style): raw <pre> source, or rendered markdown HTML. Persisted
      #     as `view`, cycled by mod+K v. This is what shows when NOT focused.
      #   focus: the source <textarea> takes the keyboard, replacing the view.
      #     Reactive on $noteEditing (the focused clip id).
      # The styled view and the textarea are siblings keyed by clip id. The view
      # shows while $noteEditing != this clip; the textarea shows while it ==. The
      # view re-renders live on clip.update; the textarea carries data-ignore-morph
      # so morph leaves an in-flight draft untouched (reseeded from source on focus,
      # see wireNotePane). data-render stays 'note' regardless of style so the
      # client always wires the editor.
      let body = (clip-body $c)
      let esc = (html-escape $body)
      let styled = if (note-style $c) == "rendered" {
        let html = (clip-body $c | .md | get __html)
        $"<div class='clip-md note-view' id='note-view-($c.id)' data-show=\"$noteEditing != '($c.id)'\">($html)</div>"
      } else {
        $"<pre class='note-pre note-view' id='note-view-($c.id)' data-show=\"$noteEditing != '($c.id)'\">($esc)</pre>"
      }
      # Clicks inside the open editor (e.g. repositioning the caret) are editor
      # clicks, not pane-select clicks -- stop them bubbling to the pane handler
      # so editing a note isn't interrupted by the select gesture.
      $"<div class='note-body'>($styled)<textarea class='note-edit' id='note-edit-($c.id)' data-ignore-morph spellcheck='false' style='display:none' data-on:click=\"evt.stopPropagation\(\)\">($esc)</textarea></div>"
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

# The `selected` highlight is reactive on the client's $cursor signal (the
# same mechanism the #doc panes use via data-class:active), so the server never
# bakes it in -- it just emits every row and the client decides which is current.
def render-clip-row [c: record]: nothing -> string {
  let label = (html-escape (clip-display-label $c))
  # Set the cursor signal locally (instant reactive highlight), then ping the
  # server so it can remember the stack's cursor + answer /api/state.
  let onclick = $"$cursor = '($c.id)'; @post\('/nav'\)"
  let onclose = $"@post\('/clip/close?clip=($c.id)'\)"
  $"<li data-clip='($c.id)' data-class:selected=\"$cursor == '($c.id)'\"><button type='button' class='row' data-on:click=\"($onclick)\">(icon-svg (clip-render-type $c))($label)<small>(id-tail $c.id)</small></button><button type='button' class='close' data-on:click=\"($onclose)\" title='Close'>×</button></li>"
}

# A stack row: click navigates to that stack's page, double-click renames (reuses the
# rename modal in 'stack' mode), × deletes. Name is carried in data-* so the
# dblclick handler reads it off the element rather than via string interpolation.
def render-stack-row [s: record, selected: string]: nothing -> string {
  let cls = if $s.id == $selected { "selected" } else { "" }
  # Stored name may be null; display falls back to the scru128 id. data-name
  # carries the *real* name (empty when unset) so rename starts from blank.
  let real = ($s.name? | default "")
  let display = (html-escape (if ($real | is-empty) { (id-tail $s.id) } else { $real }))
  let nm_attr = ((html-escape $real) | str replace -a "'" '&#39;')
  # MPA: switching stacks is navigation -- go to that stack's page.
  let onclick = $"window.location = '/stack/($s.id)'"
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

# Stack-switcher rows: the same stacks as the rail, rendered as picker-rows for
# the top-left switcher overlay (the rail is hidden in niri, so this is how you
# switch/create stacks there). Selecting closes the overlay; the current stack
# is marked active. A trailing "New stack" row keeps creation reachable.
def render-stack-switcher [proj: record]: nothing -> string {
  let sel = ($proj.selectedStackId | default "")
  let rows = ($proj.stacks | sort-by lastTouched | reverse | each {|s|
    let real = ($s.name? | default "")
    let display = (html-escape (if ($real | is-empty) { (id-tail $s.id) } else { $real }))
    let active = if $s.id == $sel { " active" } else { "" }
    $"<button type='button' class='picker-row($active)' data-on:click=\"window.location = '/stack/($s.id)'\">($display)</button>"
  } | str join "")
  let newrow = $"<button type='button' class='picker-row' data-on:click=\"$stackPicking = false; @post\('/stack/new'\)\"><svg class='icon' xmlns='http://www.w3.org/2000/svg' width='1em' height='1em' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M5 12h14'/><path d='M12 5v14'/></svg> New stack</button>"
  $"<div id='stack-switcher'>($rows)($newrow)</div>"
}

# Selected stack's display name (real name, or the id when unnamed); "" when no
# stack. Drives the top-bar breadcrumb signal so you can see which stack you're
# on even in niri, where the rail (and its selection highlight) is gone.
def stack-name-of [proj: record]: nothing -> string {
  let sel = ($proj.selectedStackId | default "")
  let s = ($proj.stacks | where id == $sel | get 0?)
  if ($s | is-empty) { "" } else {
    let real = ($s.name? | default "")
    if ($real | is-empty) { (id-tail $sel) } else { $real }
  }
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
  let items = ($v.clips | each {|c| render-clip-row $c } | str join "")
  $"<aside id='clips-list'><header>Clips ($sort_btn)<button type='button' class='new-btn' data-on:click=\"$picking = true\" title='New clip'>+</button></header><ul class='clips'>($items)</ul></aside>"
}

# Render one continuous-document pane for a clip, keyed by clip id. A terminal
# clip renders a live grid (view stream by its bound sid, into #grid-<clip>); a
# content clip renders an editable body (textarea on focus, <pre> otherwise --
# managed client-side). Active highlight is reactive on $cursor.
def render-pane [c: record]: nothing -> string {
  let cid = $c.id
  let label = (clip-display-label $c)
  # The pane-head has its own id so a label-only clip.patch on a terminal
  # can update just this header rather than re-morph the whole <section>
  # (which would wipe the live `<div id='grid-{cid}'>` underneath).
  let head = $"<header class='bar pane-head' id='pane-head-($cid)'>($label)<small>(id-tail $cid)</small></header>"
  let rtype = (clip-render-type $c)
  # Every click selects (cursor highlight + /nav). What follows depends on the
  # clip: a terminal focuses on the single click so you can type immediately (no
  # separate gesture -- typing IS the point of clicking a terminal); a document
  # only selects, and editing is the explicit gesture (double-click or mod+Enter
  # on the selection). __paneClicked drops focus mode back to navigate so a plain
  # select after editing is consistent.
  let select = $"$cursor = '($cid)'; @post\('/nav'\)"
  let onfocus = $"window.__focusClip && window.__focusClip\('($cid)'\)"
  let onsel = if $c.kind == "terminal" {
    $"($select); ($onfocus)"
  } else {
    $"($select); window.__paneClicked && window.__paneClicked\(\)"
  }
  let body = if $c.kind == "terminal" {
    let sid = (sid-for-clip $cid)
    if $sid == "" {
      "<div class='pane-screen pane-dead'>[exited]</div>"
    } else {
      let view = $"@get\('/pty/view?sid=($sid)&target=grid-($cid)', {openWhenHidden: true}\)"
      $"<div id='screen-($cid)' class='pane-screen' data-pty='($sid)' data-effect=\"($view)\"><div id='grid-($cid)'></div></div>"
    }
  } else {
    (render-content $c)
  }
  # data-render tells the client how to mount: terminal grid, editable note, or
  # a static preview (image/file/html) it leaves alone.
  let render_attr = match $rtype { "terminal" => "terminal", "note" => "note", _ => "static" }
  $"<section class='pane' id='pane-($cid)' data-clip='($cid)' data-kind='($c.kind)' data-render='($render_attr)' data-class:active=\"$cursor == '($cid)'\" data-on:click=\"($onsel)\" data-on:dblclick=\"($onfocus)\">($head)($body)</section>"
}

# Full continuous document, every clip's pane in render order. The layout-niri
# class is reactive on $docLayout, so a layout toggle reflows without re-morphing
# #doc (which would drop live grids) -- it just swaps the container's flex axis.
def render-doc [clips: list]: nothing -> string {
  let panes = $clips | each {|c| render-pane $c } | str join ""
  $"<div id='doc' class='doc' data-class:layout-niri=\"$docLayout === 'niri'\">($panes)</div>"
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

# Does a live clip with this id exist? The by-id routes use it to 404 on an
# unknown clip instead of a silent 204 -- the UI crops ids to the tail, so a
# caller pasting what it sees would otherwise no-op and look like it worked.
def clip-exists [cid: string]: nothing -> bool {
  if ($cid | is-empty) { return false }
  (clip-stack-of (.cat | projection project) $cid) != null
}

# A 404 response body for an unknown clip id, mirroring the /pty/* routes.
def no-such-clip [cid: string]: nothing -> any {
  $"no such clip: ($cid)" | metadata set { merge {'http.response': {status: 404}} }
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
  dispatch $req [
    (route {method: "GET", path: "/"} {|req ctx|
      # MPA: each stack is its own page (/stack/<id>). Bounce the bare root to
      # the current stack (focused, else default) so the address bar always
      # shows which stack you're on.
      let cur = (resolve-stack (.cat | projection project) "")
      "" | metadata set { merge {'http.response': {status: 302 headers: {location: $"/stack/($cur)"}}} }
    })

    (route {method: "GET", path-matches: "/stack/:id"} {|req ctx|
      # The shell for one stack. The stack id rides in the URL; the client reads
      # it (slice 2 scopes /sse to it). An unknown id still serves the shell --
      # /sse will fall back to the default stack.
      {
        datastar_js_path: $DATASTAR_JS_PATH
        title: (load-title)
        stack_id: $ctx.id
      } | .mj ($STATIC | path join "sessions.html")
    })

    (route {method: "GET", path: "/sse"} {|req ctx|
      let signals = ("" | from datastar-signals $req)
      let prior_conn = ($signals.connId? | default "")
      let conn_id = if $prior_conn == "" { random uuid } else { $prior_conn }
      let requested_sid = ($signals.cursor? | default "")
      # MPA: the page is /stack/<id>, so the client opens /sse?stack=<id>. This
      # connection shows that stack (the fold still tracks every stack for now;
      # scoping the fold itself is a later slice).
      let requested_stack = ($req.query.stack? | default "")
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
      # appends). Ephemeral nudges (selection, title pings, the post-spawn
      # "re-evaluate panes" tick) come from the in-process bus, wrapped
      # frame-shaped so apply-frame folds them uniformly.
      (null | interleave
        { .cat -f }
        { .bus sub | each {|e| {topic: $e.topic, id: (.id), hash: null, meta: $e.value}} })
      | generate {|ev, st|
          let topic = $ev.topic

          if $topic == "xs.threshold" {
            # Cold replay done. Select the stack the URL asked for (the page is
            # /stack/<id>), then reconcile -- which fills in that stack's clip
            # cursor. If no/unknown stack was requested, fall back to the default
            # (most-recently-touched). Then honour the client's requested clip
            # selection if it still exists. Then emit the full initial render.
            let with_stack = if $requested_stack != "" {
              ($st.proj
                | update selectedStackId $requested_stack
                | update selectedClipId null
                | update selectionExplicit true)
            } else {
              ($st.proj
                | update selectedStackId null
                | update selectedClipId null
                | update selectionExplicit false)
            }
            let reset = ($with_stack | projection reconcile-selection)
            let proj = if $requested_sid != "" {
              (projection apply-frame $reset {topic: "clip.select", id: "req", hash: null, meta: {id: $requested_sid}}
               | projection reconcile-selection)
            } else { $reset }

            let v = (view-of $proj)
            let clips = $v.clips
            let sel = $v.sel
            let title = (load-title)
            let doc_order = (mountable $clips)

            let sel_stack = ($proj.selectedStackId | default "")
            let stack_name = (stack-name-of $proj)
            let layout = (layout-of $proj)
            let stacks_patch = (render-stacks $proj | to datastar-patch-elements --selector "#stacks-list")
            let switcher_patch = (render-stack-switcher $proj | to datastar-patch-elements --selector "#stack-switcher")
            let clips_patch = (render-clips $proj | to datastar-patch-elements --selector "#clips-list")
            let doc_patch = if (not $doc_ready) {
              (render-doc $clips | to datastar-patch-elements --selector "#doc")
            } else { null }
            # docOrder: the sorted pane order the client applies by relocating
            # existing #doc nodes (preserves live terminal grids).
            let sel_patch = ({cursor: $sel, selectedStack: $sel_stack, stackName: $stack_name, connId: $conn_id, docReady: true, docOrder: ($doc_order | to json), docLayout: $layout} | to datastar-patch-signals)
            let title_patch = ({title: $title} | to datastar-patch-signals)

            let out = ([$sel_patch $title_patch $stacks_patch $switcher_patch $clips_patch $doc_patch] | where {|x| $x != null })
            {out: $out, next: {proj: $proj, ready: true, rendered: $doc_order, doc_order: $doc_order, title: $title, sel: $sel, sel_stack: $sel_stack, stack_name: $stack_name, layout: $layout}}

          } else if ($topic | str starts-with "xs.") {
            # Heartbeats and other system noise.
            {next: $st}

          } else {
            # stack.select is gone (MPA: switching stacks is navigation, a fresh
            # /sse?stack=<id> connection -- not a folded selection frame).
            let proj_topics = [clip.add clip.update clip.delete clip.patch stack.add stack.update stack.delete clip.select clip.restore stack.restore]
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
              let stack_name = (stack-name-of $proj)
              # Sidebars: re-render only when a projection frame changed them.
              let stacks_patch = if $is_proj {
                (render-stacks $proj | to datastar-patch-elements --selector "#stacks-list")
              } else { null }
              let switcher_patch = if $is_proj {
                (render-stack-switcher $proj | to datastar-patch-elements --selector "#stack-switcher")
              } else { null }
              let clips_patch = if $is_proj {
                (render-clips $proj | to datastar-patch-elements --selector "#clips-list")
              } else { null }
              let selstk_patch = if $sel_stack != $st.sel_stack { ({selectedStack: $sel_stack} | to datastar-patch-signals) } else { null }
              # Breadcrumb name: tracks selection and a rename of the current stack.
              let stackname_patch = if $stack_name != $st.stack_name { ({stackName: $stack_name} | to datastar-patch-signals) } else { null }

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
                # remove is selector-only per the datastar SSE spec (no elements).
                ("" | to datastar-patch-elements --selector $"#pane-($id)" --mode "remove")
              })
              let rendered2 = (($st.rendered | where {|id| $id in $all_ids }) | append $to_add | uniq)

              # Order changed (a move, a sort flip, or a new clip's slot): push
              # the sorted pane order; the client relocates existing #doc nodes.
              let docorder_patch = if $want != $st.doc_order { ({docOrder: ($want | to json)} | to datastar-patch-signals) } else { null }

              # Layout flip (flow <-> niri): toggle the #doc class reactively.
              let layout = (layout-of $proj)
              let layout_patch = if $layout != $st.layout { ({docLayout: $layout} | to datastar-patch-signals) } else { null }

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
                      ($"<header class='bar pane-head' id='pane-head-($rid)'>($lbl)<small>(id-tail $rid)</small></header>" | to datastar-patch-elements --selector $"#pane-head-($rid)")
                    } else { null }
                  } else {
                    (render-pane $rc | to datastar-patch-elements --selector $"#pane-($rid)")
                  }
                } else { null }
              } else { null }

              # Reactive selection highlight + client focus.
              let sel_patch = if $sel != $st.sel { ({cursor: $sel} | to datastar-patch-signals) } else { null }

              # Title: live cross-tab echo via title.events, filtered so the
              # typer's own connection doesn't clobber its focused <input>.
              let title = if ($topic == "title.events") and (($ev.meta.connId? | default "") != $conn_id) {
                ($ev.meta.title? | default $st.title)
              } else { $st.title }
              let title_patch = if $title != $st.title { ({title: $title} | to datastar-patch-signals) } else { null }

              let out = ([$stacks_patch $switcher_patch $clips_patch]
                | append $add_patches
                | append $rm_patches
                | append [$repane $docorder_patch $layout_patch $sel_patch $selstk_patch $stackname_patch $title_patch]
                | where {|x| $x != null })
              {out: $out, next: {proj: $proj, ready: true, rendered: $rendered2, doc_order: $want, title: $title, sel: $sel, sel_stack: $sel_stack, stack_name: $stack_name, layout: $layout}}
            }
          }
        } {proj: (projection empty), ready: false, rendered: [], doc_order: [], title: "", sel: "", sel_stack: "", stack_name: "", layout: "flow"}
      | flatten
      | to sse
      | metadata set --content-type "text/event-stream"
    })

    (route {method: "POST", path: "/nav"} {|req ctx|
      # The client owns the cursor ($cursor signal). This is a best-effort ping
      # so the server can persist the focused clip (reconnect landing +
      # /api/state). It does NOT publish clip.select / re-fold selection: the
      # client already moved $cursor locally, and echoing it back would re-render
      # the sidebars mid-click and clobber the cursor (the morph race).
      let body = $in
      let signals = $body | from datastar-signals $req
      let sid = ($signals.cursor? | default "")
      if $sid != "" { save-focused-sid $sid }
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "POST", path: "/clip/new"} {|req ctx|
      # Create a clip of ?type= (note | terminal) in the currently-selected
      # stack (carried in the $selectedStack signal; live selection isn't
      # persisted, so the client tells us). The clip.add frame propagates to
      # every /sse via `.cat -f`. A terminal also gets a freshly-spawned pty
      # bound to it; a `clip.events` nudge then prompts the streams to mount
      # its pane once the pty is live. Select the new clip.
      let body = $in
      let signals = $body | from datastar-signals $req
      let target = ($signals.selectedStack? | default "")
      let cursor = ($signals.cursor? | default "")
      # Resolve against real stacks (id or name), falling back to the focused or
      # default stack. Never trust the raw signal -- an unknown value would home
      # the clip to a non-existent stack, which the projection drops, leaving a
      # live pty bound to no stack (an orphan you can't see or close in the UI).
      let proj = (.cat | projection project)
      let stack = (resolve-stack $proj $target)
      let type = ($req.query.type? | default "note")
      let cid = if $type == "terminal" {
        let c = (add-clip $stack "terminal" "application/x-stacks-terminal")
        spawn-for-clip $c | ignore
        $c
      } else {
        "" | add-clip $stack "content" "text/markdown"
      }
      # Land the new clip directly after the selected one (below in flow, right
      # in niri) rather than at the top/bottom. `proj` predates the add, so it
      # holds the existing order.
      place-after $proj $stack $cid $cursor
      save-focused-sid $cid
      {} | .bus pub "clip.events"
      {id: $cid} | .bus pub "clip.select"
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "POST", path: "/stack/new"} {|req ctx|
      # Create a new (manual-sort) stack. No name -- the UI shows the stack's
      # scru128 id until it's renamed. A browser (datastar) gets a redirect SSE
      # to the new stack's page (MPA: the stack is its own URL). A scripted
      # caller sending `Accept: application/json` gets {id} instead, so it can
      # target the new stack without scraping the redirect script out of HTML.
      let f = (null | .append "stack.add" --meta {sort: "manual"} --ttl forever)
      # datastar asks for `text/event-stream, text/html, application/json`, so
      # the redirect wins whenever event-stream is on the list. JSON is only for
      # a caller that asks for it without event-stream (a plain script).
      let accept = ($req.headers | get accept? | default "")
      let wants_json = ($accept | str contains "application/json") and (not ($accept | str contains "text/event-stream"))
      if $wants_json {
        {id: $f.id} | to json | metadata set { merge {'http.response': {status: 201, headers: {"content-type": "application/json"}}} }
      } else {
        $"/stack/($f.id)" | to datastar-redirect | to sse | metadata set --content-type "text/event-stream"
      }
    })

    (route {method: "POST", path: "/stack/rename"} {|req ctx|
      # Rename a stack (persisted stack.update; propagates via `.cat -f`).
      let body = $in
      let signals = $body | from datastar-signals $req
      let sid = ($signals.renameStackId? | default "")
      let nm = ($signals.draft? | default "" | str trim)
      if $sid != "" and $nm != "" {
        null | .append "stack.update" --meta {id: $sid, name: $nm} --ttl forever | ignore
      }
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "POST", path: "/stack/close"} {|req ctx|
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
    })

    (route {method: "POST", path: "/stack/sort"} {|req ctx|
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
    })

    (route {method: "POST", path: "/stack/layout"} {|req ctx|
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
    })

    (route {method: "POST", path: "/clip/move"} {|req ctx|
      # Reorder or relocate a clip. Keyed by ?clip=; the source stack is derived
      # from the clip, so callers don't pass it. Modes:
      #   ?dir=up|down   one step within its stack (the GUI path)
      #   ?to=<n>        absolute 0-based index within the destination stack
      #   ?stack=<dest>  move to another stack (id or name); ?to= places it, else
      #                  it appends and the destination's own sort decides the slot
      # An ordered placement (?to=, or an in-stack ?dir=) freezes the destination
      # to manual sort, the same as the first drag/move in the UI does. The first
      # ordered move in an auto stack (or a manual one with unset positions)
      # renumbers the whole stack; after that each move is one position patch.
      let cid = ($req.query.clip? | default "")
      let dir = ($req.query.dir? | default "")
      let to_raw = ($req.query.to? | default "")
      let to = if $to_raw == "" { null } else { (try { $to_raw | into int } catch { null }) }
      let dest_q = ($req.query.stack? | default "")
      let proj = (.cat | projection project)
      let src = ($proj.stacks | where {|s| $s.clips | any {|c| $c.id == $cid }} | get 0?)
      let dest_id = if $dest_q == "" {
        ($src.id? | default "")
      } else if ($proj.stacks | any {|s| $s.id == $dest_q }) {
        $dest_q
      } else {
        ($proj.stacks | where {|s| ($s.name? | default "") == $dest_q } | get 0?.id | default "")
      }
      let dest = ($proj.stacks | where id == $dest_id | get 0?)
      if $cid == "" or ($src | is-empty) {
        no-such-clip $cid
      } else if ($dest | is-empty) {
        $"no such stack: ($dest_q)" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        let cross = ($dest_id != $src.id)
        let moved = ($src.clips | where id == $cid | get 0)
        if $cross and ($to == null) {
          # Plain relocation: hand the clip to the destination, let its sort place it.
          null | .append "clip.patch" --meta {id: $cid, stack_id: $dest_id} --ttl forever | ignore
        } else {
          # Ordered placement. `base` is the destination's clips without the moved
          # one; we insert at `ti` and re-derive positions.
          let base = if $cross { (projection sorted-clips $dest) } else { (projection sorted-clips $src | where id != $cid) }
          let n = ($base | length)
          let ti = if $to != null {
            let lo = ([$to 0] | math max)
            ([$lo $n] | math min)
          } else if (not $cross) and ($dir in ["up" "down"]) {
            let full = (projection sorted-clips $src)
            let cur = ($full | enumerate | where item.id == $cid | get 0?.index | default (-1))
            if $dir == "up" { $cur - 1 } else { $cur + 1 }
          } else { (-1) }
          if $ti >= 0 and $ti <= $n {
            let new_order = (($base | first $ti) | append $moved | append ($base | skip $ti))
            let needs_renumber = ($dest.sort != "manual") or ($base | any {|c| ($c.position? | default null) == null })
            if $dest.sort != "manual" { null | .append "stack.update" --meta {id: $dest_id, sort: "manual"} --ttl forever | ignore }
            if $needs_renumber {
              if $cross { null | .append "clip.patch" --meta {id: $cid, stack_id: $dest_id} --ttl forever | ignore }
              renumber-stack $new_order
            } else {
              let ni = ($new_order | enumerate | where item.id == $cid | get 0.index)
              let prev = if $ni == 0 { null } else { ($new_order | get ($ni - 1) | get position?) }
              let next = if $ni == (($new_order | length) - 1) { null } else { ($new_order | get ($ni + 1) | get position?) }
              let newpos = (projection position-between $prev $next)
              if $newpos == null {
                if $cross { null | .append "clip.patch" --meta {id: $cid, stack_id: $dest_id} --ttl forever | ignore }
                renumber-stack $new_order
              } else {
                let meta = if $cross { {id: $cid, stack_id: $dest_id, position: $newpos} } else { {id: $cid, position: $newpos} }
                null | .append "clip.patch" --meta $meta --ttl forever | ignore
              }
            }
          }
        }
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "GET", path: "/clip/blob"} {|req ctx|
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
    })

    (route {method: "POST", path: "/clip/add"} {|req ctx|
      # Add an asset to a stack from the raw request body -- the primary
      # command-line entry point. Mime comes from ?mime_type= or the
      # Content-Type header (so `curl -H 'content-type: image/png'` just
      # works); the target stack from ?stack= (id OR name), else the current
      # (last-focused) stack, else the default. Optional ?view= sets the display
      # style (embed | raw | rendered). Returns the new clip id.
      #
      #   curl --data-binary @diagram.png -H 'content-type: image/png' :5099/clip/add
      #   cat notes.md | curl --data-binary @- -H 'content-type: text/markdown' :5099/clip/add
      #   curl --data-binary @logo.svg -H 'content-type: image/svg+xml' ':5099/clip/add?stack=design'
      let body = $in
      let ct = (($req.headers | get "content-type" | default "") | split row ";" | get 0 | str trim | str downcase)
      let mime = ($req.query.mime_type? | default (if $ct == "" { "application/octet-stream" } else { $ct }))
      let proj = (.cat | projection project)
      let stack = (resolve-stack $proj ($req.query.stack? | default ""))
      let cid = ($body | add-clip $stack "content" $mime)
      # Optional ?view= sets the display style at creation (e.g. a markdown clip
      # straight to `rendered`, a URL note to `embed`), saving a round-trip to
      # /clip/view. Unknown values are ignored -- the clip keeps its default.
      let view = ($req.query.view? | default "")
      if ($view in ["embed" "raw" "rendered"]) {
        null | .append "clip.patch" --meta {id: $cid, view: $view} --ttl forever | ignore
      }
      save-focused-sid $cid
      {} | .bus pub "clip.events"
      {id: $cid} | .bus pub "clip.select"
      $cid | metadata set { merge {'http.response': {status: 201}} }
    })

    (route {method: "POST", path: "/clip/view"} {|req ctx|
      # Set a clip's view style explicitly. Persisted as clip.patch {view};
      # propagates via `.cat -f`.
      let cid = ($req.query.clip? | default "")
      let view = ($req.query.view? | default "")
      if not (clip-exists $cid) {
        no-such-clip $cid
      } else {
        if ($view in ["embed" "raw" "rendered"]) {
          null | .append "clip.patch" --meta {id: $cid, view: $view} --ttl forever | ignore
        }
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "POST", path: "/clip/view/cycle"} {|req ctx|
      # Cycle a clip's view style (mod+K v). For markdown today: raw <-> rendered.
      # Other text has only raw, so this is a no-op there. Orthogonal to focus.
      let cid = ($req.query.clip? | default "")
      let proj = (.cat | projection project)
      let clip = ($proj.stacks | each {|s| $s.clips } | flatten | where id == $cid | get 0?)
      if ($clip | is-empty) {
        no-such-clip $cid
      } else {
        if (($clip.mime_type? | default "") == "text/markdown") {
          let next = if (($clip.view? | default "") == "rendered") { "raw" } else { "rendered" }
          null | .append "clip.patch" --meta {id: $cid, view: $next} --ttl forever | ignore
        }
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "GET", path: "/api"} {|req ctx|
      # Self-describing API overview (markdown). Travels with the binary so any
      # running instance documents itself: curl <base>/api. Rendered as a
      # minijinja template so `{{ base }}` resolves to this instance's address.
      {base: (api-base $req), bin: $nu.current-exe} | .mj ($API_DOCS | path join "index.md")
      | metadata set --content-type "text/markdown; charset=utf-8"
    })

    (route {method: "GET", path-matches: "/api/howto/:topic"} {|req ctx|
      # Individual howto docs linked from /api. Topic is one path segment;
      # restrict it to a slug so it can't escape the docs dir.
      let topic = ($ctx.topic? | default "")
      let file = ($API_DOCS | path join $"($topic).md")
      if ($topic =~ '^[a-z0-9-]+$') and ($file | path exists) {
        {base: (api-base $req), bin: $nu.current-exe} | .mj $file
        | metadata set --content-type "text/markdown; charset=utf-8"
      } else {
        $"no such howto: ($topic)" | metadata set { merge {'http.response': {status: 404}} }
      }
    })

    (route {method: "GET", path: "/api/state"} {|req ctx|
      # Discovery for command-line tooling: stack ids/names + the current
      # (last-focused) stack, so scripts can target ?stack=<id|name>.
      let proj = (.cat | projection project)
      {
        focusedClip: (load-focused-sid)
        focusedStack: (clip-stack-of $proj (load-focused-sid))
        stacks: ($proj.stacks | each {|s| {id: $s.id, name: ($s.name? | default null)} })
        # Every clip across all stacks, each tagged with its owning stack, in
        # that stack's render order -- a flat list mirroring `terminals`. Scripts
        # find a clip by label (`where label == X`) or scope to a stack (`where
        # stack == id`) without a second round-trip, so they need no local
        # registry. label is the rename (null until renamed); view is the style
        # override (rendered/embed, null when default); position is null while a
        # stack is auto-sorted.
        clips: ($proj.stacks | each {|s|
          projection sorted-clips $s | each {|c| {
            id: $c.id
            stack: $s.id
            kind: ($c.kind? | default "content")
            label: ($c.label? | default null)
            mime: ($c.mime_type? | default null)
            view: ($c.view? | default null)
            position: ($c.position?)
          } }
        } | flatten)
        # Live ptys so CLI tooling can map a clip to its sid (and back) without
        # scraping /sse. clip is the owning clip id; cwd is from OSC 7 (null
        # until the shell reports one). The label lives on the clip -- join via
        # `clip` into `clips` above for it.
        terminals: (pty list | each {|p| {sid: $p.sid, clip: ($p.meta.clip_id? | default null), cwd: ($p.cwd? | default null)} })
      } | to json | metadata set --content-type "application/json"
    })

    (route {method: "GET", path: "/api/events"} {|req ctx|
      # A machine-readable feed of log frames as newline-delimited JSON -- one
      # frame per line, streamed as they're appended. Live-only: the replayed
      # history is skipped, so every line is a change that happened after you
      # connected. Pair it with /api/state for a snapshot, then react to deltas.
      #
      # Frames are the protocol (see app/projection.nu): clip.add / clip.update /
      # clip.patch / clip.delete and stack.add / stack.update / stack.delete.
      # Each line is {id, topic, meta}: id is the frame's scru128 (the clip id on
      # clip.add, the stack id on stack.add), meta its fields. clip.add carries
      # {stack_id, mime_type, ...}; clip.patch carries whatever changed (label,
      # view, position, stack_id on a move).
      #
      #   curl -sN localhost:5099/api/events        # stream; -N = no buffering
      .cat -f
      | generate {|ev, live|
          if $ev.topic == "xs.threshold" {
            # End of history replay -- everything after this is live.
            {next: true}
          } else if (not $live) or ($ev.topic | str starts-with "xs.") {
            # Still replaying history, or a system heartbeat: skip.
            {next: $live}
          } else if (($ev.topic | str starts-with "clip.") or ($ev.topic | str starts-with "stack.")) {
            {out: ({id: $ev.id, topic: $ev.topic, meta: ($ev.meta? | default {})} | to json --raw | $"($in)\n"), next: $live}
          } else {
            # Ephemeral nudges (focus pings, title, bus events) aren't the feed.
            {next: $live}
          }
        } false
      | metadata set --content-type "application/x-ndjson"
    })

    (route {method: "POST", path: "/clip/update"} {|req ctx|
      # Replace an existing clip's body (clip.update -> CAS): a note's text on
      # blur, or any asset re-posted from the CLI --
      #   curl --data-binary @diagram.png 'localhost:5099/clip/update?clip=<id>'
      # Mime is unchanged; the clip's pane refreshes live. A note's editor
      # textarea is data-ignore-morph, so an open draft survives the refresh
      # (the <pre> picks up the new body underneath).
      let body = $in
      let cid = ($req.query.clip? | default "")
      if not (clip-exists $cid) {
        no-such-clip $cid
      } else {
        $body | set-clip-body $cid
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "POST", path: "/clip/close"} {|req ctx|
      # Tombstone the clip (won't respawn) and, if it's a terminal, kill its
      # pty. The clip.delete frame propagates via `.cat -f`; each /sse drops
      # the pane in its #doc reconcile.
      let cid = ($req.query.clip? | default "")
      if not (clip-exists $cid) {
        no-such-clip $cid
      } else {
        let sid = (sid-for-clip $cid)
        if $sid != "" { pty close $sid }
        delete-clip $cid
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "POST", path: "/clip/label"} {|req ctx|
      # Rename a clip. The label persists on the clip (clip.patch {label}) and
      # propagates via `.cat -f`, so every sidebar + pane head re-renders. The
      # label is clip-level (notes, images, terminals alike), so this is a
      # `/clip/` route keyed by ?clip=, like its siblings -- no pty involved.
      let cid = ($req.query.clip? | default "")
      let new = ($req.query.label? | default "" | str trim)
      if not (clip-exists $cid) {
        no-such-clip $cid
      } else {
        set-clip-label $cid $new
        null | metadata set { merge {'http.response': {status: 204}} }
      }
    })

    (route {method: "POST", path: "/title"} {|req ctx|
      # Set the per-server window title. Persist (ghostty.title) for reconnects
      # and broadcast (title.events, connId-tagged) so other tabs update live
      # without echoing back into the typer's focused <input>.
      let body = $in
      let signals = $body | from datastar-signals $req
      let new = ($signals.title? | default "" | str trim)
      save-title $new
      {connId: ($signals.connId? | default ""), title: $new} | .bus pub "title.events"
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "POST", path: "/pty/input"} {|req ctx|
      let body = $in
      $body | pty write $req.query.sid
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "POST", path: "/pty/resize"} {|req ctx|
      let body = $in
      let cfg = $body | from json
      pty resize $req.query.sid $cfg.cols $cfg.rows
      null | metadata set { merge {'http.response': {status: 204}} }
    })

    (route {method: "GET", path: "/pty/view"} {|req ctx|
      let sid = ($req.query.sid? | default "")
      if not (pty-sid-live $sid) {
        $"no pty session: ($sid)" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        let target = ($req.query.target? | default "grid")
        # `pty view` emits HTML grid-update records (one buffer fact each); the
        # pty stays datastar-agnostic. Map each kind to a datastar patch here.
        pty view $sid --target $target
        | each {|f|
            match $f.kind {
              # screen + row are morph-by-id (the html carries its own id).
              "screen" => ($f.html | to datastar-patch-elements)
              "row" => ($f.html | to datastar-patch-elements)
              # new bottom rows append into the grid container.
              "append" => ($f.html | to datastar-patch-elements --selector $"#($target)" --mode append)
              # purged top rows: remove by id.
              "trim" => ("" | to datastar-patch-elements --selector ($f.ids | each {|id| $"#($id)" } | str join ",") --mode remove)
              # idle keepalive -> SSE comment.
              "heartbeat" => {comment: "hb"}
            }
          }
        | to sse
        | metadata set --content-type "text/event-stream"
      }
    })

    (route {method: "GET", path: "/pty/raw"} {|req ctx|
      # Live tee of a session's raw output bytes (escape sequences and all).
      # Ends when the session closes; closing the connection drops the tee.
      let sid = ($req.query.sid? | default "")
      if not (pty-sid-live $sid) {
        $"no pty session: ($sid)" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        pty raw $sid | metadata set --content-type "application/octet-stream"
      }
    })

    (route {method: "GET", path: "/pty/snap"} {|req ctx|
      # One-shot plain-text snapshot of a session's full buffer (scrollback
      # included). Not a stream -- returns the current screen state and ends.
      let sid = ($req.query.sid? | default "")
      if not (pty-sid-live $sid) {
        $"no pty session: ($sid)" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        pty snap $sid | metadata set --content-type "text/plain; charset=utf-8"
      }
    })

    (route {method: "GET", path: "/md.css"} {|req ctx|
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
    })

    (route true {|req ctx|
      let path = if $req.path == "/" { "/sessions.html" } else { $req.path }
      .static $STATIC $path
    })
  ]
}
