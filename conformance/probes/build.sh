#!/usr/bin/env bash
# Builds the probe contracts to res/<name>.wasm and rewrites res/SHA256SUMS.
#
#   ./build.sh          build, copy, and print whether the hashes changed
#   ./build.sh --check  build and fail if any wasm differs from SHA256SUMS
#
# `cargo build --target wasm32-unknown-unknown --release` with `--cfg near`
# (what cargo-near sets: near-sdk then calls the on-chain host functions,
# e.g. panic_utf8, instead of its pure-Rust fallbacks, which turn a panic
# into a bare wasm trap), on the toolchain in rust-toolchain.toml (1.95.0)
# with its default wasm features (bulk-memory, sign-ext, ...), which
# nearcore 2.14 at protocol 88 accepts. No wasm-opt pass.
# Local paths are remapped so the wasm does not depend on (or reveal) where
# the build ran: with the same toolchain and Cargo.lock the bytes match
# SHA256SUMS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
check=${1:-}

sysroot=$(rustc --print sysroot)
cargo_home=${CARGO_HOME:-$HOME/.cargo}
target_dir=${CARGO_TARGET_DIR:-$here/target}
export CARGO_TARGET_DIR="$target_dir"
export RUSTFLAGS="--remap-path-prefix=$sysroot=/rustc --remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$here=/probes --remap-path-prefix=$target_dir=/target -C link-arg=-s --cfg near"

cargo build --locked --target wasm32-unknown-unknown --release

mkdir -p res
out=$(mktemp -d)
for c in probe ft wrap async_probe; do
  cp "$target_dir/wasm32-unknown-unknown/release/$c.wasm" "$out/$c.wasm"
done
(cd "$out" && shasum -a 256 probe.wasm ft.wasm wrap.wasm async_probe.wasm) > "$out/SHA256SUMS"

if [ "$check" = "--check" ]; then
  if diff -u res/SHA256SUMS "$out/SHA256SUMS"; then
    echo "probes: wasm matches res/SHA256SUMS"
  else
    echo "probes: wasm differs from res/SHA256SUMS" >&2
    exit 1
  fi
else
  cp "$out"/*.wasm res/
  if [ -f res/SHA256SUMS ] && diff -q res/SHA256SUMS "$out/SHA256SUMS" >/dev/null; then
    echo "probes: unchanged"
  else
    cp "$out/SHA256SUMS" res/SHA256SUMS
    echo "probes: res/SHA256SUMS rewritten:"
    cat res/SHA256SUMS
  fi
fi
rm -rf "$out"
