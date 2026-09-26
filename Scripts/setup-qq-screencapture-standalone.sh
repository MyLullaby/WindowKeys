#!/bin/bash
# Set up a personal, standalone copy of the screenshot plugin from this Mac's
# installed QQ. No Tencent binary is downloaded or included in this repository.
# Verified on 2026-09-26 with macOS 27 / QQ 7.0.1 / plugin 6.6.7.
set -euo pipefail

EXPECTED_BUNDLE_ID='FN2V63AD2J.com.tencent.ScreenCapture3'
EXPECTED_TEAM_ID='FN2V63AD2J'
QQ_APP='/Applications/QQ.app'
DEST_APP="$HOME/Applications/QQ ScreenCapture plugin.app"
DRY_RUN=0
ASSUME_YES=0
CLEAR_QUARANTINE=0

usage() {
  cat <<'HELP'
Usage: setup-qq-screencapture-standalone.sh [--qq-app PATH] [--dry-run] [--yes] [--clear-quarantine]

Copies the plugin from your own installed QQ to ~/Applications, adds the
microphone usage description, ad-hoc re-signs the copy WITHOUT App Sandbox,
enables standalone mode, and assigns Command-Shift-4 (screenshot) and
Command-Shift-5 (recording). Conflicting Apple screenshot shortcuts are backed
up and disabled only when their macOS 27 key codes match known values.

This is a personal-use workaround for a closed-source Tencent binary, not a
WindowKeys feature. It does NOT grant Screen Recording or Microphone access:
macOS requires you to approve these permissions manually for the final app.
It does not modify /Applications/QQ.app or download a third-party DMG.

  --qq-app PATH         Installed QQ.app (default: /Applications/QQ.app)
  --dry-run             Inspect compatibility and show the plan; make no changes
  --yes                 Accept the security/shortcut warning non-interactively
  --clear-quarantine    If necessary, remove ONLY com.apple.quarantine from
                        the verified copy, not the installed QQ or other xattrs
  --help                Show this help

Run on macOS 27 or later; newer QQ/macOS releases may change internal behavior.
If this script refuses an unrecognized layout, do not force old key IDs.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while (( $# > 0 )); do
  case "$1" in
    --qq-app) (( $# >= 2 )) || die '--qq-app needs a path'; QQ_APP=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --clear-quarantine) CLEAR_QUARANTINE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || die 'This script only runs on macOS.'
(( EUID != 0 )) || die 'Run as your normal login user; do not use sudo.'
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 27 )) || die "This workflow was only verified on macOS 27+ (found $(sw_vers -productVersion))."
[[ -d "$QQ_APP" ]] || die "Install QQ first; missing $QQ_APP"
SOURCE_APP="$QQ_APP/Contents/Resources/app/QQ ScreenCapture plugin.app"
[[ -d "$SOURCE_APP" ]] || die "This QQ version has no plugin at $SOURCE_APP"
[[ "$SOURCE_APP" != "$DEST_APP" ]] || die 'Source and destination must differ.'
[[ ! -L "$DEST_APP" ]] || die "Refusing symlink destination: $DEST_APP"
[[ -f "$SOURCE_APP/Contents/Info.plist" ]] || die 'Plugin Info.plist missing.'
source_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
[[ "$source_id" == "$EXPECTED_BUNDLE_ID" ]] || die "Unrecognized plugin bundle ID: $source_id"
exec_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_APP/Contents/Info.plist")
[[ "$exec_name" == 'QQ ScreenCapture plugin' ]] || die "Unrecognized executable: $exec_name"
SOURCE_EXE="$SOURCE_APP/Contents/MacOS/$exec_name"
[[ -f "$SOURCE_EXE" ]] || die 'Plugin executable missing.'
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" || die 'The installed QQ plugin has an invalid signature.'
team=$(/usr/bin/codesign -dv --verbose=2 "$SOURCE_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
[[ "$team" == "$EXPECTED_TEAM_ID" ]] || die "Unexpected signer team: $team"
/usr/bin/strings -a "$SOURCE_EXE" | /usr/bin/grep -F 'settingkeyrunalone' >/dev/null ||
  die 'This plugin version has no known standalone-mode marker.'

# The binary is not redistributed; keeping QQ installed preserves an original.
# A currently running second copy could seize the same bundle ID / hotkeys.
if (( ! DRY_RUN )); then
  if /usr/bin/pgrep -x QQ >/dev/null 2>&1; then
    die 'Quit QQ before setup; this script will not stop QQ for you.'
  fi
  if /usr/bin/pgrep -x 'System Settings' >/dev/null 2>&1; then
    die 'Close System Settings before setup so it cannot race with shortcut preference changes.'
  fi
  if /usr/bin/pgrep -f 'QQ ScreenCapture plugin.app/Contents/MacOS/QQ ScreenCapture plugin' >/dev/null 2>&1; then
    die 'Quit any running QQ screenshot plugin before setup (including older standalone copies).'
  fi
fi

# Guard the Apple hotkey IDs and exact virtual-key/modifier values observed in
# macOS 27. ID 30 or 31 may be bound to Command-Shift-4; ID 184 is the toolbar.
# Do not disable a user-remapped shortcut that is no longer one of these keys.
system_xml=$(defaults export com.apple.symbolichotkeys -) ||
  die 'Cannot read Apple screenshot hotkeys. Configure them manually in System Settings.'
plist_value() {
  printf '%s' "$system_xml" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}
for id in 30 31 184; do
  plist_value "AppleSymbolicHotKeys.$id.enabled" >/dev/null ||
    die "System shortcut ID $id is missing; stop rather than guessing a replacement."
done
matching_ids=''
ids_to_disable=''
for id in 30 31 184; do
  keycode=$(plist_value "AppleSymbolicHotKeys.$id.value.parameters.1")
  modifiers=$(plist_value "AppleSymbolicHotKeys.$id.value.parameters.2")
  if { [[ "$id" == 30 || "$id" == 31 ]] && [[ "$keycode" == 21 && "$modifiers" == 1179648 ]]; } ||
     { [[ "$id" == 184 ]] && [[ "$keycode" == 23 && "$modifiers" == 1179648 ]]; }; then
    matching_ids="$matching_ids $id"
    if [[ "$(plist_value "AppleSymbolicHotKeys.$id.enabled")" == true ]]; then
      ids_to_disable="$ids_to_disable $id"
    fi
  fi
done
[[ " $matching_ids " == *' 184 '* ]] ||
  die 'Command-Shift-5 is not at the known macOS 27 system shortcut ID; configure it manually.'

info "Source: $SOURCE_APP"
info "Destination: $DEST_APP"
info "Plugin version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
info "Matching macOS screenshot shortcut IDs:$matching_ids"
info "Currently enabled conflicts to disable:${ids_to_disable:- none}"
info 'Shortcut plan: Command-Shift-4 screenshot, Command-Shift-5 recording.'
if (( DRY_RUN )); then
  info 'DRY RUN: no app, preference, permission, or system shortcut was changed.'
  exit 0
fi

if (( ! ASSUME_YES )); then
  cat <<'WARNING'

WARNING: This will ad-hoc re-sign a copy of Tencent's plugin with App Sandbox
DISABLED. The copy may have broad screen/network access and may perform Tencent
telemetry or crash reporting. It will replace Apple's Command-Shift-4/5
shortcuts, so those keys will not invoke macOS Screenshot if the plugin exits.
Screen Recording and Microphone permissions still require manual approval.
The signed original inside QQ will not be changed. Continue? [y/N]
WARNING
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || die 'Cancelled; no changes made.'
fi

backup_root="$HOME/Library/Application Support/QQScreenCapture-standalone/backups"
stamp=$(date '+%Y%m%d-%H%M%S')
backup="$backup_root/$stamp-$$"
/bin/mkdir -p -m 700 "$backup"
/usr/bin/defaults export com.apple.symbolichotkeys "$backup/system-hotkeys-before.plist"
pref_domain="$HOME/Library/Preferences/$EXPECTED_BUNDLE_ID"
if /usr/bin/defaults export "$pref_domain" "$backup/plugin-preferences-before.plist" 2>/dev/null; then
  info 'Saved the existing plugin preferences.'
else
  info 'No existing standalone plugin preferences to back up.'
fi
info "Rollback snapshots: $backup"
restore_system_shortcuts() {
  if [[ -n "$ids_to_disable" ]]; then
    /usr/bin/defaults import com.apple.symbolichotkeys "$backup/system-hotkeys-before.plist" || return 1
    /usr/bin/killall SystemUIServer 2>/dev/null || true
  fi
}

/bin/mkdir -p "$HOME/Applications"
[[ ! -L "$HOME/Applications" ]] || die 'Refusing a symlinked ~/Applications directory.'
stage="$HOME/Applications/.QQScreenCapture-staging-$stamp-$$.app"
[[ ! -e "$stage" ]] || die "Staging path already exists: $stage"
/usr/bin/ditto "$SOURCE_APP" "$stage"
info "Prepared staged copy: $stage"

stage_plist="$stage/Contents/Info.plist"
if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$stage_plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string 需要麦克风权限以在录屏时录制音频' "$stage_plist"
elif [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$stage_plist")" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription 需要麦克风权限以在录屏时录制音频' "$stage_plist"
fi

entitlements="$backup/standalone-entitlements.plist"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><false/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.files.downloads.read-write</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST

for framework in "$stage"/Contents/Frameworks/*.framework; do
  name=$(basename "$framework" .framework)
  binary="$framework/Versions/A/$name"
  [[ -f "$binary" ]] || die "Unexpected framework layout: $framework"
  /usr/bin/codesign --force --sign - "$binary"
done
/usr/bin/codesign --force --sign - --entitlements "$entitlements" "$stage"
/usr/bin/codesign --verify --deep --strict "$stage" || die 'Staged copy failed signature verification.'
/usr/bin/codesign -d --entitlements :- "$stage" 2>/dev/null |
  /usr/bin/plutil -p - | /usr/bin/grep -F '"com.apple.security.app-sandbox" => false' >/dev/null || die 'The staged copy is not in standalone no-sandbox mode.'

# Avoid the guide's blanket xattr -cr; never modify the original QQ bundle.
if /usr/bin/xattr -lr "$stage" 2>/dev/null | /usr/bin/grep -F com.apple.quarantine >/dev/null; then
  if (( CLEAR_QUARANTINE )); then
    /usr/bin/xattr -dr com.apple.quarantine "$stage"
    info 'Removed quarantine only from the verified staged copy.'
  else
    die "The staged copy is quarantined. Inspect it, then opt in with --clear-quarantine. Stage remains at: $stage"
  fi
else
  info 'No quarantine attribute present; nothing was removed.'
fi

# Preserve any prior standalone installation rather than overwriting it.
if [[ -e "$DEST_APP" ]]; then
  [[ -d "$DEST_APP" && ! -L "$DEST_APP" ]] || die 'Destination exists but is not a normal app bundle.'
  /bin/mv "$DEST_APP" "$backup/previous-standalone.app"
  info "Prior standalone app retained at $backup/previous-standalone.app"
fi
if ! /bin/mv "$stage" "$DEST_APP"; then
  if [[ -d "$backup/previous-standalone.app" ]]; then
    /bin/mv "$backup/previous-standalone.app" "$DEST_APP"
  fi
  die "Could not place the staged copy. Prior installation was restored if present. Backup: $backup"
fi

/usr/bin/defaults write "$pref_domain" settingkeyrunalone -bool YES
/usr/bin/defaults write "$pref_domain" settingkeycapturehotkey -dict keyCode -int 21 modifierFlags -int 1179648
/usr/bin/defaults write "$pref_domain" JTSettingKeyRecordHotKey -dict keyCode -int 23 modifierFlags -int 1179648
app_xml=$(defaults export "$pref_domain" -)
app_value() {
  printf '%s' "$app_xml" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}
[[ "$(app_value settingkeyrunalone)" == true &&
   "$(app_value settingkeycapturehotkey.keyCode)" == 21 &&
   "$(app_value settingkeycapturehotkey.modifierFlags)" == 1179648 &&
   "$(app_value JTSettingKeyRecordHotKey.keyCode)" == 23 &&
   "$(app_value JTSettingKeyRecordHotKey.modifierFlags)" == 1179648 ]] ||
  die "Standalone preferences could not be verified. Backup: $backup"

# Import an exported snapshot with only known matching shortcut IDs changed.
# This keeps unrelated system keyboard shortcuts as they were at setup time.
if [[ -n "$ids_to_disable" ]]; then
  work="$backup/system-hotkeys-modified.plist"
  /bin/cp "$backup/system-hotkeys-before.plist" "$work"
  for id in $ids_to_disable; do
    /usr/libexec/PlistBuddy -c "Set :AppleSymbolicHotKeys:${id}:enabled false" "$work"
  done
  if ! /usr/bin/defaults import com.apple.symbolichotkeys "$work"; then
    restore_system_shortcuts || true
    die "Could not update Apple shortcuts. Original exported domain: $backup/system-hotkeys-before.plist"
  fi
fi
check=$(defaults export com.apple.symbolichotkeys -)
for id in $matching_ids; do
  if ! printf '%s' "$check" | /usr/bin/plutil -extract "AppleSymbolicHotKeys.$id.enabled" raw -o - - |
       /usr/bin/grep -Fx false >/dev/null; then
    restore_system_shortcuts || true
    die "System shortcut $id was not disabled; attempted to restore the prior domain. Backup: $backup"
  fi
done
if [[ -n "$ids_to_disable" ]]; then
  /usr/bin/killall SystemUIServer 2>/dev/null || true
fi

/usr/bin/open -a "$DEST_APP"
/bin/sleep 2
if ! /usr/sbin/lsof -t "$DEST_APP/Contents/MacOS/$exec_name" >/dev/null 2>&1; then
  restore_system_shortcuts || true
  die "App did not remain running; prior Apple shortcuts were restored if possible. Backup: $backup"
fi
after_launch=$(defaults export "$pref_domain" -)
for expected in 'settingkeyrunalone:true' 'settingkeycapturehotkey.keyCode:21' \
                'settingkeycapturehotkey.modifierFlags:1179648' 'JTSettingKeyRecordHotKey.keyCode:23' \
                'JTSettingKeyRecordHotKey.modifierFlags:1179648'; do
  key=${expected%%:*}
  value=${expected#*:}
  if [[ "$(printf '%s' "$after_launch" | /usr/bin/plutil -extract "$key" raw -o - -)" != "$value" ]]; then
    restore_system_shortcuts || true
    die "Plugin changed shortcut preference $key on launch; prior Apple shortcuts were restored if possible. Backup: $backup"
  fi
done

cat <<EOF

INSTALLED: $DEST_APP
BACKUP:    $backup

AUTOMATIC STEPS VERIFIED: standalone copy and signature, preference values,
Apple shortcut entries and running process. QQ's signed original is untouched.

MANUAL STEPS REQUIRED ON THIS MAC:
1. System Settings → Privacy & Security → Screen & System Audio Recording:
   add/enable "$DEST_APP"; then quit and reopen that app.
2. On first audio recording, approve Microphone for that same app if prompted.
3. Physically test Command-Shift-4 and Command-Shift-5 on nonsensitive content.
   The script cannot pre-approve macOS privacy permissions or prove a hotkey's
   actual delivery from preferences alone.

ROLLBACK: Re-enable the Apple screenshot shortcuts in System Settings → Keyboard
→ Keyboard Shortcuts → Screenshots. The backup directory contains the prior
plugin preferences, the entire prior Apple hotkey domain and any replaced app.
Do not blindly re-import that domain much later: it would also revert unrelated
keyboard changes made since this setup.
EOF
/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' || true
