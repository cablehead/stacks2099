# Pure render helpers: the kind/mime -> render-type dispatch and the small
# string helpers it feeds. No store/pty/datastar deps, so this is
# unit-testable (tests/test_render.nu) -- mirrors examples/2048's pure game.nu.
# The body-touching renderers (render-content, render-pane) stay in serve.nu.

export def html-escape [s: string]: nothing -> string {
  $s | str replace -a '&' '&amp;' | str replace -a '<' '&lt;' | str replace -a '>' '&gt;'
}

# Short, recognizable fragment of a scru128 id for display. scru128 is
# time-ordered: the timestamp lives in the leading chars and the entropy in the
# trailing chars, so ids minted close together share a prefix. Crop the tail
# (the part that actually distinguishes them), never the head.
export def id-tail [id: string]: nothing -> string {
  $id | str substring (-8..)
}

# Is `s` a single http(s) URL? Used to offer an "Embed" view on URL notes.
export def is-url [s: string]: nothing -> bool {
  let t = ($s | str trim)
  (($t | str starts-with "http://") or ($t | str starts-with "https://")) and (not ($t | str contains " ")) and (($t | lines | length) == 1)
}

# A clip's render type -- WHAT it is, independent of view style or focus. The
# seed of the Phase 4 content-type dispatch (mime -> renderer); buckets:
#   terminal  live pty grid
#   note      editable text (text/plain, text/markdown) -- shows a styled view
#             (raw or rendered, per note-style) plus a source textarea that
#             focus reveals. `view` no longer changes the render type.
#   image     image/*  -> <img> preview
#   embed     text/uri-list or view=embed -> live <iframe>
#   file      anything else -> read-only preview / download
export def clip-render-type [c: record]: nothing -> string {
  if $c.kind == "terminal" { return "terminal" }
  let m = ($c.mime_type? | default "text/plain")
  if ($c.view? | default "") == "embed" { return "embed" }
  if ($m | str starts-with "image/") {
    "image"
  } else if $m == "text/uri-list" {
    "embed"
  } else if $m in ["text/plain" "text/markdown"] {
    "note"
  } else {
    "file"
  }
}

# A note's display style when NOT focused: "rendered" (markdown -> HTML) or
# "raw" (source <pre>). Only markdown can render; plain text is always raw.
# Cycled via mod+K v (clip.patch {view}); orthogonal to focus.
export def note-style [c: record]: nothing -> string {
  if ($c.view? | default "") == "rendered" and ($c.mime_type? | default "") == "text/markdown" {
    "rendered"
  } else {
    "raw"
  }
}

# A clip's display label: its set label, else a render-type default.
export def clip-display-label [c: record]: nothing -> string {
  let l = ($c.label? | default "")
  if ($l | is-not-empty) { return $l }
  match (clip-render-type $c) {
    "terminal" => "nu"
    "image" => "image"
    "embed" => "embed"
    "file" => ($c.mime_type? | default "file")
    _ => "note"
  }
}

# Inline SVG (vendored lucide icons) for a render type.
export def icon-svg [rtype: string]: nothing -> string {
  let a = "class='row-icon' xmlns='http://www.w3.org/2000/svg' width='1em' height='1em' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'"
  match $rtype {
    "terminal" => $"<svg ($a)><path d='m7 11 2-2-2-2'/><path d='M11 13h4'/><rect width='18' height='18' x='3' y='3' rx='2'/></svg>"
    "image" => $"<svg ($a)><rect width='18' height='18' x='3' y='3' rx='2' ry='2'/><circle cx='9' cy='9' r='2'/><path d='m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21'/></svg>"
    "embed" => $"<svg ($a)><circle cx='12' cy='12' r='10'/><path d='M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20'/><path d='M2 12h20'/></svg>"
    "file" => $"<svg ($a)><path d='M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z'/><path d='M14 2v4a2 2 0 0 0 2 2h4'/></svg>"
    _ => $"<svg ($a)><path d='M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z'/><path d='M14 2v4a2 2 0 0 0 2 2h4'/><path d='M10 9H8'/><path d='M16 13H8'/><path d='M16 17H8'/></svg>"
  }
}
