#!/bin/sh
# Build the Rust core (static lib + island-hook) into build/core. Universal for Release, host arch for Debug.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
OUT="$ROOT/build/core"
mkdir -p "$OUT"
cd "$ROOT/core"
if [ "${CONFIGURATION:-Release}" = "Debug" ]; then
  T="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
  cargo build --release --target "$T"
  cp "target/$T/release/libisland_core.a" "target/$T/release/island-hook" "$OUT/"
else
  for T in aarch64-apple-darwin x86_64-apple-darwin; do cargo build --release --target "$T"; done
  lipo -create target/*-apple-darwin/release/libisland_core.a -output "$OUT/libisland_core.a"
  lipo -create target/*-apple-darwin/release/island-hook -output "$OUT/island-hook"
fi
