use std/assert

# Unit tests for the pure projection (app/projection.nu) -- the fold from the
# event log to UI state. No store/pty/render here; those are serve.nu and are
# covered (eventually) by browser e2e. Mirrors examples/2048's test idiom:
# import the pure module, assert on pure functions.
const script_dir = path self | path dirname
use ($script_dir | path join ".." "app" "projection.nu") *

# Fold frames without reconcile-selection, for precise state assertions.
def fold [frames: list]: nothing -> record {
  $frames | reduce --fold (empty) {|f acc| apply-frame $acc $f }
}

# Frame shorthand. (apply-frame reads .topic, .id, .hash, .meta.)
def frame [topic: string, id: string, meta: record, hash: any = null]: nothing -> record {
  {topic: $topic, id: $id, hash: $hash, meta: $meta}
}

# --- empty -----------------------------------------------------------------
let e = (empty)
assert ($e.stacks == []) "empty has no stacks"
assert ($e.selectedStackId == null) "empty has no selected stack"
assert ($e.selectedClipId == null) "empty has no selected clip"

# --- stack.add -------------------------------------------------------------
let s = (fold [(frame "stack.add" "s1" {sort: "manual"})])
assert (($s.stacks | length) == 1) "stack.add adds one stack"
let st = ($s.stacks | first)
assert ($st.id == "s1") "stack id is the frame id"
assert ($st.name == null) "name defaults to null (UI falls back to the id)"
assert ($st.sort == "manual") "sort comes from meta"
assert (($s.stacks | first | get clips) == []) "new stack has no clips"
# sort defaults to auto when absent
let sauto = (fold [(frame "stack.add" "s9" {})])
assert (($sauto.stacks | first | get sort) == "auto") "sort defaults to auto"

# --- clip.add --------------------------------------------------------------
let c = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.add" "c2" {stack_id: "s1", kind: "terminal", mime_type: "x/term"})
])
let clips = ($c.stacks | first | get clips)
assert (($clips | length) == 2) "two clips added to the stack"
let c1 = ($clips | where id == "c1" | first)
assert ($c1.kind == "content") "kind defaults to content"
assert ($c1.mime_type == "text/plain") "mime_type defaults to text/plain"
assert ($c1.hash == "h1") "clip carries its frame hash"
assert ($c1.versions == ["c1"]) "versions seeded with the add frame id"
let c2 = ($clips | where id == "c2" | first)
assert ($c2.kind == "terminal") "kind read from meta"
assert ($c2.mime_type == "x/term") "mime_type read from meta"

# robustness: a clip.add missing stack_id is a no-op (foreign/old frame)
let cbad = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "cX" {kind: "content"})   # no stack_id
])
assert (($cbad.stacks | first | get clips | length) == 0) "clip.add without stack_id is skipped, not a crash"

# --- clip.update -----------------------------------------------------------
let u = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.update" "u1" {id: "c1"} "h2")
])
let uc = ($u.stacks | first | get clips | where id == "c1" | first)
assert ($uc.hash == "h2") "clip.update swaps the hash"
assert ($uc.versions == ["u1" "c1"]) "clip.update prepends the new version"
assert ($uc.lastTouched == "u1") "clip.update bumps lastTouched"

# --- clip.patch ------------------------------------------------------------
# label is non-structural: the field merges, but the stack's lastTouched is
# NOT bumped (a rename/re-classify isn't activity that should re-sort stacks).
let p = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.patch" "p1" {id: "c1", label: "shell"})
])
let pc = ($p.stacks | first | get clips | where id == "c1" | first)
assert ($pc.label == "shell") "clip.patch merges the label"
assert (($p.stacks | first | get lastTouched) == "c1") "label patch does NOT bump the stack's lastTouched"

# position IS structural: it's a manual reorder, so the stack's lastTouched
# bumps (the clip gets the new position; clip.lastTouched is left alone).
let pp = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.patch" "p2" {id: "c1", position: "a0"})
])
let ppc = ($pp.stacks | first | get clips | where id == "c1" | first)
assert ($ppc.position == "a0") "position is set on the clip"
assert (($pp.stacks | first | get lastTouched) == "p2") "position patch bumps the stack's lastTouched"

# stack_id in a patch moves the clip to another stack.
let mv = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "stack.add" "s2" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.patch" "p3" {id: "c1", stack_id: "s2"})
])
assert (($mv.stacks | where id == "s1" | first | get clips | length) == 0) "clip left the source stack"
assert (($mv.stacks | where id == "s2" | first | get clips | length) == 1) "clip arrived in the target stack"

# --- clip.delete -----------------------------------------------------------
let d = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.add" "c2" {stack_id: "s1"} "h2")
  (frame "clip.delete" "d1" {id: "c1"})
])
let dclips = ($d.stacks | first | get clips)
assert (($dclips | length) == 1) "clip.delete removes the clip"
assert (($dclips | first | get id) == "c2") "the right clip survives"
assert (($d.deleted | length) == 1) "deleted snapshot recorded (for restore/trash)"

# --- sorted-clips: auto vs manual ------------------------------------------
let auto = (fold [
  (frame "stack.add" "sa" {sort: "auto"})
  (frame "clip.add" "c1" {stack_id: "sa"} "h1")
  (frame "clip.add" "c2" {stack_id: "sa"} "h2")
])
let auto_ids = (sorted-clips ($auto.stacks | first) | get id)
assert ($auto_ids == ["c2" "c1"]) "auto sort = lastTouched desc (newest first)"

let man = (fold [
  (frame "stack.add" "sm" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "sm", position: 200} "h1")
  (frame "clip.add" "c2" {stack_id: "sm", position: 100} "h2")
])
let man_ids = (sorted-clips ($man.stacks | first) | get id)
assert ($man_ids == ["c2" "c1"]) "manual sort = position asc (c2@100 before c1@200)"

# --- position-between (fractional ordering keys) ---------------------------
assert ((position-between null null) > 0) "first key when the stack is empty"
assert ((position-between 100 300) == 200) "midpoint of two keys"
assert ((position-between 100 null) > 100) "append: after lo"
let lo_key = (position-between null 100)
assert ($lo_key > 0 and $lo_key < 100) "prepend: before hi"
assert ((position-between 100 101) == null) "adjacent keys leave no gap -> null (rebalance)"
assert ((position-between null 1) == null) "no room below hi=1 -> null"

# --- selection: clip.select / stack.select ---------------------------------
# clip.select reads the selected stack, so a stack must be selected first
# (live, the threshold's reconcile sets it; here we do it explicitly).
let sel = ([
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "clip.add" "c2" {stack_id: "s1"} "h2")
  (frame "stack.select" "sx" {id: "s1"})
  (frame "clip.select" "x1" {id: "c2"})
] | project)
assert ($sel.selectedStackId == "s1") "selection resolves to the stack"
assert ($sel.selectedClipId == "c2") "clip.select jumps to the given id"

# cycle by action: down from c1 moves to c2 in manual order [c1@a, c2@b]
let cyc = ([
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1", position: "a"} "h1")
  (frame "clip.add" "c2" {stack_id: "s1", position: "b"} "h2")
  (frame "stack.select" "sx" {id: "s1"})
  (frame "clip.select" "x1" {id: "c1"})
  (frame "clip.select" "x2" {action: "down"})
] | project)
assert ($cyc.selectedClipId == "c2") "clip.select down moves to the next clip in order"

# --- reconcile-selection default -------------------------------------------
let def = ([
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
] | project)
assert ($def.selectedStackId == "s1") "default selects the (only) stack"
assert ($def.selectedClipId == "c1") "default selects its first clip"

# --- robustness: unknown / foreign topics are no-ops -----------------------
let noise = (fold [
  (frame "stack.add" "s1" {sort: "manual"})
  (frame "clip.add" "c1" {stack_id: "s1"} "h1")
  (frame "ghostty.title" "g1" {val: "x"})       # unknown topic
  (frame "clip.delete" "z1" {clip_id: "c1"})      # old-schema key (clip_id, not id)
  (frame "clip.update" "z2" {})                   # missing id
])
assert (($noise.stacks | first | get clips | length) == 1) "unknown/old/foreign frames are skipped, clip survives"

print "tests/test_projection.nu: all assertions passed"
