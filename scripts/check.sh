#!/bin/bash

set -euo pipefail

# Pin deno to CI's version (.github/workflows/ci.yml). fmt output drifts between
# releases, so a mismatch silently red-fails CI. Keep this in lockstep with CI.
EXPECTED_DENO="2.8.1"
have_deno="$(deno --version | head -1 | awk '{print $2}')"
if [ "$have_deno" != "$EXPECTED_DENO" ]; then
  echo "deno $EXPECTED_DENO required (have $have_deno); CI pins this version." >&2
  echo "install: deno upgrade --version $EXPECTED_DENO" >&2
  exit 1
fi

# router/html/datastar nu stdlib lives in http-nu now and is tested there.
nu tests/test_projection.nu
nu tests/test_render.nu
# Endpoint test: drive serve.nu's handler via the binary's `eval --store` so
# .cat/.append are live (the closure needs a store; plain `nu` can't run it).
cargo build -q
"$(dirname "$0")/../target/debug/stacks2099" eval --store "$(mktemp -d)" tests/test_clip_add.nu
"$(dirname "$0")/../target/debug/stacks2099" eval --store "$(mktemp -d)" tests/test_routes.nu
deno fmt --check  # whole repo; scope + excludes live in deno.json
cargo fmt --check --all
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::uninlined_format_args
cargo build -p nu_plugin_test
cargo test
