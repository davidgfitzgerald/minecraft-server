#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher: Bash). The machine-side twin of
# scripts/guard.sh: stops *Claude* from running disruptive Minecraft-server commands.
#
#   • players online  → DENY  (hard block; Claude must ask David for approval)
#   • nobody online    → ASK   (surface a confirmation to David)
#   • can't tell while server is up → DENY (fail closed)
#   • anything not disruptive → ALLOW (pass through silently)
#
# Reads the hook JSON payload on stdin; replies with a PreToolUse permission decision.
set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

emit() {  # emit <deny|ask|allow> <reason>
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

# Gate ONLY player-affecting ops (stack down / bedrock|playit stop-restart-rm /
# force-recreate / the disruptive `just` recipes). Leaves monitor/bridge & all
# read-only commands untouched.
if ! printf '%s' "$cmd" | grep -Eiq \
    -e 'docker[[:space:]]+compose[[:space:]]+down' \
    -e 'docker[[:space:]]+compose[[:space:]]+up[[:space:]].*--force-recreate' \
    -e 'docker[[:space:]]+compose[[:space:]]+(stop|restart|rm|kill)([[:space:]]+-[^[:space:]]+)*[[:space:]]+(bedrock|playit)' \
    -e 'docker[[:space:]]+(stop|kill|restart|rm)([[:space:]]+-[^[:space:]]+)*[[:space:]]+(bedrock|playit)' \
    -e '(^|[[:space:];&|])just[[:space:]]+(down|restart|recreate|up)([[:space:]]|$)'; then
  exit 0   # not disruptive → allow
fi

# Disruptive → how many players are online?
count=0; names=""
if docker exec bedrock send-command "list" >/dev/null 2>&1; then
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  for _ in $(seq 1 12); do
    block=$(docker logs --since "$since" bedrock 2>&1 | grep -iA1 "players online" | tail -2)
    [ -n "$block" ] && break
    sleep 0.05
  done
  parsed=$(printf '%s' "$block" | sed -nE 's#.*There are ([0-9]+)/[0-9]+ players online.*#\1#p')
  names=$(printf '%s' "$block" | sed -n '2p' | tr -d '\r' | sed 's/^[[:space:]]*//')
  count="${parsed:-UNKNOWN}"   # server up but unparseable → fail closed below
fi

# NOTE: players-online and can't-verify use DENY (not ask) on purpose — deny is a hard
# block that auto mode CANNOT override, whereas auto mode silently auto-approves "ask".
# So the server can never be taken down by Claude/auto-mode while players are on; only a
# human can, by running the guarded `just` recipe in their terminal (typing the count).
if [ "$count" = "UNKNOWN" ]; then
  emit deny "🛑 BLOCKED — could not verify whether players are online before \"$cmd\". Refusing as a precaution. If it's genuinely safe, run it yourself in the terminal."
elif [ "$count" -gt 0 ] 2>/dev/null; then
  emit deny "🛑 BLOCKED — $count player(s) ONLINE right now${names:+ ($names)}. Will NOT run \"$cmd\" — it would disconnect them. This is a hard block: to take the server down with players on, a human must run it (e.g. \`just down\`/\`just restart\`, which makes you type the player count)."
else
  emit ask "\"$cmd\" will stop/restart the Minecraft server. No players are online right now — approve to proceed."
fi
exit 0
