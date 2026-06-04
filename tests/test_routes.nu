use std/assert

# Endpoint test for the MPA stack routing (ADR 0006): each stack is its own page.
# /stack/:id serves the shell with the id from the URL. Driven via the
# `source serve.nu; do $closure $req` pattern (run through `stacks2099
# eval --store`).
#
# The `/` -> 302 redirect sets http.response metadata via the `http.response`
# custom slot (see http-nu src/response.rs extract_http_response_meta), which the
# response layer consumes to build the reply. That slot is NOT surfaced by the
# `metadata` command, so a `do $handler` caller can't read the status/Location --
# the redirect path is covered by the browser e2e (the app boots through it).

const script_dir = path self | path dirname
let handler = source ($script_dir | path join ".." "app" "serve.nu")

# A real stack id to address (the test owns its temp store, so make one).
let sid = (null | .append "stack.add" --meta {sort: "manual"} --ttl forever | get id)

# GET /stack/<id> -> the shell HTML.
let page = (do $handler {method: "GET" path: $"/stack/($sid)" headers: {} query: {}} | into string)
assert (($page | str downcase) | str contains "<!doctype html") "stack page serves the sessions shell"
assert ($page | str contains "data-signals") "shell includes the datastar root"

# /clip/new must never orphan a clip: a bogus selectedStack (here the literal
# "None") should fall back to a real stack via resolve-stack, not be trusted
# verbatim and then dropped by the projection.
'{"selectedStack":"None"}' | do $handler {method: "POST" path: "/clip/new" headers: {} query: {type: "note"}}
let added = (.cat | where {|f| $f.topic == "clip.add" } | last)
assert ($added.meta.stack_id == $sid) $"bogus selectedStack should home the clip to a real stack, got ($added.meta.stack_id)"
let proj = (.cat | projection project)
assert (($proj.stacks | where id == $sid | get 0.clips | length) >= 1) "the new clip is visible in the stack (not orphaned)"

print "test_routes.nu: all assertions passed"
