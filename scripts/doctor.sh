#!/bin/sh
# Health check for the Minecraft stack. Default prints a human-readable report;
# `--brief` prints one compact line (used by the in-game/Discord !doctor command).
# Pure shell + docker (no just-template braces), so it's reusable from the Justfile
# recipe, notify.sh, and chat-bot.py alike. Run from the project root.
set -u
BED="${BEDROCK_CONTAINER:-bedrock}"
PLY="${PLAYIT_CONTAINER:-playit}"
BRIEF=0; [ "${1:-}" = "--brief" ] && BRIEF=1

# best-effort: load .env so the webhook-count check sees the configured channels
if [ -f .env ]; then set -a; . ./.env 2>/dev/null || true; set +a; fi

running() {  # echo "up" if the named container is running, else "DOWN"
  [ -n "$(docker ps -q -f "name=^/${1}$" -f status=running 2>/dev/null)" ] && echo up || echo DOWN
}
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo none; }

bed=$(running "$BED"); ply=$(running "$PLY"); bedh=$(health "$BED")
trn=$(docker logs --since 15s "$PLY" 2>&1 | grep -c 'tunnel running'); [ "${trn:-0}" -gt 0 ] && tun=up || tun=down

online="?"
if [ "$bed" = up ]; then
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  docker exec "$BED" send-command "list" >/dev/null 2>&1
  sleep 0.4
  online=$(docker logs --since "${since}Z" "$BED" 2>&1 | sed -nE 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#p' | tail -1)
  [ -n "$online" ] || online="?"
fi
mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$BED" 2>/dev/null | sed 's| /.*||; s/ //g'); mem=${mem:-?}
cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$BED" 2>/dev/null); cpu=${cpu:-?}
rc=$(docker inspect -f '{{.RestartCount}}' "$BED" 2>/dev/null || echo "?")
disk=$(df -h bedrock-data 2>/dev/null | awk 'NR==2{print $5}'); disk=${disk:-?}
hooks=0
for v in DISCORD_WEBHOOK_PLAYER DISCORD_WEBHOOK_SERVER_STATUS DISCORD_WEBHOOK_MONITOR DISCORD_WEBHOOK_CHAT DISCORD_WEBHOOK_BACKUP; do
  eval "val=\${$v:-}"; [ -n "$val" ] && hooks=$((hooks + 1))
done

if [ "$BRIEF" -eq 1 ]; then
  printf 'bedrock:%s(%s) tunnel:%s players:%s cpu:%s mem:%s restarts:%s disk:%s hooks:%s/5\n' \
    "$bed" "$bedh" "$tun" "$online" "$cpu" "$mem" "$rc" "$disk" "$hooks"
  exit 0
fi

echo "🩺 Minecraft stack health"
echo "  bedrock   : $bed (health: $bedh)"
echo "  playit    : $ply (tunnel: $tun)"
echo "  players   : $online"
echo "  cpu / mem : $cpu / $mem"
echo "  restarts  : $rc (since container create)"
echo "  disk      : $disk used on the bedrock-data filesystem"
echo "  webhooks  : $hooks/5 Discord channels configured"
