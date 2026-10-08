#!/usr/bin/env bash
# Builds target/kmux.app. Set KMUX_CONFIGURATION=debug for a debug build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$repo_root/target/ghosttykit/GhosttyKit.xcframework" ]]; then
  "$repo_root/scripts/build-ghosttykit.sh"
fi

configuration="${KMUX_CONFIGURATION:-release}"
build=(swift build --package-path "$repo_root/apps/kmux" --configuration "$configuration" --scratch-path "$repo_root/target/kmux-build")
"${build[@]}"
product_dir="$("${build[@]}" --show-bin-path)"

app="$repo_root/target/kmux.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$product_dir/kmux" "$app/Contents/MacOS/kmux"

# Markdown panes: the page (in the repo) and its libraries, downloaded once at
# these versions and checked, so the app works offline.
markdown="$app/Contents/Resources/markdown"
mkdir -p "$markdown" "$repo_root/target/markdown-assets"
cp "$repo_root/apps/kmux/Resources/markdown/"* "$markdown/"
while read -r name url sum; do
  cached="$repo_root/target/markdown-assets/$name"
  if [[ ! -f "$cached" ]] || ! echo "$sum  $cached" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$cached.tmp"
    echo "$sum  $cached.tmp" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch for $name" >&2; exit 1; }
    mv "$cached.tmp" "$cached"
  fi
  cp "$cached" "$markdown/$name"
done <<'ASSETS'
markdown-it.min.js https://cdn.jsdelivr.net/npm/markdown-it@14.3.2/dist/markdown-it.min.js e32488403e2e565ac12a9669bfdf2b1b876eb0a5c84f8e0699884b562d18eb52
purify.min.js https://cdn.jsdelivr.net/npm/dompurify@3.4.16/dist/purify.min.js 2c90a9b46d6463f26038a29b686e82bc91de01fdac9d5229e7cfe3b360134ea2
mermaid.min.js https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js 581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8
ASSETS
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>kmux</string>
<key>CFBundleIdentifier</key><string>dev.kanna.kmux</string>
<key>CFBundleName</key><string>kmux</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "Built $app"
