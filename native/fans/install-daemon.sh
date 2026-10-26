#!/bin/bash
# Install the UniApi fan helper as a root LaunchDaemon, so fan control stops asking for the
# administrator password every time the app or the server restarts. The server runs this through
# exactly one `osascript ... with administrator privileges` dialog; after that the daemon is
# started by launchd at boot and every UniApi server attaches to it silently.
#
#   install-daemon.sh install <path to built uniapi-fans> <uid>
#   install-daemon.sh uninstall
#
# Why the binary is COPIED instead of pointed at. data/bin/uniapi-fans is writable by the logged-in
# user, and a LaunchDaemon executing a user-writable file as root is a local privilege escalation:
# anything running as that user could overwrite it and own the machine at the next boot. The
# installed copy is root-owned and non-writable, which is also why rebuilding the helper needs one
# more password - there is no way to let unprivileged code update a root-executed binary that is
# not the same hole. Do not "fix" that by having the daemon self-update from the repo.
set -euo pipefail
LABEL=app.devved.uniapi.fans
TOOLS=/Library/PrivilegedHelperTools
TARGET="$TOOLS/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ "$(id -u)" = 0 ] || { echo "install-daemon.sh must run as root" >&2; exit 2; }

case "${1:-}" in
  uninstall)
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$TARGET"
    echo "removed $LABEL"
    exit 0 ;;
  install) ;;
  *) echo "usage: install-daemon.sh install <binary> <uid> | uninstall" >&2; exit 2 ;;
esac

SOURCE="${2:-}"
OWNER="${3:-}"
[ -n "$SOURCE" ] && [ -f "$SOURCE" ] && [ -x "$SOURCE" ] || { echo "no executable helper at '$SOURCE'" >&2; exit 2; }
case "$OWNER" in ''|*[!0-9]*) echo "uid must be numeric" >&2; exit 2 ;; esac
# Only a real login account. A daemon serving uid 0 would hand root's socket to root's own code,
# and the helper itself refuses anything below 501 anyway.
[ "$OWNER" -ge 501 ] || { echo "refusing to install for system uid $OWNER" >&2; exit 2; }

install -d -o root -g wheel -m 755 "$TOOLS"
# Stage beside the target and rename over it. The target is then never briefly present with the
# wrong owner or mode, and a daemon that is still running keeps its own inode until launchd
# restarts it - `codesign --force` style in-place rewriting could kill a live root helper before
# its watchdog restored automatic fan control.
tmp="$(mktemp "$TARGET.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat "$SOURCE" > "$tmp"
chown root:wheel "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$TARGET"
trap - EXIT

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TARGET</string>
    <string>--daemon</string>
    <string>$OWNER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "installed $LABEL for uid $OWNER"
