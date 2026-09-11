#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$repo_dir/dist/我的课表.app"
version="${VERSION:-1.0.0}"
dmg_path="$repo_dir/dist/我的课表-$version.dmg"
staging_dir="$(mktemp -d /private/tmp/my-schedule-dmg.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT

if [[ ! -d "$app_bundle" ]]; then
  echo "未找到应用，请先运行 scripts/build-release.sh" >&2
  exit 1
fi

cp -R "$app_bundle" "$staging_dir/我的课表.app"
ln -s /Applications "$staging_dir/应用程序"
rm -f "$dmg_path"
hdiutil create \
  -volname "我的课表" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path"

if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg_path"
fi

shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
echo "$dmg_path"
