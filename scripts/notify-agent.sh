#!/usr/bin/env bash
# Install / uninstall / inspect a launchd LaunchAgent that runs scripts/notify.sh
# permanently — it starts at login and auto-restarts (KeepAlive), so you get player
# join/leave notifications without keeping a terminal open. macOS host only.
#
#   just notify-install     # set up + start the permanent watcher
#   just notify-uninstall   # stop + remove it
#   just notify-running     # is it alive?
set -euo pipefail

LABEL="com.mcserver.notify"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # project root (this script lives in scripts/)
DOMAIN="gui/$(id -u)"

install_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$DIR/bedrock-data/logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DIR/scripts/notify.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DIR/bedrock-data/logs/notify-agent.log</string>
  <key>StandardErrorPath</key><string>$DIR/bedrock-data/logs/notify-agent.log</string>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true   # in case it's already loaded
  # bootstrap can transiently fail with "Input/output error" if the previous instance
  # isn't fully torn down yet — wait for it to leave, then retry a couple of times.
  for _ in 1 2 3 4 5 6; do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
  for _ in 1 2 3; do launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break; sleep 1; done
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || { echo "❌ launchctl bootstrap failed for $LABEL"; exit 1; }
  echo "✅ installed + started: $LABEL"
  echo "   watching : $DIR/scripts/notify.sh  (player connect/disconnect)"
  echo "   agent log: bedrock-data/logs/notify-agent.log"
  echo "   it now starts at login and restarts itself if it dies or the container recreates."
  echo "   stop/remove with: just notify-uninstall"
}

uninstall_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/rm -f "$PLIST"
  echo "🗑  removed $LABEL (notifications will no longer run in the background)"
}

status_agent() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "● running: $LABEL"
    launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|last exit code" | sed 's/^[[:space:]]*/  /'
  else
    echo "○ not loaded — run: just notify-install"
  fi
}

case "${1:-status}" in
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  status)    status_agent ;;
  *) echo "usage: $0 {install|uninstall|status}"; exit 1 ;;
esac
