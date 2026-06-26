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
EV="$OUT/events.csv"; EV_HDR="time,event,player"
HE="$OUT/health.csv"; HE_HDR="time,players_online,bedrock_cpu_pct,bedrock_mem,playit_session_expired_d,playit_error_d,playit_udp_reauth_d"
[ -f "$EV" ] || echo "$EV_HDR" > "$EV"
[ -f "$HE" ] || echo "$HE_HDR" > "$HE"

# --- log rotation (docker json-file style: cap each file's size, keep N files) ----
# When the active file reaches MAX_BYTES it becomes f.1; existing f.1→f.2 … and the
# oldest (f.<MAX_FILES-1>) is dropped, so at most MAX_FILES files exist per stream
# (the active one + MAX_FILES-1 rotated). A fresh active file re-gets its CSV header.
MAX_BYTES="${MONITOR_LOG_MAX_BYTES:-10485760}"   # 10 MiB per file
MAX_FILES="${MONITOR_LOG_MAX_FILES:-10}"         # files kept per stream, including the active one
rotate_log() {  # $1=active file  $2=header line
  _f="$1"; _hdr="$2"
  _sz=$(wc -c < "$_f" 2>/dev/null | tr -d '[:space:]'); _sz=${_sz:-0}
  [ "$_sz" -lt "$MAX_BYTES" ] && return
  _i=$((MAX_FILES - 1)); rm -f "${_f}.${_i}" 2>/dev/null     # drop the oldest
  while [ "$_i" -gt 1 ]; do
    _j=$((_i - 1)); [ -f "${_f}.${_j}" ] && mv -f "${_f}.${_j}" "${_f}.${_i}"; _i=$_j
  done
  mv -f "$_f" "${_f}.1"; echo "$_hdr" > "$_f"
}

echo "monitor: every ${INT}s -> $OUT  (watching $BED / $PLY)  [rotate: ${MAX_FILES}x${MAX_BYTES}B/file]"

# --- alerting setup (publishes to the ntfy bus; see scripts/notify-lib.sh) ----
. "$(dirname "$0")/notify-lib.sh" 2>/dev/null || true
command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true
CPU_ALERT="${MONITOR_CPU_ALERT:-300}"        # bedrock CPU% (box64 is multi-core, can exceed 100)
MEM_ALERT="${MONITOR_MEM_ALERT:-2500}"       # bedrock memory, MiB — early warning for the heap crash
COOLDOWN="${MONITOR_ALERT_COOLDOWN:-600}"    # seconds between "still high" reminders while an alarm holds
la_cpu=0; la_mem=0; tunnel_down=0; cpu_alarm=0; mem_alarm=0; server_down=0; today="$(date -u +%Y-%m-%d)"; last_online=0
# crash counter baseline: bedrock's RestartCount climbs each time `restart: unless-stopped`
# revives a crashed process. We alert on any INCREASE; a recreate resets it to 0 (a decrease)
# and we just re-baseline silently. Seed from the current value so restarts that happened
# before the monitor started are treated as already-known, not re-announced on (re)start.
last_restart=$(docker inspect -f '{{.RestartCount}}' "$BED" 2>/dev/null); last_restart=${last_restart:-0}
# tunnel boot-grace: a just-(re)started playit takes longer than one interval to
# authenticate and bring the tunnel up, so "no heartbeat yet" right after the stack
# restarts is EXPECTED — not an outage. tunnel_seen latches once we've actually seen
# the tunnel up this session (so a real drop is still caught instantly); until then we
# stay quiet for TUNNEL_GRACE seconds so the monitor doesn't false-fire "TUNNEL DOWN"
# the instant everything comes back up. After the grace, a tunnel that never came up
# IS reported (covers a genuinely broken tunnel at boot).
tunnel_seen=0; START_TS=$(date +%s); TUNNEL_GRACE="${MONITOR_TUNNEL_GRACE:-150}"
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

online_now() {  # authoritative current player count via the server's own `list`
  # Echoes an integer, or "" if the server can't be reached. This is the source of
  # truth: the net connects-disconnects tally drifts permanently whenever a crash/
  # restart kills sessions without logging "Player disconnected".
  _since=$(date -u +%Y-%m-%dT%H:%M:%S)
  docker exec "$BED" send-command "list" >/dev/null 2>&1 || { echo ""; return; }
  _i=0
  while [ "$_i" -lt 20 ]; do                      # poll this list's output for ~2s (a just-restarted server under load can be slow to answer)
    sleep 0.1
    _cnt=$(docker logs --since "${_since}Z" "$BED" 2>&1 \
      | sed -nE 's#.*There are ([0-9]+)/[0-9]+ players online.*#\1#p' | tail -1)
    [ -n "$_cnt" ] && { echo "$_cnt"; return; }
    _i=$((_i + 1))
  done
  echo ""
}

last="$(date -u +%Y-%m-%dT%H:%M:%S)"
while true; do
  now="$(date -u +%Y-%m-%dT%H:%M:%S)"
  rotate_log "$EV" "$EV_HDR"; rotate_log "$HE" "$HE_HDR"   # roll over before this tick's appends
  # relog events since last tick -> events.csv  (time,event,player)
  docker logs --since "${last}Z" "$BED" 2>&1 \
    | grep -E "Player (connected|disconnected)" \
    | sed -E "s/\[([0-9: -]+):[0-9]{3} INFO\] Player (connected|disconnected): ([^,]+).*/\1,\2,\3/" \
    >> "$EV" 2>/dev/null
  last="$now"
  # liveness (also reused by the alert block below)
  running=$(docker inspect -f '{{.State.Running}}' "$BED" 2>/dev/null || echo false)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$BED" 2>/dev/null || echo none)
  # currently online: ask the server directly (the authoritative source). If `list`
  # can't be reached this tick (e.g. a just-restarted server still booting under load),
  # hold the last authoritative reading rather than the cumulative c-d tally — that
  # tally drifts forever once a crash/restart drops a "disconnected" event, which is
  # exactly how a fresh restart with 0 players gets misreported as "1 online".
  online="$(online_now)"
  if [ -n "$online" ]; then
    last_online="$online"
  elif [ "$running" = "true" ]; then
    online="$last_online"
  else
    online=0; last_online=0     # container down ⇒ nobody online
  fi
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
  # separate container, so it stays up to report bedrock dying. (running/health
  # are computed once near the top of the loop.)
  if [ "$running" = "true" ] && [ "$health" != "unhealthy" ]; then
    [ "$server_down" -eq 1 ] && { publish_bus "✅ server back UP (container running again)" default "alert,white_check_mark"; server_down=0; }
  else
    [ "$server_down" -eq 0 ] && { publish_bus "🔴 SERVER DOWN — bedrock is not serving (running=$running health=$health)" urgent "alert,red_circle"; server_down=1; }
  fi
  # crash: detect via RestartCount, which climbs every time box64 dies and `restart:
  # unless-stopped` revives bedrock IN-PLACE. This is the reliable signal — it survives
  # log rotation and even a crash whose lines have already scrolled out of the --since
  # window, both of which the old plain `docker logs` grep silently missed. The grep is
  # now used only to NAME the cause (heap corruption vs a generic process exit). A manual
  # `docker compose restart` does NOT bump RestartCount, so this never false-fires on
  # an intentional bounce.
  rc_now=$(docker inspect -f '{{.RestartCount}}' "$BED" 2>/dev/null); rc_now=${rc_now:-0}
  cr=0
  if [ "$rc_now" -gt "$last_restart" ]; then
    cr=$((rc_now - last_restart))
    win=$(docker logs --since "${INT}s" "$BED" 2>&1)   # one read; used to name the cause + add context
    heap=$(printf '%s\n' "$win" | grep -ciE 'invalid next size|corrupted size vs|double free or corruption')
    cause="process exited"; [ "${heap:-0}" -gt 0 ] && cause="box64 heap corruption"
    # context: these box64 faults frequently land during a LevelDB AutoCompaction pass (an
    # I/O-heavy world-db rewrite). Flag it so compaction-triggered crashes are obvious at a glance.
    detail=""
    printf '%s\n' "$win" | grep -q 'Running AutoCompaction' && detail=" during a LevelDB AutoCompaction pass"
    publish_bus "💥 SERVER CRASH x${cr} (${cause})${detail} — bedrock died and auto-restarted (restart #${rc_now}). If it keeps crash-looping it may need a manual restart; a 🔴 SERVER DOWN alert follows if it doesn't recover." urgent "alert,boom,skull"
  fi
  last_restart=$rc_now    # re-baseline (also resyncs to 0 after a recreate)
  # recovery / ready
  rb=$(docker logs --since "${INT}s" "$BED" 2>&1 | grep -c 'Server started\.')
  [ "${rb:-0}" -gt 0 ] && publish_bus "✅ server is up (ready for players)" default "alert,white_check_mark"
  # tunnel heartbeat: playit prints "tunnel running" ~every 3s; silence ⇒ down
  trn=$(docker logs --since "${INT}s" "$PLY" 2>&1 | grep -c 'tunnel running')
  if [ "${trn:-0}" -gt 0 ]; then
    tunnel_seen=1
    [ "$tunnel_down" -eq 1 ] && { publish_bus "✅ tunnel back up" default "alert,white_check_mark"; tunnel_down=0; }
  else
    # No heartbeat this tick. Suppress "DOWN" during the boot-grace window unless we've
    # already confirmed the tunnel was up this session (see tunnel_seen above) — this is
    # what stops the spurious "TUNNEL DOWN" that used to fire the moment the stack came
    # back up (the monitor restarts with tunnel_down=0 and out-races playit's first beat).
    if [ "$tunnel_down" -eq 0 ] \
       && { [ "$tunnel_seen" -eq 1 ] || [ $((now_s - START_TS)) -ge "$TUNNEL_GRACE" ]; }; then
      publish_bus "📡 TUNNEL DOWN — friends can't join (no playit heartbeat in ${INT}s)" urgent "alert,satellite,warning"; tunnel_down=1
    fi
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
  # daily digest at UTC-midnight rollover. OFF by default: the richer UK-time uptime
  # graph (host launchd `com.mcserver.uptime`, scripts/uptime.sh) is the daily digest now,
  # so we don't double-post to #monitoring. Re-enable this lightweight in-container text
  # digest with MONITOR_INLINE_DIGEST=1. Counts are cumulative since the logs began and
  # span rotated files ("$EV".* / "$HE".*) so a rotation doesn't reset them (header lines
  # score 0 in the awk/grep, so they're harmless in the merged stream).
  d_now="$(date -u +%Y-%m-%d)"
  if [ "$d_now" != "$today" ]; then
    if [ "${MONITOR_INLINE_DIGEST:-0}" = "1" ]; then
      c=$(cat "$EV" "$EV".* 2>/dev/null | grep -c ',connected,'); c="${c:-0}"
      d=$(cat "$EV" "$EV".* 2>/dev/null | grep -c ',disconnected,'); d="${d:-0}"
      pk=$(cat "$HE" "$HE".* 2>/dev/null | awk -F, '{if($2+0>m)m=$2+0} END{print m+0}')
      publish_bus "📊 daily digest: peak ${pk:-0} online, ${c:-0} joins / ${d:-0} leaves (relog proxy)" default "monitor,bar_chart"
    fi
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
