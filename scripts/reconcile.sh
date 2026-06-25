#!/usr/bin/env bash
# Player-activity reconciler (outbox pattern). Run on the host at every server start
# (wired into `just up` / `just restart` / `just recreate`; also `just reconcile`).
#
# The problem it fixes: a crash, a hard kill, or the laptop sleeping can end a player's
# session WITHOUT the live watcher (scripts/notify.sh) ever posting their "left" — so
# #player-activity shows a join with no matching leave and a player looks online forever.
#
# How it works: the server logs are the source of truth for connection events, and
# scripts/notify.sh records every event it DID post to a local outbox ledger
# (bedrock-data/monitoring/posted-events.log). On start we:
#   1. Rebuild the true event timeline from the archived logs (bedrock-data/logs/) plus
#      the running container's own log, splitting each on "Starting Server" boundaries.
#      Anyone still "connected" when a (past) life ends was dropped uncleanly → we
#      synthesise a "left" for them at that life's last-seen timestamp.
#   2. Diff that timeline against the ledger.
#   3. Record every REAL connect/disconnect in the ledger SILENTLY — the live watcher
#      already announced those, so re-posting would just spam the channel. The ONLY thing
#      we ever post is a recent SYNTHETIC leave (a phantom-online heal). That post path is
#      hard-capped (RECONCILE_MAX_POST): if more events than the cap qualify, the ledger is
#      out of sync (e.g. an event-key format change), so we record them all silently and
#      post a SINGLE summary line rather than flooding #player-activity with dozens.
# The CURRENT (running) life is left to the live watcher — we only heal PAST lives, which
# is exactly where the phantom-online bug lives. This keeps the two posters race-free.
#
# Tunables (env):
#   RECONCILE_MAX_AGE_HOURS  don't backfill events older than this (default 48)
#   RECONCILE_MAX_POST       max phantom-heals to post before collapsing to a summary (default 6)
#   RECONCILE_PUBLISH_DELAY  seconds to let the bridge subscribe before posting (default 5)
#   RECONCILE_DRY_RUN=1      print what WOULD be posted; touch nothing
#   RECONCILE_LOGDIR         archived-logs dir (default bedrock-data/logs)
#   LEDGER_FILE              outbox ledger path (default bedrock-data/monitoring/posted-events.log)
set -uo pipefail

CONTAINER="${CONTAINER:-bedrock}"
LOGDIR="${RECONCILE_LOGDIR:-bedrock-data/logs}"
LEDGER_FILE="${LEDGER_FILE:-bedrock-data/monitoring/posted-events.log}"
MAX_AGE_H="${RECONCILE_MAX_AGE_HOURS:-48}"
MAX_POST="${RECONCILE_MAX_POST:-6}"
PUBLISH_DELAY="${RECONCILE_PUBLISH_DELAY:-5}"
DRY="${RECONCILE_DRY_RUN:-0}"

# publish_bus() → ntfy bus → Discord bridge (routes "player" tag to #player-activity)
. "$(dirname "$0")/notify-lib.sh" 2>/dev/null || true

now_s=$(date +%s)
min_s=$(( now_s - MAX_AGE_H * 3600 ))

[ "$DRY" = 1 ] || mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || true
# First run = no init marker yet. On the first run we seed historical REAL events into
# the ledger SILENTLY — they were already posted live when they happened, so re-posting
# would just duplicate what's already in #player-activity. Synthetic "session ended"
# leaves are the events that were NEVER posted (the phantom-online bug), so we DO post
# those even on the first run. The marker is written only by us, so the live watcher
# populating the ledger can't accidentally flip us out of first-run mode.
INIT_MARK="$(dirname "$LEDGER_FILE")/.reconcile-init"
FIRST_RUN=0; [ -f "$INIT_MARK" ] || FIRST_RUN=1

# "YYYY-MM-DD HH:MM:SS" -> epoch (BSD/macOS date). Unknown/unparseable -> 0.
ts_to_epoch() { date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s 2>/dev/null || echo 0; }
fmt_when() {  # "2026-06-24 19:42:11" -> "~19:42 (24 Jun)"; "unknown" -> "(time unknown)"
  [ "$1" = unknown ] && { printf '(time unknown)'; return; }
  local hm="${1:11:5}" d; d=$(date -j -f "%Y-%m-%d %H:%M:%S" "$1" "+%d %b" 2>/dev/null || echo "")
  printf '~%s%s' "$hm" "${d:+ ($d)}"
}

ledger_has() { grep -qxF "$1|$2|$3" "$LEDGER_FILE" 2>/dev/null; }
ledger_add() { ledger_has "$1" "$2" "$3" || printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$LEDGER_FILE"; }

# "[YYYY-MM-DD HH:MM:SS:mmm INFO] ..." -> "YYYY-MM-DD HH:MM:SS"  (millis dropped)
ln_ts() { printf '%s' "$1" | sed -nE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}):[0-9]+ INFO\].*/\1/p'; }

# replay_stream walks a WHOLE log stream (which may span several server lives — every
# "Starting Server" line begins a new life) and emits canonical events on stdout as
# "ts<TAB>event<TAB>player<TAB>kind". When a life ends, anyone still connected is emitted
# as a synthetic "disconnected" at the life's last-seen timestamp — that session died
# uncleanly (crash / kill / restart) and never logged a real "Player disconnected".
RS_ONLINE=""; RS_LAST_TS="unknown"
rs_flush() {  # emit synth leaves for everyone still online, then reset the life
  while IFS= read -r _pl; do
    [ -z "$_pl" ] && continue
    printf '%s\t%s\t%s\tsynth\n' "$RS_LAST_TS" left "$_pl"
  done <<<"$RS_ONLINE"
  RS_ONLINE=""; RS_LAST_TS="unknown"
}
replay_stream() {  # $1=1 ⇒ the FINAL life is the currently-running one → don't synth its tail
  local final_live="${1:-0}" line _ts _pl
  RS_ONLINE=""; RS_LAST_TS="unknown"
  while IFS= read -r line; do
    case "$line" in
      *"Starting Server"*) rs_flush ;;                 # previous life ended here
      *"Player Spawned:"*)                             # the REAL join (a bare "connected" that
                                                       # crashed before spawn never entered the world)
        _ts=$(ln_ts "$line"); _pl=$(printf '%s' "$line" | sed -E 's/.*Player Spawned: (.+) xuid:.*/\1/')
        printf '%s\t%s\t%s\treal\n' "$_ts" joined "$_pl"; RS_LAST_TS="$_ts"
        # keep the set newline-separated with NO trailing newline (the command-substitution
        # in the disconnect branch strips a trailing one, which would mash the next name on).
        grep -qxF "$_pl" <<<"$RS_ONLINE" 2>/dev/null || RS_ONLINE="${RS_ONLINE:+$RS_ONLINE$'\n'}$_pl" ;;
      *"Player disconnected:"*)
        _ts=$(ln_ts "$line"); _pl=$(printf '%s' "$line" | sed -E 's/.*Player disconnected: ([^,]+),.*/\1/')
        printf '%s\t%s\t%s\treal\n' "$_ts" left "$_pl"; RS_LAST_TS="$_ts"
        RS_ONLINE=$(grep -vxF "$_pl" <<<"$RS_ONLINE" 2>/dev/null || true) ;;
    esac
  done
  [ "$final_live" = 1 ] || rs_flush                    # tail life: synth unless it's the live one
}

# ---- build the canonical timeline from PAST lives ---------------------------------
canon=$(mktemp); topost=$(mktemp)
trap 'rm -f "$canon" "$topost"' EXIT
# 1) archived logs (each holds ≥1 whole, already-ended lives → synth their tails too)
lives=0
for f in $(ls -1 "$LOGDIR"/bedrock_*.log 2>/dev/null | sort); do
  lives=$((lives + 1))
  replay_stream 0 < "$f" >> "$canon"
done
# 2) the CURRENT container's log: earlier lives (before a `just restart`) are past and
#    get synth'd; the final, running life is the live watcher's domain → skipped.
running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)
[ "$running" = true ] && docker logs "$CONTAINER" 2>&1 | replay_stream 1 >> "$canon"

echo "reconcile: $lives archived log file(s) in $LOGDIR · ledger=$LEDGER_FILE · max-age=${MAX_AGE_H}h · $([ "$FIRST_RUN" = 1 ] && echo 'FIRST-RUN (seed history, heal phantoms)' || echo 'steady-state')$([ "$DRY" = 1 ] && echo ' · DRY-RUN')"

# ---- decide per event: post / record-silently ------------------------------------
# REAL connect/disconnect events were already announced live by scripts/notify.sh, so we
# NEVER re-post them (that's what flooded the channel when the event-key format changed) —
# we only record them in the ledger to keep the timeline complete. The one thing worth
# healing is a recent SYNTHETIC leave (a phantom: someone still "connected" when a past
# life ended, which never logged a real disconnect). A first run just seeds the baseline.
seeded=0; skipped_old=0; queued=0
while IFS=$'\t' read -r ts ev pl kind; do
  [ -z "${ts:-}" ] && continue
  ledger_has "$ts" "$ev" "$pl" && continue            # already delivered/recorded
  e_s=$(ts_to_epoch "$ts"); [ "$e_s" = 0 ] && e_s=$now_s
  recent=0; [ "$e_s" -ge "$min_s" ] && recent=1
  if [ "$kind" = synth ] && [ "$recent" = 1 ] && [ "$FIRST_RUN" = 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$ts" "$ev" "$pl" "$kind" >> "$topost"; queued=$((queued + 1))
  else
    [ "$DRY" = 1 ] || ledger_add "$ts" "$ev" "$pl"     # record silently, never post
    if [ "$recent" = 0 ]; then skipped_old=$((skipped_old + 1)); else seeded=$((seeded + 1)); fi
  fi
done < <(sort "$canon")

# ---- post the queued phantom-heals, with a HARD CAP so a desync can never flood -----
posted=0; collapsed=0
wait_for_bridge() {  # the ntfy→Discord bridge only forwards live messages; let it subscribe
  [ "$DRY" = 1 ] && return
  local i=0; while [ $i -lt 15 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' mc-bridge 2>/dev/null)" = true ] && break
    i=$((i + 1)); sleep 1
  done
  sleep "$PUBLISH_DELAY"
}
if [ -s "$topost" ]; then
  qn=$(wc -l < "$topost" | tr -d ' ')
  if [ "$qn" -gt "$MAX_POST" ]; then
    # More "phantoms" than any real downtime should produce → the ledger is out of sync
    # (not a handful of genuine heals). Record them all silently and post ONE summary
    # instead of spamming the channel — this is the anti-flood backstop.
    collapsed="$qn"
    if [ "$DRY" = 1 ]; then
      echo "  [dry] would COLLAPSE ${qn} events (> cap ${MAX_POST}) into a single summary"
    else
      while IFS=$'\t' read -r ts ev pl kind; do ledger_add "$ts" "$ev" "$pl"; done < "$topost"
      wait_for_bridge
      publish_bus "🔄 quietly reconciled ${qn} past player events (ledger was out of date — not re-posting them all)" default "player,arrows_counterclockwise"
    fi
  else
    wait_for_bridge
    while IFS=$'\t' read -r ts ev pl kind; do
      msg="⏪ ${pl} ${ev} $(fmt_when "$ts") — session ended when the server went down"
      if [ "$DRY" = 1 ]; then
        echo "  [dry] would post: $msg"
      else
        publish_bus "$msg" default "player,rewind"
        ledger_add "$ts" "$ev" "$pl"
      fi
      posted=$((posted + 1))
    done < "$topost"
  fi
fi

# ---- sanity line: what the server itself says is online right now ------------------
live="(server not reachable)"
if docker exec "$CONTAINER" send-command "list" >/dev/null 2>&1; then
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  for _ in $(seq 1 10); do
    blk=$(docker logs --since "$since" "$CONTAINER" 2>&1 | grep -iA1 "players online" | tail -2)
    [ -n "$blk" ] && { live=$(printf '%s' "$blk" | sed -nE 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#p'); break; }
    sleep 0.1
  done
fi

# mark the ledger initialised so the next run is steady-state (real misses get posted too)
[ "$DRY" = 1 ] || { [ "$FIRST_RUN" = 1 ] && : > "$INIT_MARK"; }

if [ "$DRY" = 1 ]; then
  echo "reconcile (dry): would post ${queued} phantom-heal(s)$([ "${queued}" -gt "${MAX_POST}" ] && echo " → COLLAPSED to 1 summary (cap ${MAX_POST})"), record ${seeded} recent + ${skipped_old} old silently · server reports ${live} online"
elif [ "$collapsed" != 0 ]; then
  echo "reconcile: ledger was out of date — quietly recorded ${collapsed} past events + posted 1 summary · server reports ${live} online"
else
  echo "reconcile: backfilled ${posted} phantom-heal(s)$([ "$FIRST_RUN" = 1 ] && echo ", seeded ${seeded} historical baseline (silent)")$([ "$skipped_old" -gt 0 ] && echo ", recorded ${skipped_old} old silently") · server reports ${live} online"
fi
