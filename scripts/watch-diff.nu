#!/usr/bin/env nu
# Watch a git repo and publish its whole-tree diff as `git.diff` store frames.
#
# This is the live feed behind a `kind: diff` clip. serve.nu's /sse loop reads
# `git.diff` (latest-wins, ttl last:1) and morphs the <diff-clip> in place. Run
# it beside a stacks2099 store:
#
#   xs serve / stacks2099 ... --store <DIR>   # the store this writes to
#   XS_ADDR=<DIR>/sock nu scripts/watch-diff.nu [REPO]
#
# REPO defaults to the current directory. The whole-tree patch (tracked changes
# vs HEAD plus untracked files) is recomputed on every change, deduped by
# content hash, and stored in CAS.
#
# Productionised, this becomes a cross.stream service (run the store with
# --services), so the store supervises restart/hot-replace:
#
#   r#'{ run: {|| watch-diff-stream <REPO> } }'# | .append xs.service.gitdiff.create
#
# with this file's `repo-diff`/`watch-diff-stream` loaded as a module. The body
# is identical; only the lifecycle owner differs.

# The cross.stream client (.append/.cat/.cas), talking to $env.XS_ADDR. Inside a
# cross.stream service these are native; standalone we pull in xs.nu.
use ~/xs/xs.nu *

# The whole-tree unified patch: tracked changes vs HEAD, then untracked files
# synthesised as add-only diffs (so new files show up too).
def repo-diff [repo: string]: nothing -> string {
  let tracked = (do { ^git -C $repo diff HEAD } | complete | get stdout)
  let untracked = (
    do { ^git -C $repo ls-files --others --exclude-standard } | complete
    | get stdout | lines | where {|f| ($f | str trim) != "" }
  )
  let added = ($untracked | each {|f|
    do { ^git -C $repo diff --no-index -- /dev/null ($repo | path join $f) } | complete | get stdout
  } | str join)
  $tracked + $added
}

# Publish one frame iff the patch changed since `last`. Returns the new hash.
def publish [repo: string, last: string]: nothing -> string {
  let patch = (repo-diff $repo)
  let h = ($patch | hash sha256)
  if $h == $last { return $last }
  $patch | .append "git.diff" --ttl last:1 --meta {sha: $h, repo: $repo}
  print $"git.diff ($h | str substring 0..12) (($patch | str length)) bytes"
  $h
}

def main [repo: string = "."] {
  let repo = ($repo | path expand)
  print $"watching ($repo)"
  # Seed the current state so a fresh clip paints immediately.
  let seed = (publish $repo "")
  # Recompute on every change; .git churn is skipped, deduping drops no-ops.
  watch $repo --glob "**/*" --debounce 300ms
  | where { ($in.path | path relative-to $repo | str starts-with ".git") == false }
  | generate {|_e, last| {next: (publish $repo $last)} } $seed
}
