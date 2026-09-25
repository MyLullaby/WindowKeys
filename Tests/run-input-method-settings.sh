#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-input-settings-tests.XXXXXX)
# Include the settings controller without launching the menu-bar app.
sed '/^private final class AppDelegate/,$d' "$project_dir/Sources/WindowKeys/main.swift" > "$test_dir/main.swift"
cat "$project_dir/Tests/input-method-settings.swift" >> "$test_dir/main.swift"
cat "$project_dir/Tests/diagnostic-log.swift" >> "$test_dir/main.swift"
xcrun swift "$test_dir/main.swift"
