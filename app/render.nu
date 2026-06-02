# Pure render helpers: the kind/mime -> render-type dispatch and the small
# string helpers it feeds. No store/pty/datastar deps, so this is
# unit-testable (tests/test_render.nu) -- mirrors examples/2048's pure game.nu.
# The body-touching renderers (render-content, render-pane) stay in serve.nu.

export def html-escape [s: string]: nothing -> string {
  $s | str replace -a '&' '&amp;' | str replace -a '<' '&lt;' | str replace -a '>' '&gt;'
}

# Is `s` a single http(s) URL? Used to offer an "Embed" view on URL notes.
export def is-url [s: string]: nothing -> bool {
  let t = ($s | str trim)
  (($t | str starts-with "http://") or ($t | str starts-with "https://")) and (not ($t | str contains " ")) and (($t | lines | length) == 1)
}

# A clip's render type, derived from kind + mime_type. The seed of the Phase 4
# content-type dispatch (mime -> renderer); buckets:
#   terminal  live pty grid
#   note      editable text (text/plain, text/markdown)
#   image     image/*  -> <img> preview
#   embed     text/uri-list or view=embed -> live <iframe>
#   doc       view=rendered on markdown/text -> rendered HTML
#   file      anything else -> read-only preview / download
export def clip-render-type [c: record]: nothing -> string {
  if $c.kind == "terminal" { return "terminal" }
  if $c.kind == "diff" { return "diff" }
  let view = ($c.view? | default "")
  let m = ($c.mime_type? | default "text/plain")
  # Explicit views: embed -> live <iframe>; rendered -> markdown/text -> HTML.
  if $view == "embed" { return "embed" }
  if $view == "rendered" and ($m in ["text/markdown" "text/plain"]) { return "doc" }
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

# A clip's display label: its set label, else a render-type default.
export def clip-display-label [c: record]: nothing -> string {
  let l = ($c.label? | default "")
  if ($l | is-not-empty) { return $l }
  match (clip-render-type $c) {
    "terminal" => "nu"
    "diff" => "diff ."
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
    "diff" => $"<svg ($a)><path d='M12 3v12'/><path d='m8 11 4 4 4-4'/><path d='M8 5H4'/><path d='M20 5h-4'/><path d='M9 19H4'/><path d='M20 19h-5'/></svg>"
    "image" => $"<svg ($a)><rect width='18' height='18' x='3' y='3' rx='2' ry='2'/><circle cx='9' cy='9' r='2'/><path d='m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21'/></svg>"
    "embed" => $"<svg ($a)><circle cx='12' cy='12' r='10'/><path d='M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20'/><path d='M2 12h20'/></svg>"
    "file" => $"<svg ($a)><path d='M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z'/><path d='M14 2v4a2 2 0 0 0 2 2h4'/></svg>"
    _ => $"<svg ($a)><path d='M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z'/><path d='M14 2v4a2 2 0 0 0 2 2h4'/><path d='M10 9H8'/><path d='M16 13H8'/><path d='M16 17H8'/></svg>"
  }
}
