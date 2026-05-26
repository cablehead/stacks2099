use std/assert

# Unit tests for the pure render helpers (app/render.nu) -- the kind/mime ->
# render-type dispatch and friends. The body/pty-touching renderers
# (render-content, render-pane) live in serve.nu and are covered by the
# browser e2e (tests-browser/).
const script_dir = path self | path dirname
use ($script_dir | path join ".." "app" "render.nu") *

def clip [rec: record]: nothing -> record { {kind: "content", mime_type: "text/plain"} | merge $rec }

# --- clip-render-type: the dispatch ----------------------------------------
assert ((clip-render-type (clip {kind: "terminal"})) == "terminal") "terminal kind"
assert ((clip-render-type (clip {mime_type: "image/png"})) == "image") "image/* -> image"
assert ((clip-render-type (clip {mime_type: "image/svg+xml"})) == "image") "any image/* -> image"
assert ((clip-render-type (clip {mime_type: "text/uri-list"})) == "embed") "uri-list -> embed"
assert ((clip-render-type (clip {mime_type: "text/plain", view: "embed"})) == "embed") "view=embed wins -> embed"
assert ((clip-render-type (clip {mime_type: "text/markdown", view: "rendered"})) == "doc") "view=rendered on markdown -> doc"
assert ((clip-render-type (clip {mime_type: "text/plain", view: "rendered"})) == "doc") "view=rendered on plain text -> doc"
assert ((clip-render-type (clip {mime_type: "application/pdf", view: "rendered"})) == "file") "view=rendered on non-text falls through -> file"
assert ((clip-render-type (clip {mime_type: "text/plain"})) == "note") "text/plain -> note"
assert ((clip-render-type (clip {mime_type: "text/markdown"})) == "note") "text/markdown -> note"
assert ((clip-render-type (clip {mime_type: "application/json"})) == "file") "json -> file"
assert ((clip-render-type {kind: "content"}) == "note") "missing mime defaults to text/plain -> note"

# --- is-url ----------------------------------------------------------------
assert (is-url "http://example.com") "http url"
assert (is-url "https://example.com/a?b=c#d") "https url with query/frag"
assert (is-url "  https://example.com  ") "trims surrounding whitespace"
assert (not (is-url "ftp://example.com")) "non-http scheme is not a url"
assert (not (is-url "just some text")) "prose is not a url"
assert (not (is-url "http://a b")) "embedded space is not a single url"
assert (not (is-url "http://a\nhttp://b")) "multiline is not a single url"

# --- clip-display-label ----------------------------------------------------
assert ((clip-display-label (clip {label: "my label"})) == "my label") "explicit label wins"
assert ((clip-display-label (clip {kind: "terminal"})) == "nu") "terminal default label"
assert ((clip-display-label (clip {mime_type: "image/png"})) == "image") "image default label"
assert ((clip-display-label (clip {mime_type: "text/plain"})) == "note") "note default label"
assert ((clip-display-label (clip {mime_type: "text/uri-list"})) == "embed") "embed default label"
assert ((clip-display-label (clip {mime_type: "application/pdf"})) == "application/pdf") "file label is the mime"

# --- html-escape -----------------------------------------------------------
assert ((html-escape "a<b>&c") == "a&lt;b&gt;&amp;c") "escapes & < >"
assert ((html-escape "plain") == "plain") "leaves plain text alone"

# --- icon-svg --------------------------------------------------------------
for t in ["terminal" "image" "embed" "file" "note"] {
  assert ((icon-svg $t) | str starts-with "<svg") $"icon-svg ($t) returns an svg"
}

print "tests/test_render.nu: all assertions passed"
