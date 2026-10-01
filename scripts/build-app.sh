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
sparkle_artifact="$root_dir/.build/artifacts/sparkle/Sparkle"
sparkle_framework="$sparkle_artifact/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    printf '找不到 Sparkle.framework，请先运行 swift package resolve。\n' >&2
    exit 1
fi
mkdir -p "$app_dir/Contents/Frameworks"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_artifact/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE"
xcrun swift "$root_dir/scripts/make-icon.swift" "$root_dir/build/AppIcon.iconset"
iconutil -c icns "$root_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
sign_identity="${LANDROP_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
# Sparkle's XPC services must share the host application's signing identity.
embedded_sparkle="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${sign_args[@]}" "$embedded_sparkle/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" "$embedded_sparkle/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$embedded_sparkle/Autoupdate"
codesign "${sign_args[@]}" "$embedded_sparkle/Updater.app"
codesign "${sign_args[@]}" "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/局域快传.zip"
printf '已生成：%s\n' "$app_dir" "$output_dir/局域快传.zip"
