#!/usr/bin/env bash
# Builds target/merman/KmuxMerman.xcframework: merman (pinned in
# crates/kmux-merman/Cargo.toml and Cargo.lock) behind kmux's small C bridge.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/scripts/env.sh"
crate="$repo_root/crates/kmux-merman"
out="$repo_root/target/merman"
xcframework="$out/KmuxMerman.xcframework"
library="$repo_root/target/kmux-merman/release/libkmux_merman.a"

# merman needs a newer Rust than the rest of kmux.
if ! rustup run "$KMUX_MERMAN_RUST" rustc --version >/dev/null 2>&1; then
  rustup toolchain install "$KMUX_MERMAN_RUST" --profile minimal
fi
(cd "$crate" && CARGO_TARGET_DIR="$repo_root/target/kmux-merman" cargo "+$KMUX_MERMAN_RUST" build --release --locked)

# Rebuild the xcframework only when the library changed.
if [[ -f "$xcframework/Info.plist" && "$xcframework" -nt "$library" ]]; then
  echo "Up to date: $xcframework"
  exit 0
fi
mkdir -p "$out"
rm -rf "$xcframework" "$out/headers"
mkdir -p "$out/headers"
cp "$crate/include/kmux_merman.h" "$out/headers/"
cat > "$out/headers/module.modulemap" <<'MAP'
module KmuxMerman {
    header "kmux_merman.h"
    export *
}
MAP
xcodebuild -create-xcframework -library "$library" -headers "$out/headers" -output "$xcframework" >/dev/null
echo "Built $xcframework"
