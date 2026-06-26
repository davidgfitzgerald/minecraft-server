#!/bin/sh
# ntfy "bus" subscriber → fan-out. Streams every event published to the topic and:
#   1) prints it to this container's log  (docker logs mc-bridge / just logs bridge)
#   2) forwards it to the matching Discord CHANNEL via webhook, routed by category.
#
# Category is the FIRST ntfy tag on each event: player | alert | monitor | chat.
# Each category maps to its own channel webhook, falling back to DISCORD_WEBHOOK_URL:
#   player  → DISCORD_WEBHOOK_PLAYER    (#player-activity)
#   alert   → DISCORD_WEBHOOK_SERVER_STATUS     (#server-status)
#   monitor → DISCORD_WEBHOOK_MONITOR   (#monitoring)
#   chat    → DISCORD_WEBHOOK_CHAT      (#in-game-chat)
#   (anything else, or a category with no specific hook) → DISCORD_WEBHOOK_URL
#
# Runs as the `bridge` compose service (curlimages/curl image: has curl + /bin/sh).
set -u
TOPIC="${NTFY_TOPIC:?bridge: NTFY_TOPIC not set}"
SERVER="${NTFY_SERVER:-https://ntfy.sh}"
W_PLAYER="${DISCORD_WEBHOOK_PLAYER:-}"
W_ALERT="${DISCORD_WEBHOOK_SERVER_STATUS:-}"
W_MONITOR="${DISCORD_WEBHOOK_MONITOR:-}"
W_CHAT="${DISCORD_WEBHOOK_CHAT:-}"
W_DEFAULT="${DISCORD_WEBHOOK_URL:-}"

# crude but dependency-free JSON string extractor (no jq in this image)
field() { echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }

# classify by the first recognised category tag, else "other"
category() { for c in player alert monitor chat; do case "$1" in *"\"$c\""*) echo "$c"; return;; esac; done; echo other; }

# pick the channel webhook for a category, with fallback to the default hook
hook_for() {
  case "$1" in
    player)  echo "${W_PLAYER:-$W_DEFAULT}" ;;
    alert)   echo "${W_ALERT:-$W_DEFAULT}" ;;
    monitor) echo "${W_MONITOR:-$W_DEFAULT}" ;;
    chat)    echo "$W_CHAT" ;;   # NO default fallback: chat is high-volume, so stay silent until #in-game-chat is configured
    *)       echo "$W_DEFAULT" ;;
  esac
}

on() { [ -n "$1" ] && echo ON || echo off; }
echo "bridge: subscribing to $SERVER/$TOPIC"
echo "  channels → player:$(on "$W_PLAYER")  alert:$(on "$W_ALERT")  monitor:$(on "$W_MONITOR")  chat:$(on "$W_CHAT")  default:$(on "$W_DEFAULT")"

while true; do
  # -N = no buffering; ntfy streams one JSON object per line, plus keepalive/open events
  curl -sN "$SERVER/$TOPIC/json" | while IFS= read -r line; do
    echo "$line" | grep -q '"event":"message"' || continue   # skip open/keepalive frames
    title=$(field "$line" title)
    msg=$(field "$line" message)
    cat=$(category "$line")
    hook=$(hook_for "$cat")
    echo "[bus:$cat] ${title:+$title — }${msg}"
    if [ -n "$hook" ]; then
      # escape quotes only — keep ntfy's "\n" (multi-line) intact so Discord renders newlines.
      # (our messages never contain literal backslashes, so this stays valid JSON.)
      safe=$(printf '%s' "$msg" | sed 's/"/\\"/g')
      st=$(printf '%s' "${title:-Minecraft}" | sed 's/"/\\"/g')
      curl -fsS -H "Content-Type: application/json" \
        -d "{\"content\":\"**${st}** — ${safe}\"}" "$hook" >/dev/null 2>&1 \
        || echo "   (bridge: discord post failed for category '$cat')"
    fi
  done
  echo "bridge: stream ended, reconnecting in 5s…"
  sleep 5
done
