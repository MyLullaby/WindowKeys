#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
test_dir=$(mktemp -d /tmp/windowkeys-translation-tests.XXXXXX)
cat "$project_dir/Sources/WindowKeys/Translation.swift" "$project_dir/Tests/translation.swift" > "$test_dir/main.swift"
xcrun swift "$test_dir/main.swift"
