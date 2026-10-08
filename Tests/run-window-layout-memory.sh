#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-layout-tests.XXXXXX)
xcrun swiftc "$project_dir/Sources/WindowKeys/WindowGeometryAnimation.swift" "$project_dir/Sources/WindowKeys/WindowLayoutMemory.swift" \
  "$project_dir/Tests/window-layout-memory.swift" -o "$test_dir/tests"
"$test_dir/tests"
