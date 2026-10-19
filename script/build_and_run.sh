#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
mode=${1:-run}
case "$mode" in
  run|--verify|--install) ;;
  *) echo 'Usage: build_and_run.sh [--verify|--install]' >&2; exit 2 ;;
esac
"$project_dir/build.sh"
app="$project_dir/build/WindowKeys.app"
if pgrep -x WindowKeys >/dev/null; then pkill -x WindowKeys; fi
if [[ "$mode" == --install ]]; then
  /usr/bin/ditto "$app" /Applications/WindowKeys.app
  app=/Applications/WindowKeys.app
fi
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/open "$app"
sleep 2
pgrep -x WindowKeys >/dev/null
echo "Running: $app (app-bound power protection stops when the old process exits)"
