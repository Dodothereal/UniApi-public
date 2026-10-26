#!/bin/bash
# One administrator authorization installs an immutable root executable.
# The chosen local user can change only the charging target, never root code.
set -euo pipefail
LABEL=app.devved.uniapi-battery
PLIST=/Library/LaunchDaemons/$LABEL.plist
TOOLS=/Library/PrivilegedHelperTools
INSTALLED=$TOOLS/$LABEL
PARENT='/Library/Application Support/UniApi'
STATE_DIR="$PARENT/Battery"
CONFIG="$STATE_DIR/target"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCE="${3:-$ROOT/native/swift/build.noindex/Helpers/uniapi-battery}"
ACTION="${1:-install}"
[ "$(id -u)" -eq 0 ] || { echo 'Run this installer as administrator.' >&2; exit 1; }
case "$ACTION" in install|uninstall) ;; *) echo 'Expected install or uninstall.' >&2; exit 64;; esac
# Establish protected ancestry first. chmod alone does not remove macOS ACLs.
# Refuse an unsafe existing directory instead of racing a writer while fixing it.
secure_directory() {
  local directory="$1"
  [ ! -L "$directory" ] || { echo "Refusing linked directory: $directory" >&2; exit 1; }
  if [ -e "$directory" ]; then
    [ -d "$directory" ] && [ "$(stat -f %u "$directory")" = 0 ] \
      && [ "$(( 8#$(stat -f %Lp "$directory") & 0022 ))" = 0 ] \
      && [ "$(ls -lde "$directory" | wc -l | tr -d ' ')" = 1 ] \
      || { echo "Unsafe directory ownership, mode or ACL: $directory" >&2; exit 1; }
  else
    install -d -o root -g wheel -m 755 "$directory"
  fi
}
for directory in /Library '/Library/Application Support' /Library/LaunchDaemons "$TOOLS" "$PARENT" "$STATE_DIR"; do
  secure_directory "$directory"
done
# Refuse links at every managed destination, before touching anything as root.
for path in "$TOOLS" "$INSTALLED" "$PARENT" "$STATE_DIR" "$CONFIG" "$PLIST"; do
  [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; exit 1; }
done
stop_controller() {
  local loaded=0
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then loaded=1; fi
  if [ "$loaded" = 0 ] && [ ! -e "$STATE_DIR/preferences.plist" ]; then return; fi
  # Publish off by replacement, never by truncating a possibly hard-linked
  # user-owned target inode. Preserve that user's ability to issue requests.
  local owner=0
  if [ -f "$CONFIG" ]; then owner="$(stat -f %u "$CONFIG")"; fi
  rm -f "$STATE_DIR/target.stop"
  (umask 077; printf 'off\n' > "$STATE_DIR/target.stop")
  chown "$owner":wheel "$STATE_DIR/target.stop"
  mv -f "$STATE_DIR/target.stop" "$CONFIG"
  local started="$(date +%s)"
  if [ "$loaded" = 0 ]; then
    [ -f "$PLIST" ] && [ -x "$INSTALLED" ] || { echo 'Recovery journal exists but the prior controller is missing.' >&2; exit 1; }
    launchctl bootstrap system "$PLIST"
  fi
  for attempt in $(seq 1 120); do
    local state updated
    state="$(plutil -extract state raw -o - "$STATE_DIR/state.json" 2>/dev/null || true)"
    updated="$(plutil -extract updatedAt raw -o - "$STATE_DIR/state.json" 2>/dev/null || true)"
    if [ "$state" = off ] && [[ "$updated" =~ ^[0-9]+$ ]] && [ "$updated" -gt "$((started * 1000))" ] \
        && [ ! -e "$STATE_DIR/preferences.plist" ]; then
      launchctl bootout "system/$LABEL"
      return
    fi
    sleep 1
  done
  echo 'Native restoration is not confirmed. Controller and journal preserved for recovery.' >&2
  exit 1
}
if [ "$ACTION" = uninstall ]; then
  stop_controller
  # A failed rollback must remain recoverable rather than discarding the journal.
  [ ! -e "$STATE_DIR/preferences.plist" ] || { echo "Native preference rollback is incomplete; journal preserved." >&2; exit 1; }
  rm -f "$PLIST" "$INSTALLED" "$CONFIG" "$STATE_DIR/state.json" "$STATE_DIR/state.new" "$STATE_DIR/preferences.new"
  rmdir "$STATE_DIR" 2>/dev/null || true
  echo "Removed $LABEL; unrelated UniApi files preserved."
  exit 0
fi
TARGET_UID="${2:-${SUDO_UID:-}}"
case "$TARGET_UID" in ''|*[!0-9]*) echo 'Pass the local user numeric UID as the second argument.' >&2; exit 64;; esac
[ "$TARGET_UID" -ge 500 ] && id "$TARGET_UID" >/dev/null || { echo 'Expected a local user UID.' >&2; exit 64; }
[ -x "$SOURCE" ] && [ ! -L "$SOURCE" ] || { echo 'Build native/swift/build.sh first.' >&2; exit 1; }
if [ -f "$INSTALLED" ] && [ -f "$PLIST" ]; then
  source "$(dirname "$0")/battery-handoff.sh"
  uniapi_battery_handoff "$SOURCE" "$STATE_DIR" "$INSTALLED" "$PLIST" "$LABEL" "$TARGET_UID"
  exit 0
fi
# A legacy controller restores its native baseline on TERM. Publishing off
# during an upgrade would also retire the only restoration journal. Until its
# compatible handoff is available, an active upgrade must preserve all bytes
# and refuse before stopping the controller or replacing its executable.
if [ -e "$STATE_DIR/preferences.plist" ]; then
  echo 'Active charging upgrade requires a compatible journal handoff; target and controller preserved.' >&2
  exit 1
fi
if [ -e "$CONFIG" ]; then
  [ -f "$CONFIG" ] && [ "$(stat -f %l "$CONFIG")" = 1 ] && [ "$(stat -f %z "$CONFIG")" -le 16 ] \
    || { echo 'Unsafe charging target; controller preserved.' >&2; exit 1; }
  [ "$(cat "$CONFIG")" = off ] || { echo 'Active charging target preserved; a compatible upgrade handoff is required.' >&2; exit 1; }
fi
stop_controller
[ ! -e "$STATE_DIR/preferences.plist" ] || { echo 'Previous native charging settings have not been restored; refusing replacement.' >&2; exit 1; }
install -o root -g wheel -m 755 "$SOURCE" "$INSTALLED"
# Remove an old target inode rather than truncating any pre-existing hard link.
rm -f "$CONFIG" "$STATE_DIR/state.json" "$STATE_DIR/state.new"
(umask 077; printf 'off\n' > "$CONFIG")
chown "$TARGET_UID":wheel "$CONFIG"
chmod 600 "$CONFIG"
rm -f "$PLIST"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$INSTALLED</string><string>daemon</string><string>$CONFIG</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardErrorPath</key><string>/var/log/uniapi-battery.log</string>
</dict></plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap system "$PLIST"
for attempt in 1 2 3 4 5; do
  if [ -f "$STATE_DIR/state.json" ]; then
    echo "Installed $LABEL. Charging controls now need no password."
    cat "$STATE_DIR/state.json"
    exit 0
  fi
  sleep 1
done
echo 'No daemon heartbeat; see /var/log/uniapi-battery.log.' >&2
exit 1
