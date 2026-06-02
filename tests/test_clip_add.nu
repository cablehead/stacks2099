use std/assert

# Drive the real /clip/add + /clip/update handlers (serve.nu's dispatch closure)
# against a temp store and assert the uploaded body lands in CAS. This is the
# `source serve.nu; do $closure $req` endpoint-test pattern from http-nu, run via
# `stacks2099 eval --store` so .cat/.append are available.

const script_dir = path self | path dirname
let handler = source ($script_dir | path join ".." "app" "serve.nu")

# POST /clip/add with a body; the body is the closure's pipeline input.
let body = "hello streaming clip"
let resp = (
  $body | do $handler {
    method: "POST"
    path: "/clip/add"
    headers: {"content-type": "text/markdown"}
    query: {}
  }
)

# The handler returns the new clip id (status 201).
let cid = ($resp | into string | str trim)
assert (($cid | str length) > 0) "clip/add returns a new clip id"

# The clip.add frame was appended with our stack/kind/mime, and its CAS body is
# the bytes we streamed in.
let frame = (.cat | where {|f| ($f.id? | default "") == $cid } | first)
assert equal ($frame.topic) "clip.add" "appended a clip.add frame"
assert equal ($frame.meta.kind) "content" "kind=content"
assert equal ($frame.meta.mime_type) "text/markdown" "mime from content-type header"
assert (($frame.hash? | default "") != "") "body was CAS-stored (frame has a hash)"
let stored = (.cas $frame.hash)
assert equal $stored $body "the streamed body round-trips through CAS intact"

# /clip/update streams a replacement body to the same clip (clip.update -> CAS).
let body2 = "updated streaming body"
$body2 | do $handler {
  method: "POST"
  path: "/clip/update"
  headers: {}
  query: {clip: $cid}
}
let upd = (.cat | where {|f| ($f.topic == "clip.update") and (($f.meta.id? | default "") == $cid) } | last)
assert (($upd.hash? | default "") != "") "clip/update CAS-stored the new body"
assert equal (.cas $upd.hash) $body2 "the streamed update body round-trips through CAS intact"

print "test_clip_add.nu: all assertions passed"
