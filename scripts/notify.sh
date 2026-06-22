#!/usr/bin/env bash
# Host-side watcher: fire a macOS notification (and optionally an iPhone push via
# ntfy.sh) whenever a player connects/disconnects from the Bedrock server.
#
# MUST run on the Mac host (uses osascript) — not inside a container. Ctrl-C to stop.
#
#   ./scripts/notify.sh                       # watch join/leave  -> macOS notification
#   NTFY_TOPIC=my-secret-topic ./scripts/notify.sh   # ALSO push to iPhone via ntfy.sh
#   NOTIFY_TEST=1 ./scripts/notify.sh         # also fire on the `list` "players online"
#                                               line, so you can test without logging in
#
# Set NTFY_TOPIC once in the project .env (NTFY_TOPIC=...) to always push to your phone.
set -uo pipefail

CONTAINER="${CONTAINER:-bedrock}"
TITLE="Minecraft (${CONTAINER})"

# Pick up NTFY_TOPIC from .env if not already in the environment.
if [ -z "${NTFY_TOPIC:-}" ] && [ -f .env ]; then
  NTFY_TOPIC=$(grep -E '^NTFY_TOPIC=' .env 2>/dev/null | cut -d= -f2- || true)
fi

notify() {  # notify <message> <macSound> <ntfyTags>
  local msg="$1" sound="${2:-Ping}" tags="${3:-bell}"
  # 1) macOS desktop notification — prefer terminal-notifier (shows reliably on
  #    Sequoia); fall back to osascript (posts as "Script Editor", often suppressed).
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$TITLE" -message "$msg" -sound "$sound" -group minecraft-notify >/dev/null 2>&1
  else
    local safe=${msg//\\/\\\\}; safe=${safe//\"/\\\"}
    osascript -e "display notification \"$safe\" with title \"$TITLE\" sound name \"$sound\"" >/dev/null 2>&1
  fi
  # 2) iPhone / anywhere via ntfy.sh, if a topic is configured
  if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -fsS -H "Title: $TITLE" -H "Tags: $tags" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 \
      || echo "   (ntfy push failed — check network / topic name)"
  fi
  echo "→ notified: $msg"
}

online_count() {  # echo "X/Y" (current players online) by running `list`, or "" on failure
  local since out
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  sleep 0.3                                   # let the join/leave settle into the count
  docker exec "$CONTAINER" send-command "list" >/dev/null 2>&1 || { echo ""; return; }
  for _ in $(seq 1 10); do
    out=$(docker logs --since "$since" "$CONTAINER" 2>&1 | grep -iE "players online" | tail -1)
    if [ -n "$out" ]; then
      printf '%s' "$out" | sed -E 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#'
      return
    fi
    sleep 0.05
  done
  echo ""
}

echo "🔔 watching '$CONTAINER' for player connect/disconnect (Ctrl-C to stop)…"
if [ -n "${NTFY_TOPIC:-}" ]; then echo "   iPhone push: ON  (ntfy topic '$NTFY_TOPIC')"; else echo "   iPhone push: off (set NTFY_TOPIC to enable)"; fi
[ "${NOTIFY_TEST:-0}" = "1" ] && echo "   TEST mode: will also fire on the 'players online' list line"

# --tail 0 => only NEW log lines (no replay of history), then follow.
docker logs -f --tail 0 "$CONTAINER" 2>&1 | while IFS= read -r line; do
  case "$line" in
    *"Player connected:"*)
      name=$(printf '%s' "$line" | sed -E 's/.*Player connected: ([^,]+),.*/\1/')
      cnt=$(online_count); msg="✅ ${name} joined"; [ -n "$cnt" ] && msg="${msg} — ${cnt} online"
      notify "$msg" "Glass" "player,white_check_mark,video_game" ;;
    *"Player disconnected:"*)
      name=$(printf '%s' "$line" | sed -E 's/.*Player disconnected: ([^,]+),.*/\1/')
      cnt=$(online_count); msg="👋 ${name} left"; [ -n "$cnt" ] && msg="${msg} — ${cnt} online"
      notify "$msg" "Submarine" "player,wave,video_game" ;;
    *"players online:"*)
      if [ "${NOTIFY_TEST:-0}" = "1" ]; then
        count=$(printf '%s' "$line" | sed -E 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#')
        notify "🔔 TEST OK — server reports ${count} players online" "Ping" "bell,test_tube"
      fi ;;
  esac
done
