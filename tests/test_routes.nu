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

print "test_routes.nu: all assertions passed"
