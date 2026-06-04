use std/assert

# Unit tests for the pure render helpers (app/render.nu) -- the kind/mime ->
# render-type dispatch and friends. The body/pty-touching renderers
# (render-content, render-pane) live in serve.nu and are covered by the
# browser e2e (tests-browser/).
const script_dir = path self | path dirname
use ($script_dir | path join ".." "app" "render.nu") *

def clip [rec: record]: nothing -> record { {kind: "content", mime_type: "text/plain"} | merge $rec }

# --- id-tail: crop the entropy end of a scru128, not the timestamp prefix ----
assert ((id-tail "03g9058viwkbqxibsyxgoxi4g") == "yxgoxi4g") "id-tail shows the trailing chars"
assert ((id-tail "abc") == "abc") "id-tail of a short string is the whole string"

# --- clip-render-type: the dispatch ----------------------------------------
assert ((clip-render-type (clip {kind: "terminal"})) == "terminal") "terminal kind"
assert ((clip-render-type (clip {mime_type: "image/png"})) == "image") "image/* -> image"
assert ((clip-render-type (clip {mime_type: "image/svg+xml"})) == "image") "any image/* -> image"
assert ((clip-render-type (clip {mime_type: "text/uri-list"})) == "embed") "uri-list -> embed"
assert ((clip-render-type (clip {mime_type: "text/plain", view: "embed"})) == "embed") "view=embed wins -> embed"
# view (style) no longer changes the render type: editable text is always 'note'
# (it carries both the styled view and the source textarea). Style is note-style.
assert ((clip-render-type (clip {mime_type: "text/markdown", view: "rendered"})) == "note") "view=rendered markdown is still a note"
assert ((clip-render-type (clip {mime_type: "text/plain", view: "rendered"})) == "note") "view=rendered plain text is still a note"
assert ((clip-render-type (clip {mime_type: "application/pdf", view: "rendered"})) == "file") "view=rendered on non-text falls through -> file"
assert ((clip-render-type (clip {mime_type: "text/plain"})) == "note") "text/plain -> note"
assert ((clip-render-type (clip {mime_type: "text/markdown"})) == "note") "text/markdown -> note"
assert ((clip-render-type (clip {mime_type: "application/json"})) == "file") "json -> file"
assert ((clip-render-type {kind: "content"}) == "note") "missing mime defaults to text/plain -> note"

# --- note-style: raw vs rendered (orthogonal to render type + focus) --------
assert ((note-style (clip {mime_type: "text/markdown", view: "rendered"})) == "rendered") "markdown view=rendered -> rendered"
assert ((note-style (clip {mime_type: "text/markdown"})) == "raw") "markdown default -> raw"
assert ((note-style (clip {mime_type: "text/markdown", view: "raw"})) == "raw") "markdown view=raw -> raw"
assert ((note-style (clip {mime_type: "text/plain", view: "rendered"})) == "raw") "plain text can't render -> raw"

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
