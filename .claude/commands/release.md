---
allowed-tools: Bash, Edit, Read, Glob
argument-hint: [version] (e.g., 0.1.0)
description: Release process - version bump, tag, GitHub Actions build, Homebrew tap
---

# Release Process for stacks2099

stacks2099 is an application binary, not a published crate -- there is no
`cargo publish`. Pushing a tag triggers `.github/workflows/release.yml`, which
builds Linux / macOS (arm64) / Windows and publishes a GitHub Release.
We then point the Homebrew tap at the new macOS build.

## Pre-flight

Current branch: !`git branch --show-current`

Recent releases: !`git tag --sort=-version:refname | grep -v dev | head -5`

Current version: !`grep '^version' Cargo.toml | head -1`

## Steps

### 1. Version bump

- Set `version` in `Cargo.toml` to `$ARGUMENTS`.
- `cargo check` to update `Cargo.lock`.

### 2. Commit and tag

```bash
git add Cargo.toml Cargo.lock
git commit -m "chore: release v$ARGUMENTS"
git tag v$ARGUMENTS
git push && git push origin v$ARGUMENTS
```

Pushing the tag triggers the release workflow. Tags containing `-dev.` publish
as prereleases.

### 3. Watch the build

```bash
gh run list --workflow=release.yml --limit 1
gh run watch <run-id> --exit-status
```

All three targets must go green:
`x86_64-unknown-linux-gnu`, `aarch64-apple-darwin`, `x86_64-pc-windows-msvc`.

### 4. Verify the release

```bash
gh release view v$ARGUMENTS
```

Confirm all three archives are attached. Release notes are auto-generated
(`generate_release_notes`); refine with `gh release edit v$ARGUMENTS --notes ...`
if needed.

### 5. Update the Homebrew tap (cablehead/tap)

The release tarballs hold the binary at their root, so the formula installs it
directly. Wait ~10s after the build for the GitHub CDN, then:

```bash
cd /tmp && rm -rf homebrew-tap && gh repo clone cablehead/homebrew-tap && cd homebrew-tap
arm="https://github.com/cablehead/stacks2099/releases/download/v$ARGUMENTS/stacks2099-aarch64-apple-darwin.tar.gz"
sha=$(curl -sL "$arm" | sha256sum | cut -d' ' -f1)
echo "$sha"
```

Write `Formula/stacks2099.rb` (substitute the sha):

```ruby
class Stacks2099 < Formula
  desc "Server-projected terminal + notes workspace in a single Nushell-powered binary"
  homepage "https://github.com/cablehead/stacks2099"
  url "https://github.com/cablehead/stacks2099/releases/download/v$ARGUMENTS/stacks2099-aarch64-apple-darwin.tar.gz"
  sha256 "<sha>"
  license "MIT"
  version "$ARGUMENTS"

  def install
    bin.install "stacks2099"
  end

  test do
    system "#{bin}/stacks2099", "--help"
  end
end
```

(arm64 only, matching the other formulas in the tap; add an `on_intel` URL +
sha for `x86_64-apple-darwin` if Intel support is wanted.) Commit and push:

```bash
git add Formula/stacks2099.rb
git commit -m "stacks2099 v$ARGUMENTS"
git push
```

Verify: `brew install cablehead/tap/stacks2099 && stacks2099 --help`

### 6. Bump to the next dev version

```bash
# Cargo.toml version -> next patch with -dev (e.g. 0.1.0 -> 0.1.1-dev)
cargo check
git add Cargo.toml Cargo.lock
git commit -m "chore: bump to v<next>-dev"
git push
```

## Done

- GitHub release: https://github.com/cablehead/stacks2099/releases/tag/v$ARGUMENTS
- Homebrew: `brew install cablehead/tap/stacks2099`
