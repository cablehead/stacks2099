# Pure projection over the stacks event stream.
#
# Vendored from ~/stacks.nu/www/projection.nu (the v2 model). The only
# stacks2099 change is a `kind` field on each clip ("content" | "terminal"):
# terminal clips bind to a live pty (handled entirely in serve.nu's render +
# bootstrap layer); this projection stays pty-agnostic.
#
# Persistent topics:
#   stack.add    meta: {name, sort, layout}                  frame.id = stack id
#   stack.update meta: {id, name?, sort?, layout?}
#   stack.delete meta: {id}
#   clip.add     meta: {stack_id, kind?, mime_type, position?}   frame.id = clip id
#   clip.update  meta: {id}                                   body -> new hash; clip id stays stable
#   clip.patch   meta: {id, stack_id?, position?, mime_type?, label?, ...}  # field merge; stack_id moves
#   clip.delete  meta: {id}
#
# Ephemeral selection topics (TTL=ephemeral; replay window is "live only"):
#   stack.select  meta: {action: "down"|"up"} | {id}
#   clip.select   meta: {action: "down"|"up"} | {id}
#
# State shape:
#   {
#     stacks: [{id, name, sort, layout, lastTouched, clips: [{id, kind, hash, mime_type, position, lastTouched, versions}]}]
#     selectedStackId: string|null
#     selectedClipId:  string|null
#     frameId:         string|null   # id of the last frame that produced this state
#   }
#
# `sort` is "auto" or "manual". `sorted-clips` returns a stack's clips in
# render order: auto = lastTouched desc (newest activity first, so edits
# float to the top), manual = position asc.
#
# `layout` is how the stack's panes compose: "flow" (vertical document column)
# or "niri" (horizontal scrollable strip of fixed-width columns). Both consume
# the same `sorted-clips` order; layout is presentation only.

export def empty []: nothing -> record {
  {stacks: [] selectedStackId: null selectedClipId: null selectionExplicit: false frameId: null deleted: []}
}

# Pick the id that occupies the same slot after `removed` is dropped from
# `ids`. Falls back to the last remaining id when the removed one was the
# bottom, and null when nothing remains. Used by stack/clip delete to keep
# the cursor under the user's eye.
def slot-after-removal [ids: list removed: any]: nothing -> any {
  let idx = $ids | enumerate | where item == $removed | get index.0?
  let post = $ids | where {|x| $x != $removed }
  if $idx == null or ($post | is-empty) {
    null
  } else if $idx >= ($post | length) {
    $post | last
  } else {
    $post | get $idx
  }
}

export def sorted-clips [stack: record]: nothing -> list {
  if $stack.sort == "manual" {
    $stack.clips | sort-by {|c| [($c.position? | default 0) $c.id] }
  } else {
    $stack.clips | sort-by lastTouched | reverse
  }
}

# A position key strictly between lo and hi (integer keys with gaps). null lo
# or hi are open bounds (move to top / bottom). Returns null when two adjacent
# keys leave no integer gap -- the caller then renumbers (rebalances) the stack.
export def position-between [lo: any, hi: any]: nothing -> any {
  let step = 65536
  if ($lo == null) and ($hi == null) {
    $step
  } else if ($lo == null) {
    if $hi <= 1 { null } else { $hi // 2 }
  } else if ($hi == null) {
    $lo + $step
  } else if (($hi - $lo) <= 1) {
    null
  } else {
    ($lo + $hi) // 2
  }
}

export def apply-frame [state: record frame: record]: nothing -> record {
  let s = match $frame.topic {
    "stack.add" => (stack-add $state $frame)
    "stack.update" => (stack-update $state $frame)
    "stack.delete" => (stack-delete $state $frame)
    "clip.add" => (clip-add $state $frame)
    "clip.update" => (clip-update $state $frame)
    "clip.patch" => (clip-patch $state $frame)
    "clip.delete" => (clip-delete $state $frame)
    "stack.select" => (stack-select $state $frame)
    "clip.select" => (clip-select $state $frame)
    "clip.restore" => (clip-restore $state $frame)
    "stack.restore" => (stack-restore $state $frame)
    _ => $state
  }
  $s | update frameId ($frame.id? | default $s.frameId)
}

# Apply default selection (first stack, first clip) when nothing is selected
# or when current selection has been deleted. Idempotent.
export def reconcile-selection []: record -> record {
  let state = $in
  # Default selection follows render order: most-recently-touched first.
  let stack_ids = $state.stacks | sort-by lastTouched | reverse | get id
  # Until the user explicitly picks a stack (via stack.select), the cursor
  # tracks the most-active stack. Once they have, we preserve their choice
  # and only fall back to the top when it's no longer valid.
  let sel_stack = if (not $state.selectionExplicit) {
    $stack_ids | get -i 0
  } else if ($state.selectedStackId in $stack_ids) {
    $state.selectedStackId
  } else {
    $stack_ids | get -i 0
  }
  if $sel_stack == null {
    return ($state | update selectedStackId null | update selectedClipId null)
  }
  let stack = $state.stacks | where id == $sel_stack | first
  let clips = sorted-clips $stack
  let clip_ids = $clips | get id
  let sel_clip = if ($state.selectedClipId in $clip_ids) {
    $state.selectedClipId
  } else {
    $clip_ids | get -i 0
  }
  $state | update selectedStackId $sel_stack | update selectedClipId $sel_clip
}

def stack-add [state: record frame: record] {
  let stack = {
    id: $frame.id
    name: ($frame.meta?.name?)   # null until renamed; UI falls back to the id
    sort: ($frame.meta?.sort? | default "auto")
    layout: ($frame.meta?.layout? | default "flow")   # "flow" (column) | "niri" (scrollable strip)
    clips: []
    lastTouched: $frame.id
  }
  $state | update stacks ($state.stacks | append $stack)
}

def stack-update [state: record frame: record] {
  let id = ($frame.meta?.id?)
  if $id == null { return $state }
  let patch = $frame.meta | reject id
  let stacks = $state.stacks | each {|s|
      if $s.id == $id { $s | merge $patch | update lastTouched $frame.id } else { $s }
    }
  $state | update stacks $stacks
}

def stack-delete [state: record frame: record] {
  let id = ($frame.meta?.id?)
  if $id == null { return $state }
  let victim = $state.stacks | where id == $id | get -i 0
  let stacks = $state.stacks | where id != $id
  let new_selected = if $state.selectedStackId != $id {
    $state.selectedStackId
  } else {
    let pre = $state.stacks | sort-by lastTouched | reverse | get id
    slot-after-removal $pre $id
  }
  let new_clip = if $new_selected == null or $new_selected == $state.selectedStackId {
    $state.selectedClipId
  } else {
    let stack = $stacks | where id == $new_selected | get -i 0
    let clip_ids = if $stack == null { [] } else { sorted-clips $stack | get id }
    $clip_ids | get -i 0
  }
  let deleted = if $victim == null { $state.deleted } else {
    [{frame_id: $frame.id kind: "stack" snapshot: {stack: $victim} deleted_at: $frame.id}] | append $state.deleted
  }
  $state
  | update stacks $stacks
  | update selectedStackId $new_selected
  | update selectedClipId $new_clip
  | update deleted $deleted
}

def clip-add [state: record frame: record] {
  let stack_id = ($frame.meta?.stack_id?)
  if $stack_id == null { return $state }   # foreign / pre-projection frame
  let clip = {
    id: $frame.id
    kind: ($frame.meta?.kind? | default "content")
    hash: ($frame.hash?)
    mime_type: ($frame.meta?.mime_type? | default "text/plain")
    position: ($frame.meta?.position?)
    lastTouched: $frame.id
    versions: [$frame.id]
  }
  let stacks = $state.stacks | each {|s|
      if $s.id == $stack_id {
        $s | update clips ($s.clips | append $clip) | update lastTouched $frame.id
      } else {
        $s
      }
    }
  # In auto-sort stacks, a new clip is the new top -- bump selection to it
  # when it lands in the currently-selected stack.
  let target = $stacks | where id == $stack_id | get -i 0
  let bump = ($target != null) and ($target.sort == "auto") and ($state.selectedStackId == $stack_id)
  if $bump {
    $state | update stacks $stacks | update selectedClipId $frame.id
  } else {
    $state | update stacks $stacks
  }
}

def clip-update [state: record frame: record] {
  let clip_id = ($frame.meta?.id?)
  if $clip_id == null { return $state }
  let new_hash = $frame.hash?
  let stacks = $state.stacks | each {|s|
      if ($s.clips | any {|c| $c.id == $clip_id }) {
        let updated_clips = $s.clips | each {|c|
            if $c.id == $clip_id {
              $c
              | update hash $new_hash
              | update lastTouched $frame.id
              | update versions ([$frame.id] | append $c.versions)
            } else { $c }
          }
        $s | update clips $updated_clips | update lastTouched $frame.id
      } else {
        $s
      }
    }
  $state | update stacks $stacks
}

# clip.patch: field-level merge into a clip's meta. stack_id in the patch
# moves the clip to a different stack (structural). Other fields are merged
# directly. lastTouched only bumps for structural changes (move or position
# update), not for pure metadata patches like mime_type / label -- those are
# a re-classification/rename, not activity.
def clip-patch [state: record frame: record] {
  let clip_id = ($frame.meta?.id?)
  if $clip_id == null { return $state }
  let patch = $frame.meta | reject id

  let owners = $state.stacks | where ($it.clips | any {|c| $c.id == $clip_id })
  if ($owners | is-empty) { return $state }
  let current = $owners | first
  let clip = $current.clips | where id == $clip_id | first

  let target_id = $patch.stack_id? | default $current.id
  let field_patch = if "stack_id" in ($patch | columns) {
    $patch | reject stack_id
  } else { $patch }
  let patched = $clip | merge $field_patch
  let bump = ($target_id != $current.id) or (($patch.position?) != null)

  let stacks = $state.stacks | each {|s|
      let stripped = $s | update clips ($s.clips | where id != $clip_id)
      let was_source = ($s.id == $current.id)
      let is_target = ($s.id == $target_id)
      if $is_target {
        let next = $stripped | update clips ($stripped.clips | append $patched)
        if $bump { $next | update lastTouched $frame.id } else { $next }
      } else if $was_source {
        if $bump { $stripped | update lastTouched $frame.id } else { $stripped }
      } else {
        $stripped
      }
    }
  $state | update stacks $stacks
}

def clip-delete [state: record frame: record] {
  let clip_id = ($frame.meta?.id?)
  if $clip_id == null { return $state }
  let owner = $state.stacks
    | where ($it.clips | any {|c| $c.id == $clip_id })
    | get -i 0
  let owner_id = $owner | get -i id
  let victim = if $owner == null { null } else { $owner.clips | where id == $clip_id | first }
  let stacks = $state.stacks | each {|s|
      let cleaned = $s | update clips ($s.clips | where id != $clip_id)
      if $s.id == $owner_id { $cleaned | update lastTouched $frame.id } else { $cleaned }
    }
  let new_selected = if $owner == null or $state.selectedClipId != $clip_id {
    $state.selectedClipId
  } else {
    slot-after-removal (sorted-clips $owner | get id) $clip_id
  }
  let deleted = if $victim == null { $state.deleted } else {
    [{frame_id: $frame.id kind: "clip" snapshot: {clip: $victim stack_id: $owner_id} deleted_at: $frame.id}] | append $state.deleted
  }
  $state | update stacks $stacks | update selectedClipId $new_selected | update deleted $deleted
}

# Restore a previously-deleted clip. frame.meta.target points at the
# clip.delete frame's id; we read the snapshot out of state.deleted and
# splice the clip back into its original stack.
def clip-restore [state: record frame: record] {
  let target = $frame.meta?.target?
  if $target == null { return $state }
  let entry = $state.deleted | where frame_id == $target | get -i 0
  if $entry == null or $entry.kind != "clip" { return $state }
  let stack_id = $entry.snapshot.stack_id
  let parent_alive = ($state.stacks | any {|s| $s.id == $stack_id })
  if not $parent_alive { return $state }
  let clip = $entry.snapshot.clip
  let stacks = $state.stacks | each {|s|
      if $s.id == $stack_id {
        $s | update clips ($s.clips | append $clip)
      } else { $s }
    }
  let deleted = $state.deleted | where frame_id != $target
  $state
  | update stacks $stacks
  | update deleted $deleted
  | update selectedStackId $stack_id
  | update selectedClipId $clip.id
  | update selectionExplicit true
}

def stack-restore [state: record frame: record] {
  let target = $frame.meta?.target?
  if $target == null { return $state }
  let entry = $state.deleted | where frame_id == $target | get -i 0
  if $entry == null or $entry.kind != "stack" { return $state }
  let stack = $entry.snapshot.stack
  let stacks = $state.stacks | append $stack
  let deleted = $state.deleted | where frame_id != $target
  $state
  | update stacks $stacks
  | update deleted $deleted
  | update selectedStackId $stack.id
  | update selectionExplicit true
}

# Cycle by `action`, jump by `id`. "top" jumps to the first id in render order.
def cycle [ids: list current: any action: string]: nothing -> any {
  if ($ids | is-empty) { return null }
  let n = $ids | length
  let idx = $ids | enumerate | where item == $current | get index.0?
  let cur = $idx | default 0
  match $action {
    "down" => ($ids | get (($cur + 1) mod $n))
    "up" => ($ids | get (($cur - 1 + $n) mod $n))
    "top" => ($ids | first)
    _ => $current
  }
}

def stack-select [state: record frame: record] {
  let stack_ids = $state.stacks | sort-by lastTouched | reverse | get id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $stack_ids) { $frame.meta.id } else { $state.selectedStackId }
  } else {
    cycle $stack_ids $state.selectedStackId ($frame.meta?.action? | default "")
  }
  let stack = $state.stacks | where id == $new_id | get -i 0
  let clip_ids = if $stack == null { [] } else { sorted-clips $stack | get id }
  $state
  | update selectedStackId $new_id
  | update selectedClipId ($clip_ids | get -i 0)
  | update selectionExplicit true
}

def clip-select [state: record frame: record] {
  let stack = $state.stacks | where id == $state.selectedStackId | get -i 0
  if $stack == null { return $state }
  let clip_ids = sorted-clips $stack | get id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $clip_ids) { $frame.meta.id } else { $state.selectedClipId }
  } else {
    cycle $clip_ids $state.selectedClipId ($frame.meta?.action? | default "")
  }
  $state | update selectedClipId $new_id | update selectionExplicit true
}

# Fold a list of frames into final state, with selection reconciled. Pure.
export def project []: list -> record {
  reduce -f (empty) {|frame acc| apply-frame $acc $frame } | reconcile-selection
}
