#!/usr/bin/env bash
# Generate the 4-panel uptime graph (London time) and post it to #monitoring as a
# Discord attachment + text digest. Status is authoritative (healthchecks.io flips);
# detail panels come from the local monitor health.csv. Host-only (needs python3 +
# matplotlib, which the slim monitor container deliberately doesn't carry).
#
#   scripts/uptime.sh                # last 24h (rolling)
#   scripts/uptime.sh yesterday      # the previous London calendar day (used by the daily agent)
#   scripts/uptime.sh today          # today so far (London)
#   scripts/uptime.sh 12h            # rolling 12 hours
#   scripts/uptime.sh 2026-06-23     # a specific London calendar day
#
#   --no-post   render + print the summary, but DON'T post to Discord (local preview)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$DIR" || exit 1

# load .env (HEALTHCHECK_URL / HEALTHCHECK_API_KEY / DISCORD_WEBHOOK_MONITOR)
set -a; [ -f .env ] && . ./.env; set +a

POST=1; SPEC=""
for a in "$@"; do
  case "$a" in
    --no-post) POST=0 ;;
    *) SPEC="$a" ;;
  esac
done

# translate the friendly SPEC into uptime_graph.py args
case "$SPEC" in
  "")                       WIN=(--hours 24) ;;
  yesterday|today)          WIN=(--day "$SPEC") ;;
  [0-9]*h)                  WIN=(--hours "${SPEC%h}") ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) WIN=(--day "$SPEC") ;;
  *) echo "unrecognised window '$SPEC' (use: yesterday|today|Nh|YYYY-MM-DD)"; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 1; }
python3 -c "import matplotlib" 2>/dev/null || { echo "python3 matplotlib not installed (pip install matplotlib)"; exit 1; }

PNG="$(mktemp -t uptime).png"
CRASHES=$(docker logs bedrock 2>&1 | grep -c 'free(): invalid next size' 2>/dev/null || echo 0)

echo "→ rendering uptime graph (${SPEC:-last 24h}) ..."
SUMMARY=$(python3 scripts/uptime_graph.py --health bedrock-data/monitoring/health.csv \
            --out "$PNG" --crashes "$CRASHES" "${WIN[@]}")
rc=$?
[ $rc -eq 0 ] || { echo "render failed (rc=$rc)"; rm -f "$PNG"; exit $rc; }
echo "$SUMMARY"

if [ "$POST" -eq 0 ]; then
  echo "→ --no-post: graph at $PNG (not posted)"; exit 0
fi
if [ -z "${DISCORD_WEBHOOK_MONITOR:-}" ]; then
  echo "→ DISCORD_WEBHOOK_MONITOR unset — not posting. Graph at $PNG"; exit 0
fi

# build payload_json with correct UTF-8 (emoji-safe), then multipart-upload the PNG
PAYLOAD="$(mktemp -t uptimepayload).json"
SUMMARY="$SUMMARY" python3 -c "import json,os; open('$PAYLOAD','w').write(json.dumps({'content':os.environ['SUMMARY']}, ensure_ascii=False))"
code=$(curl -sS -o /dev/null -w '%{http_code}' \
  -F "payload_json=<$PAYLOAD" \
  -F "file=@$PNG;type=image/png" \
  "$DISCORD_WEBHOOK_MONITOR")
rm -f "$PAYLOAD"
if [ "$code" = "200" ] || [ "$code" = "204" ]; then
  echo "→ posted to #monitoring (HTTP $code)"
else
  echo "→ Discord post failed (HTTP $code) — graph kept at $PNG"; exit 1
fi
rm -f "$PNG"
