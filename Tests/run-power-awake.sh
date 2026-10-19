#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-power-tests.XXXXXX)
bash -n "$project_dir/Resources/power-awake"
bash "$project_dir/Tests/power-awake-policy.sh"
xcrun swiftc -swift-version 5 "$project_dir/Sources/WindowKeys/PowerAwakeController.swift" \
  "$project_dir/Tests/power-awake.swift" -o "$test_dir/tests"
"$test_dir/tests" "$@"
