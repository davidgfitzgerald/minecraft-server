#!/usr/bin/env bash
# Cleanly disconnect every online player BEFORE the stack is torn down, so each one's
# "left" is logged by the server (and posted to #player-activity by the live watcher /
# backfilled by the reconciler) instead of vanishing into a phantom-online state.
#
# Used by `just down`: kick first, give the notifier→bridge a moment to post the leaves,
# THEN the recipe stops the monitor/bridge and removes the stack. A `stop` alone does NOT
# log "Player disconnected", which is why we kick explicitly.
#
#   KICK_REASON       message shown to kicked players (default below)
#   KICK_FLUSH_WAIT   seconds to wait for leaves to post before returning (default 6)
set -uo pipefail

CONTAINER="${CONTAINER:-bedrock}"
REASON="${KICK_REASON:-Server is going down — back soon!}"
FLUSH="${KICK_FLUSH_WAIT:-6}"

docker exec "$CONTAINER" send-command "list" >/dev/null 2>&1 || { echo "→ server not reachable — nothing to kick."; exit 0; }

# read the current "players online" block: count line + the comma-separated names beneath
since=$(date -u +%Y-%m-%dT%H:%M:%S)
block=""
for _ in $(seq 1 12); do
  block=$(docker logs --since "$since" "$CONTAINER" 2>&1 | grep -iA1 "players online" | tail -2)
  [ -n "$block" ] && break
  sleep 0.1
done
count=$(printf '%s' "$block" | sed -nE 's#.*There are ([0-9]+)/[0-9]+ players online.*#\1#p'); count=${count:-0}
if [ "${count:-0}" -eq 0 ]; then echo "→ no players online — clean shutdown, nothing to kick."; exit 0; fi

names_line=$(printf '%s' "$block" | sed -n '2p' | tr -d '\r')
echo "→ ${count} player(s) online: ${names_line}"
echo "→ kicking them cleanly so their 'left' posts before we tear down ..."

# split the names line on commas; kick each (trim surrounding whitespace)
IFS=','; for name in $names_line; do
  name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -z "$name" ] && continue
  echo "   kick: $name"
  docker exec "$CONTAINER" send-command "kick \"$name\" $REASON" >/dev/null 2>&1 || true
done
unset IFS

echo "→ waiting ${FLUSH}s for the leaves to flow to #player-activity ..."
sleep "$FLUSH"
echo "✅ players disconnected cleanly."
