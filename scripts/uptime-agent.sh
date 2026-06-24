#!/usr/bin/env bash
# Install / uninstall / inspect a launchd LaunchAgent that posts the daily uptime
# graph for the previous London day to #monitoring at 00:05 local time. macOS host
# only (the graph needs python3 + matplotlib, which live on the host). launchd uses
# the Mac's local clock, which is Europe/London here — so 00:05 = just after UK midnight.
#
#   just uptime-install     # set up + schedule the daily post
#   just uptime-uninstall    # remove it
#   just uptime-running      # is it scheduled?
set -euo pipefail

LABEL="com.mcserver.uptime"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="gui/$(id -u)"
# pyenv shims (python3) + docker + curl must be resolvable in the launchd context
PATHENV="$HOME/.pyenv/shims:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

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
    <string>$DIR/scripts/uptime.sh</string>
    <string>yesterday</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATHENV</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>0</integer>
    <key>Minute</key><integer>5</integer>
  </dict>
  <key>StandardOutPath</key><string>$DIR/bedrock-data/logs/uptime-agent.log</string>
  <key>StandardErrorPath</key><string>$DIR/bedrock-data/logs/uptime-agent.log</string>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "✅ installed: $LABEL  (daily at 00:05 London → #monitoring)"
  echo "   posts     : the previous London day's uptime graph"
  echo "   agent log : bedrock-data/logs/uptime-agent.log"
  echo "   test now  : just uptime        (on-demand, posts immediately)"
  echo "   remove    : just uptime-uninstall"
}

uninstall_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/rm -f "$PLIST"
  echo "🗑  removed $LABEL (no more daily uptime posts)"
}

status_agent() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "● scheduled: $LABEL  (daily 00:05 London)"
    launchctl print "$DOMAIN/$LABEL" | grep -E "state =|run interval|last exit code" | sed 's/^[[:space:]]*/  /' || true
  else
    echo "○ not loaded — run: just uptime-install"
  fi
}

case "${1:-status}" in
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  status)    status_agent ;;
  *) echo "usage: $0 {install|uninstall|status}"; exit 1 ;;
esac
