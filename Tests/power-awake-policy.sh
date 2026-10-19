#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../Resources/power-awake"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TEST_DIR="$TMP"
PMSET="$TMP/pmset"
STATE="$TMP/state"
cat > "$PMSET" <<'MOCK'
#!/bin/bash
set -eu
case "$*" in
    '-g batt')
        case "$(cat "$TEST_DIR/source")" in
            ac) echo "Now drawing from 'AC Power'" ;;
            battery) echo "Now drawing from 'Battery Power'" ;;
            unknown) echo 'Unrecognized power source' ;;
            error) exit 1 ;;
        esac
        printf ' -InternalBattery-0 (id=123)\t%s%%; discharging; present: true\n' "$(cat "$TEST_DIR/percent")" ;;
    '-g') printf 'System-wide power settings:\n SleepDisabled %s\n' "$(cat "$TEST_DIR/disabled")" ;;
    '-g custom') printf 'Battery Power:\n sleep 1\nAC Power:\n sleep %s\n' "$(cat "$TEST_DIR/idle")" ;;
    '-a disablesleep '*) echo "$3" > "$TEST_DIR/disabled"; echo "$*" >> "$TEST_DIR/writes" ;;
    '-c sleep '*) echo "$3" > "$TEST_DIR/idle"; echo "$*" >> "$TEST_DIR/writes" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$PMSET"
echo 0 > "$TMP/disabled"
echo 7 > "$TMP/idle"
echo ac > "$TMP/source"
echo 10 > "$TMP/percent"
save_state
[[ "$(cat "$STATE/disablesleep")" == 0 && "$(cat "$STATE/ac-sleep")" == 7 ]]
reconcile >/dev/null
[[ "$(cat "$TMP/disabled")" == 1 ]]
reconcile >/dev/null
[[ "$(wc -l < "$TMP/writes" | tr -d ' ')" == 1 ]]
echo battery > "$TMP/source"
for percent in 100 80 51 50 49 0 unknown 101; do
    echo "$percent" > "$TMP/percent"
    reconcile >/dev/null
    case "$percent" in
        100|80|51|50) [[ "$(cat "$TMP/disabled")" == 1 ]] ;;
        *) [[ "$(cat "$TMP/disabled")" == 0 ]] ;;
    esac
done
echo 80 > "$TMP/percent"
[[ "$(power_snapshot)" == 'battery 80' ]]
echo 90 > "$TMP/percent"
for source in unknown error; do
    echo 1 > "$TMP/disabled"
    echo "$source" > "$TMP/source"
    reconcile >/dev/null
    [[ "$(cat "$TMP/disabled")" == 0 ]]
done
echo 1 > "$TMP/disabled"
echo 0 > "$TMP/idle"
restore_state
[[ "$(cat "$TMP/disabled")" == 0 && "$(cat "$TMP/idle")" == 7 ]]
echo 'not-a-number' > "$STATE/ac-sleep"
if restore_state 2>/dev/null; then echo 'Invalid state accepted!' >&2; exit 1; fi
rm "$STATE/ac-sleep"
if restore_state 2>/dev/null; then echo 'Missing state accepted!' >&2; exit 1; fi
echo 'PASS: AC at low charge; battery 100/80/51/50/49/0; invalid charge; unknown/error fallback; idempotent reconciliation; restore; invalid/missing state.'

OWNER_PID=$$
OWNER_START=$(owner_start $$)
owner_alive
OWNER_START='different start time'
if owner_alive; then echo 'Reused PID accepted!' >&2; exit 1; fi
echo 'PASS owner exit/start-time mismatch detection'

# Test the actual app-worker entrypoint with a departed owner and mock system tools.
HELPER="$TMP/helper"
PLIST="$TMP/helper.plist"
LAUNCHCTL="$TMP/launchctl"
cat > "$LAUNCHCTL" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_DIR/launchctl-calls"
MOCK
chmod +x "$LAUNCHCTL"
echo 7 > "$STATE/ac-sleep"
echo 1 > "$TMP/disabled"
echo 0 > "$TMP/idle"
touch "$HELPER" "$PLIST"
if [[ "$EUID" == 0 ]]; then
    (main --app-daemon 999999 'missing process')
else
    (OWNER_PID=999999; OWNER_START='missing process'; trap app_daemon_cleanup EXIT
     while owner_alive; do reconcile; done)
fi
[[ "$(cat "$TMP/disabled")" == 0 && "$(cat "$TMP/idle")" == 7 ]]
[[ ! -e "$STATE" && ! -e "$HELPER" && ! -e "$PLIST" ]]
[[ "$(cat "$TMP/launchctl-calls")" == 'bootout system/local.power-awake' ]]
echo 'PASS owner-exit restores settings, removes artifacts and unloads service'
