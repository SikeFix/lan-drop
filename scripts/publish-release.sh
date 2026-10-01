#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"
publish=false
if [[ "${1:-}" == "--publish" ]]; then
    publish=true
    shift
fi
notes_file="${1:-}"
if [[ -z "$notes_file" || ! -f "$notes_file" || $# -ne 1 ]]; then
    printf '用法：%s [--publish] 发布说明.md\n默认仅准备并验证安装包；--publish 发布到 GitHub。\n' "$0" >&2
    exit 1
fi
notes_file="$(cd "$(dirname "$notes_file")" && pwd)/$(basename "$notes_file")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '版本号应为 x.y.z。\n' >&2
    exit 1
fi
repository="SikeFix/lan-drop"
signing_account="com.sikefix.landrop.sparkle"
tag="v$version"
release_dir="$root_dir/build/release-$version"
archive_dir="$release_dir/updates"
archive_name="LanDrop-macOS-universal-$tag.zip"
if [[ "$publish" == true ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        printf '请先提交源代码和发布说明，再发布对应的提交。\n' >&2
        exit 1
    fi
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
        printf '版本 %s 已存在，请提升版本号，避免替换已签名的更新。\n' "$tag" >&2
        exit 1
    fi
fi

LANDROP_OUTPUT_DIR="$release_dir" ./scripts/build-app.sh
sparkle_tools="$root_dir/.build/artifacts/sparkle/Sparkle/bin"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
actual_key="$("$sparkle_tools/generate_keys" --account "$signing_account" -p)"
if [[ "$actual_key" != "$expected_key" ]]; then
    printf '本机钥匙串的更新公钥与应用不一致，停止发布。\n' >&2
    exit 1
fi
mkdir -p "$archive_dir"
if [[ -e "$archive_dir/appcast.xml" || -e "$archive_dir/$archive_name" ]]; then
    printf '发布准备目录已存在：%s\n请检查并移动该目录后重新运行，避免覆盖已签名文件。\n' "$archive_dir" >&2
    exit 1
fi
cp "$release_dir/局域快传.zip" "$archive_dir/$archive_name"
cp "$notes_file" "$archive_dir/${archive_name%.zip}.md"
"$sparkle_tools/generate_appcast" --account "$signing_account" \
    --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
    --link "https://github.com/$repository" --embed-release-notes \
    --maximum-deltas 0 "$archive_dir"
xcrun swift "$root_dir/scripts/verify-update.swift" Resources/Info.plist \
    "$archive_dir/appcast.xml" "$archive_dir/$archive_name"
(cd "$archive_dir" && shasum -a 256 "$archive_name" > "SHA256SUMS-$tag.txt")
printf '已准备并验证更新：%s\n' "$archive_dir"
if [[ "$publish" != true ]]; then
    exit 0
fi

# Keep the release hidden until all three assets are uploaded successfully.
commit="$(git rev-parse HEAD)"
gh release create "$tag" --repo "$repository" --target "$commit" --draft \
    --title "局域快传 $tag" --notes-file "$notes_file" \
    "$archive_dir/$archive_name" "$archive_dir/SHA256SUMS-$tag.txt" "$archive_dir/appcast.xml"
gh release edit "$tag" --repo "$repository" --draft=false --latest
gh release view "$tag" --repo "$repository" --json url --jq .url
