#!/usr/bin/env bash
# Install / uninstall / inspect / run the chat bot — the Discord→Minecraft chat bridge
# (scripts/chat-bot.py). Like the notify agent, it runs permanently via launchd: starts
# at login, auto-restarts (KeepAlive). discord.py lives in an isolated venv so we don't
# touch the system Python. macOS host only.
#
#   just bot-run         # run in the FOREGROUND to test (Ctrl-C to stop)
#   just bot-install     # set up the permanent background bot
#   just bot-uninstall   # stop + remove it
#   just bot-running     # is it alive?
set -euo pipefail

LABEL="com.mcserver.chatbot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # project root (this script lives in scripts/)
DOMAIN="gui/$(id -u)"
VENV="$DIR/scripts/.botvenv"
PY="$VENV/bin/python3"

ensure_venv() {
  if [ ! -x "$PY" ]; then
    echo "→ creating isolated Python venv for the bot ($VENV) ..."
    python3 -m venv "$VENV"
  fi
  echo "→ ensuring discord.py is installed ..."
  "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$VENV/bin/pip" install --quiet "discord.py>=2.3,<3" || { echo "❌ pip install discord.py failed"; exit 1; }
}

check_creds() {
  if ! grep -qE '^CHAT_BOT_TOKEN=.+' "$DIR/.env" 2>/dev/null; then
    echo "❌ CHAT_BOT_TOKEN is empty in .env — paste your (reset) bot token there first."; return 1
  fi
  if ! grep -qE '^IN_GAME_CHAT_CHANNEL_ID=[0-9]+' "$DIR/.env" 2>/dev/null; then
    echo "❌ IN_GAME_CHAT_CHANNEL_ID is not set in .env."; return 1
  fi
}

run_foreground() {
  check_creds || exit 1
  ensure_venv
  echo "→ starting Chat bot in the foreground (Ctrl-C to stop) ..."
  cd "$DIR" && exec "$PY" "$DIR/scripts/chat-bot.py"
}

install_agent() {
  check_creds || exit 1
  ensure_venv
  mkdir -p "$HOME/Library/LaunchAgents" "$DIR/bedrock-data/logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$DIR/scripts/chat-bot.py</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DIR/bedrock-data/logs/chat-bot-agent.log</string>
  <key>StandardErrorPath</key><string>$DIR/bedrock-data/logs/chat-bot-agent.log</string>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true   # in case it's already loaded
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "✅ installed + started: $LABEL"
  echo "   bridging : Discord #in-game-chat → Minecraft (tellraw)"
  echo "   agent log: bedrock-data/logs/chat-bot-agent.log"
  echo "   starts at login, restarts itself if it dies. Stop/remove: just bot-uninstall"
}

uninstall_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/rm -f "$PLIST"
  echo "🗑  removed $LABEL (Discord→Minecraft relay will no longer run)"
}

status_agent() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "● running: $LABEL"
    launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|last exit code" | sed 's/^[[:space:]]*/  /'
  else
    echo "○ not loaded — run: just bot-install"
  fi
}

case "${1:-status}" in
  run)       run_foreground ;;
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  status)    status_agent ;;
  *) echo "usage: $0 {run|install|uninstall|status}"; exit 1 ;;
esac
