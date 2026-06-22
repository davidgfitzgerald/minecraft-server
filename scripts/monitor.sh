#!/bin/sh
# Session monitor for the Bedrock server + playit tunnel.
# Dual-use: run on the host (./scripts/monitor.sh) OR as the `monitor` compose
# sidecar. Records relogs (a proxy for the desync bug) plus health/tunnel-churn
# metrics so each desync can be correlated with conditions afterwards.
#
#   MONITOR_OUT        output dir   (default ./bedrock-data/monitoring)
#   MONITOR_INTERVAL   seconds between samples (default 30; or pass as $1)
#   BEDROCK_CONTAINER  default "bedrock"   PLAYIT_CONTAINER default "playit"
set -u
OUT="${MONITOR_OUT:-bedrock-data/monitoring}"
INT="${1:-${MONITOR_INTERVAL:-30}}"
BED="${BEDROCK_CONTAINER:-bedrock}"
PLY="${PLAYIT_CONTAINER:-playit}"
mkdir -p "$OUT"
EV="$OUT/events.csv"
HE="$OUT/health.csv"
[ -f "$EV" ] || echo "time,event,player" > "$EV"
[ -f "$HE" ] || echo "time,players_online,bedrock_cpu_pct,bedrock_mem,playit_session_expired_d,playit_error_d,playit_udp_reauth_d" > "$HE"

echo "monitor: every ${INT}s -> $OUT  (watching $BED / $PLY)"

# --- alerting setup (publishes to the ntfy bus; see scripts/notify-lib.sh) ----
. "$(dirname "$0")/notify-lib.sh" 2>/dev/null || true
command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true
CPU_ALERT="${MONITOR_CPU_ALERT:-300}"        # bedrock CPU% (box64 is multi-core, can exceed 100)
MEM_ALERT="${MONITOR_MEM_ALERT:-2500}"       # bedrock memory, MiB — early warning for the heap crash
COOLDOWN="${MONITOR_ALERT_COOLDOWN:-600}"    # seconds between "still high" reminders while an alarm holds
la_cpu=0; la_mem=0; tunnel_down=0; cpu_alarm=0; mem_alarm=0; server_down=0; today="$(date -u +%Y-%m-%d)"
# clear thresholds = 90% of the alert level (hysteresis, so alarms don't flap on/off)
CPU_CLEAR=$((CPU_ALERT * 9 / 10)); MEM_CLEAR=$((MEM_ALERT * 9 / 10))

mem_mib() {  # integer MiB from a docker mem string (1.2GiB / 950MiB / 512KiB)
  _n=$(echo "$1" | sed -E 's/[A-Za-z]+$//'); _u=$(echo "$1" | sed -E 's/[0-9.]+//')
  case "$_u" in
    GiB|GB) awk "BEGIN{printf \"%d\", ${_n:-0}*1024}" ;;
    MiB|MB) awk "BEGIN{printf \"%d\", ${_n:-0}}" ;;
    KiB|KB) awk "BEGIN{printf \"%d\", ${_n:-0}/1024}" ;;
    *) echo 0 ;;
  esac
}

last="$(date -u +%Y-%m-%dT%H:%M:%S)"
while true; do
  now="$(date -u +%Y-%m-%dT%H:%M:%S)"
  # relog events since last tick -> events.csv  (time,event,player)
  docker logs --since "${last}Z" "$BED" 2>&1 \
    | grep -E "Player (connected|disconnected)" \
    | sed -E "s/\[([0-9: -]+):[0-9]{3} INFO\] Player (connected|disconnected): ([^,]+).*/\1,\2,\3/" \
    >> "$EV" 2>/dev/null
  last="$now"
  # currently online = net connects-disconnects recorded so far
  c="$(grep -c ',connected,' "$EV" 2>/dev/null)"; c="${c:-0}"
  d="$(grep -c ',disconnected,' "$EV" 2>/dev/null)"; d="${d:-0}"
  online=$((c - d)); [ "$online" -lt 0 ] && online=0
  # health + per-interval tunnel churn
  cpu="$(docker stats --no-stream --format '{{.CPUPerc}}' "$BED" 2>/dev/null | tr -d '%')"
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$BED" 2>/dev/null | sed 's| /.*||; s/ //g')"
  se="$(docker logs --since "${INT}s" "$PLY" 2>&1 | grep -c 'session expired')"
  er="$(docker logs --since "${INT}s" "$PLY" 2>&1 | grep -c 'ERROR')"
  ua="$(docker logs --since "${INT}s" "$PLY" 2>&1 | grep -c 'udp channel requires auth')"
  echo "${now}Z,${online},${cpu:-NA},${mem:-NA},${se:-0},${er:-0},${ua:-0}" >> "$HE"

  # ---- ALERTS → ntfy bus (iPhone + Discord bridge + monitor log) -------------
  now_s=$(date +%s)
  # liveness: is the bedrock container actually running? Catches ANY down — a non-box64
  # crash, OOM-kill, manual stop, or a crash-loop that never recovers. The monitor is a
  # separate container, so it stays up to report bedrock dying.
  running=$(docker inspect -f '{{.State.Running}}' "$BED" 2>/dev/null || echo false)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$BED" 2>/dev/null || echo none)
  if [ "$running" = "true" ] && [ "$health" != "unhealthy" ]; then
    [ "$server_down" -eq 1 ] && { publish_bus "✅ server back UP (container running again)" default "alert,white_check_mark"; server_down=0; }
  else
    [ "$server_down" -eq 0 ] && { publish_bus "🔴 SERVER DOWN — bedrock is not serving (running=$running health=$health)" urgent "alert,red_circle"; server_down=1; }
  fi
  # crash: box64 heap corruption. The monitor survives the auto-restart, so it sees it.
  cr=$(docker logs --since "${INT}s" "$BED" 2>&1 | grep -c 'free(): invalid next size')
  [ "${cr:-0}" -gt 0 ] && publish_bus "💥 SERVER CRASH x${cr} (box64 heap corruption) — auto-restarting" urgent "alert,boom,skull"
  # recovery / ready
  rb=$(docker logs --since "${INT}s" "$BED" 2>&1 | grep -c 'Server started\.')
  [ "${rb:-0}" -gt 0 ] && publish_bus "✅ server is up (ready for players)" default "alert,white_check_mark"
  # tunnel heartbeat: playit prints "tunnel running" ~every 3s; silence ⇒ down
  trn=$(docker logs --since "${INT}s" "$PLY" 2>&1 | grep -c 'tunnel running')
  if [ "${trn:-0}" -eq 0 ]; then
    [ "$tunnel_down" -eq 0 ] && { publish_bus "📡 TUNNEL DOWN — friends can't join (no playit heartbeat in ${INT}s)" urgent "alert,satellite,warning"; tunnel_down=1; }
  elif [ "$tunnel_down" -eq 1 ]; then
    publish_bus "✅ tunnel back up" default "alert,white_check_mark"; tunnel_down=0
  fi
  # resource alarms: fire on breach, re-remind every COOLDOWN while held, CLEAR when
  # it drops below 90% of the threshold (hysteresis prevents flapping).
  cpu_i=$(awk "BEGIN{printf \"%d\", ${cpu:-0}}" 2>/dev/null); cpu_i=${cpu_i:-0}
  if [ "$cpu_i" -ge "$CPU_ALERT" ]; then
    if [ "$cpu_alarm" -eq 0 ]; then
      publish_bus "🔥 high CPU ${cpu_i}% (≥${CPU_ALERT}%) — lag/desync risk" high "alert,fire"; cpu_alarm=1; la_cpu=$now_s
    elif [ $((now_s - la_cpu)) -ge "$COOLDOWN" ]; then
      publish_bus "🔥 CPU still high: ${cpu_i}% (≥${CPU_ALERT}%)" high "alert,fire"; la_cpu=$now_s
    fi
  elif [ "$cpu_alarm" -eq 1 ] && [ "$cpu_i" -lt "$CPU_CLEAR" ]; then
    publish_bus "✅ CPU back to normal: ${cpu_i}% (cleared the ${CPU_ALERT}% alarm)" default "alert,white_check_mark"; cpu_alarm=0
  fi
  mem_i=$(mem_mib "${mem:-0MiB}")
  if [ "${mem_i:-0}" -ge "$MEM_ALERT" ]; then
    if [ "$mem_alarm" -eq 0 ]; then
      publish_bus "🧠 high memory ${mem_i}MiB (≥${MEM_ALERT}MiB) — heap-crash early warning" high "alert,warning"; mem_alarm=1; la_mem=$now_s
    elif [ $((now_s - la_mem)) -ge "$COOLDOWN" ]; then
      publish_bus "🧠 memory still high: ${mem_i}MiB (≥${MEM_ALERT}MiB)" high "alert,warning"; la_mem=$now_s
    fi
  elif [ "$mem_alarm" -eq 1 ] && [ "${mem_i:-0}" -lt "$MEM_CLEAR" ]; then
    publish_bus "✅ memory back to normal: ${mem_i}MiB (cleared the ${MEM_ALERT}MiB alarm)" default "alert,white_check_mark"; mem_alarm=0
  fi
  # daily digest at UTC-midnight rollover (counts are cumulative since CSV start)
  d_now="$(date -u +%Y-%m-%d)"
  if [ "$d_now" != "$today" ]; then
    pk=$(awk -F, 'NR>1{if($2+0>m)m=$2+0} END{print m+0}' "$HE" 2>/dev/null)
    publish_bus "📊 daily digest: peak ${pk:-0} online, ${c:-0} joins / ${d:-0} leaves (relog proxy)" default "monitor,bar_chart"
    today="$d_now"
  fi
  # health-aware ping to healthchecks.io each tick:
  #   bedrock healthy → success ping + a status line (shown in the hc.io dashboard log)
  #   bedrock down    → ping /fail (flags the check immediately, independent of the bus/bridge)
  #   monitor/machine dead → no ping at all → hc.io alerts after the grace period
  # So the check is GREEN only when the server is actually serving, and you get an external
  # alert for BOTH "server down" and "whole machine dead" — even if the local stack is broken.
  if [ -n "${HEALTHCHECK_URL:-}" ]; then
    hc_body="players=${online:-0} cpu=${cpu:-NA}% mem=${mem:-NA} crashes=${cr:-0}"
    hc_url="$HEALTHCHECK_URL"; [ "$server_down" -eq 1 ] && hc_url="$HEALTHCHECK_URL/fail"
    curl -fsS -m 10 --data "$hc_body" "$hc_url" >/dev/null 2>&1 || true
  fi
  sleep "$INT"
done
