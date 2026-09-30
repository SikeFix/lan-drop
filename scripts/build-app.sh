#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"
configuration="release"
architecture_args=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--native" ]]; then
    architecture_args=()
elif [[ "${1:-}" == "--debug" ]]; then
    configuration="debug"
    architecture_args=()
fi

swift build -c "$configuration" "${architecture_args[@]}" --product LanDrop
binary_dir="$(swift build -c "$configuration" "${architecture_args[@]}" --show-bin-path)"
output_dir="${LANDROP_OUTPUT_DIR:-$root_dir/dist}"
app_dir="$output_dir/局域快传.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/LanDrop" "$app_dir/Contents/MacOS/LanDrop"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
xcrun swift "$root_dir/scripts/make-icon.swift" "$root_dir/build/AppIcon.iconset"
iconutil -c icns "$root_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
sign_identity="${LANDROP_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == "-" ]]; then
    codesign --force --sign - "$app_dir"
else
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$app_dir"
fi
codesign --verify --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/局域快传.zip"
printf '已生成：%s\n' "$app_dir" "$output_dir/局域快传.zip"
