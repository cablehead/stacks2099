#!/bin/bash

set -euo pipefail

nu tests/test_router.nu
nu tests/test_html.nu
nu tests/test_datastar.nu
nu tests/test_projection.nu
nu tests/test_render.nu
# Endpoint test: drive serve.nu's handler via the binary's `eval --store` so
# .cat/.append are live (the closure needs a store; plain `nu` can't run it).
cargo build -q
"$(dirname "$0")/../target/debug/stacks2099" eval --store "$(mktemp -d)" tests/test_clip_add.nu
deno fmt --check  # whole repo; scope + excludes live in deno.json
cargo fmt --check --all
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings -W clippy::uninlined_format_args
cargo build -p nu_plugin_test
cargo test
