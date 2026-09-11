#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo_dir/Sources"
resource_dir="$repo_dir/Resources"
app_bundle="$repo_dir/dist/我的课表.app"
build_dir="$(mktemp -d /private/tmp/my-schedule-release.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

version="${VERSION:-1.0.0}"
build_number="${BUILD_NUMBER:-1}"
bundle_id="${BUNDLE_ID:-local.schedule.widget}"
signing_identity="${SIGNING_IDENTITY:--}"

frameworks=(
  -framework SwiftUI
  -framework AppKit
  -framework PDFKit
  -framework WebKit
  -framework EventKit
  -framework Security
)

for architecture in arm64 x86_64; do
  xcrun swiftc \
    -parse-as-library \
    -target "${architecture}-apple-macos14.0" \
    -module-cache-path "$build_dir/cache-$architecture" \
    -O \
    "${frameworks[@]}" \
    "$source_dir/ScheduleApp.swift" \
    "$source_dir/NJUImporter.swift" \
    -o "$build_dir/我的课表-$architecture"
done

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
lipo -create \
  "$build_dir/我的课表-arm64" \
  "$build_dir/我的课表-x86_64" \
  -output "$app_bundle/Contents/MacOS/ScheduleWidget"

cp "$resource_dir/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$resource_dir/AppIcon.png" "$app_bundle/Contents/Resources/AppIcon.png"
cp "$resource_dir/鼓楼校区地图竖版2024.pdf" "$app_bundle/Contents/Resources/鼓楼校区地图竖版2024.pdf"
cp "$resource_dir/鼓楼校区地图高清.png" "$app_bundle/Contents/Resources/鼓楼校区地图高清.png"

plutil -replace CFBundleShortVersionString -string "$version" "$app_bundle/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_bundle/Contents/Info.plist"
plutil -lint "$app_bundle/Contents/Info.plist"
xattr -cr "$app_bundle"

signing_args=(--force --deep --options runtime --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  signing_args+=(--timestamp)
fi
codesign "${signing_args[@]}" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
file "$app_bundle/Contents/MacOS/ScheduleWidget"
