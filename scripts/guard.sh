#!/usr/bin/env bash
# Human-in-the-loop safety gate for DISRUPTIVE server actions (down / restart /
# recreate / up). Refuses to proceed without explicit confirmation, and if a player
# is online it demands you type the exact player count — so a server with people on
# it can never be taken down by a reflexive keystroke or an accidental command.
#
#   guard.sh "<action description>" [mode]
#     mode = always       (default) confirm even with 0 players  → for down/restart/recreate
#     mode = players-only  only stop if players are online        → for up
#
#   FORCE=1   bypass the gate (explicit opt-out for scripted/automated use)
#
# Exit 0 = approved (caller proceeds).  Exit 1 = denied (caller's recipe aborts).
set -uo pipefail

ACTION="${1:-disruptive action}"
MODE="${2:-always}"
CONTAINER="${BEDROCK_CONTAINER:-bedrock}"

if [ "${FORCE:-0}" = "1" ]; then
  echo "⚠️  FORCE=1 set — skipping confirmation for: $ACTION"
  exit 0
fi

# --- who's online right now? (best-effort; 0 if the server isn't running) -------
count=0; names=""
if docker exec "$CONTAINER" send-command "list" >/dev/null 2>&1; then
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  for _ in $(seq 1 12); do
    block=$(docker logs --since "$since" "$CONTAINER" 2>&1 | grep -iA1 "players online" | tail -2)
    [ -n "$block" ] && break
    sleep 0.05
  done
  count=$(printf '%s' "$block" | sed -nE 's#.*There are ([0-9]+)/[0-9]+ players online.*#\1#p')
  names=$(printf '%s' "$block" | sed -n '2p' | tr -d '\r' | sed 's/^[[:space:]]*//')
  count=${count:-0}
fi

# --- decide whether confirmation is required ------------------------------------
#   2 = players online (strong gate)   1 = soft y/N   0 = nothing to confirm
if [ "$count" -gt 0 ]; then
  need=2
elif [ "$MODE" = "players-only" ]; then
  need=0
else
  need=1
fi
[ "$need" -eq 0 ] && exit 0   # players-only + nobody online → safe, proceed silently

# --- a prompt is needed → require an interactive terminal (else fail CLOSED) -----
if [ ! -t 0 ]; then
  echo "❌ '$ACTION' refused: confirmation required but no interactive terminal."
  echo "   Run it directly in your shell, or set FORCE=1 to override deliberately."
  exit 1
fi

if [ "$need" -eq 2 ]; then
  echo "🛑 STOP: $count player(s) ONLINE right now${names:+ — $names}."
  echo "    '$ACTION' will DISCONNECT them."
  printf "    Type the number of players online (%s) to proceed, or anything else to abort: " "$count"
  read -r ans
  if [ "$ans" = "$count" ]; then echo "✅ confirmed — proceeding."; exit 0; fi
  echo "❌ aborted (nobody was disconnected)."; exit 1
fi

printf "⚠️  About to: %s. No players online. Continue? [y/N] " "$ACTION"
read -r ans
case "$ans" in
  y|Y|yes|YES) echo "proceeding."; exit 0 ;;
  *) echo "❌ aborted."; exit 1 ;;
esac
