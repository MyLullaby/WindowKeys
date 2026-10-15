#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
build_dir="$project_dir/build"
app_dir="$build_dir/WindowKeys.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

mkdir -p "$macos_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"

xcrun clang -target arm64-apple-macosx13.0 -O2 -fmodules -DMAX_DISPLAYS=16 \
  -I "$project_dir/Sources/DisplayControl/Vendor" \
  -framework Foundation -framework IOKit -framework CoreDisplay -framework ApplicationServices \
  "$project_dir/Sources/DisplayControl/main.m" \
  "$project_dir/Sources/DisplayControl/Vendor/ioregistry.m" \
  -o "$macos_dir/DisplayControl"
mkdir -p "$contents_dir/Resources"
cp "$project_dir/Sources/DisplayControl/Vendor/LICENSE" "$contents_dir/Resources/m1ddc-LICENSE"
codesign --force --sign - "$macos_dir/DisplayControl"

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  "$project_dir/Sources/WindowKeys/main.swift" \
  "$project_dir/Sources/WindowKeys/WindowLayoutMemory.swift" \
  "$project_dir/Sources/WindowKeys/WindowGeometryAnimation.swift" \
  "$project_dir/Sources/WindowKeys/DisplayControl.swift" \
  -o "$macos_dir/WindowKeys"

codesign --force --sign - --identifier com.bland.windowkeys "$app_dir"
echo "$app_dir"
