#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
build_dir="$project_dir/build"
app_dir="$build_dir/WindowKeys.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

mkdir -p "$macos_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  "$project_dir/Sources/WindowKeys/main.swift" \
  -o "$macos_dir/WindowKeys"

codesign --force --sign - --identifier com.bland.windowkeys "$app_dir"
echo "$app_dir"
