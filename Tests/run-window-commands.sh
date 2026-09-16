#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-window-tests.XXXXXX)
# Build a temporary harness from the actual private controller, without starting the menu-bar app.
sed '/^private final class ResizeSettingsWindowController/,$d' "$project_dir/Sources/WindowKeys/main.swift" > "$test_dir/main.swift"
cat "$project_dir/Tests/window-commands.swift" >> "$test_dir/main.swift"
xcrun swift "$test_dir/main.swift" "$@"
