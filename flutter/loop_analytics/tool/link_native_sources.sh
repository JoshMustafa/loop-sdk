#!/usr/bin/env bash
# Mirrors the monorepo's native LoopCore and LoopAnalytics iOS sources into
# ios/Classes/Vendor as per-file relative symlinks, so the plugin's pod
# compiles them straight from the checkout.
#
# CocoaPods only sees files under the pod root (ios/) and does not descend
# into symlinked directories, so each file is linked on its own. Re-run this
# after adding, removing or renaming a file in ios/Sources/LoopCore or
# ios/Sources/LoopAnalytics, and commit the result.
set -euo pipefail

plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$plugin_dir/../.." && pwd)"
vendor_dir="$plugin_dir/ios/Classes/Vendor"

rm -rf "$vendor_dir"
for module in LoopCore LoopAnalytics; do
  (cd "$repo_dir/ios/Sources" && find "$module" -type f \( -name '*.swift' -o -name 'PrivacyInfo.xcprivacy' \)) |
    sort | while read -r file; do
      link="$vendor_dir/$file"
      mkdir -p "$(dirname "$link")"
      # One "../" per directory between the link and the repo root.
      depth=$(( $(tr -cd '/' <<<"${link#"$repo_dir"/}" | wc -c) ))
      up=$(printf '../%.0s' $(seq 1 "$depth"))
      ln -s "${up}ios/Sources/$file" "$link"
    done
done
