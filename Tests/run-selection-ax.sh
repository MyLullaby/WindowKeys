#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-selection-ax.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cat "$project_dir/Sources/WindowKeys/Translation.swift" "$project_dir/Tests/selection-ax.swift" > "$test_dir/main.swift"
xcrun swift "$test_dir/main.swift" "$@"
