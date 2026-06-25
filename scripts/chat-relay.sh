#!/usr/bin/env bash
# Post a SERVER-SIDE broadcast to the #in-game-chat Discord webhook.
#
# Why this exists: the chat-bridge behavior pack relays `world.afterEvents.chatSend`,
# which only fires for PLAYER-typed chat. A `say`/`tellraw` issued from the server
# console never triggers chatSend, so those broadcasts would otherwise be invisible in
# Discord. This script closes that gap from the host side — no pack reload / restart
# needed — by POSTing directly to the same webhook the pack uses.
#
#   scripts/chat-relay.sh "the message"   # posts as "📢 Server: the message"
#
# Used by the `just say` / `just say-raw` recipes. Whispers (`just tell`) are private and
# intentionally NOT relayed.
set -uo pipefail

msg="${1:-}"
[ -n "$msg" ] || exit 0

# Webhook from the environment, else from the gitignored .env.
hook="${DISCORD_WEBHOOK_CHAT:-}"
if [ -z "$hook" ] && [ -f .env ]; then
  hook=$(grep -E '^DISCORD_WEBHOOK_CHAT=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
fi
[ -n "$hook" ] || { echo "   ↳ (no DISCORD_WEBHOOK_CHAT set — skipped #in-game-chat relay)"; exit 0; }

# Strip Bedrock §-formatting codes (colour/style) so Discord shows clean text, then
# JSON-encode via python3 so quotes / emoji / unicode can't break the payload.
clean=$(printf '%s' "$msg" | sed -E 's/§.//g')
payload=$(printf '%s' "📢 **Server**: $clean" \
  | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read(), "allowed_mentions": {"parse": []}}))')

curl -fsS -H "Content-Type: application/json" -d "$payload" "$hook" >/dev/null 2>&1 \
  && echo "   ↳ also posted to #in-game-chat" \
  || echo "   ↳ (Discord #in-game-chat relay failed — check network / webhook)"
