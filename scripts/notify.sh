#!/usr/bin/env bash
# Host-side watcher: push player connect/disconnect events to your phone via ntfy.sh
# (the default), and OPTIONALLY raise a macOS desktop notification too (opt-in).
#
# The two outputs are fully independent:
#   • iPhone / ntfy push   — ON whenever NTFY_TOPIC is set (the default).
#   • macOS desktop alert  — OPT-IN, OFF by default. Enable with NOTIFY_MACOS=1.
#
# Runs on the Mac host (the macOS alert uses osascript/terminal-notifier; the ntfy push
# would work anywhere). Ctrl-C to stop.
#
#   ./scripts/notify.sh                  # watch join/leave → ntfy push (if NTFY_TOPIC set)
#   NOTIFY_MACOS=1 ./scripts/notify.sh   # ALSO raise macOS desktop notifications
#   NOTIFY_TEST=1 ./scripts/notify.sh    # also fire on the `list` "players online" line,
#                                          so you can test without logging in
#
# Set NTFY_TOPIC (and optionally NOTIFY_MACOS=1) once in the project .env to persist.
set -uo pipefail

CONTAINER="${CONTAINER:-bedrock}"
TITLE="Minecraft (${CONTAINER})"

# Pick up NTFY_TOPIC from .env if not already in the environment.
if [ -z "${NTFY_TOPIC:-}" ] && [ -f .env ]; then
  NTFY_TOPIC=$(grep -E '^NTFY_TOPIC=' .env 2>/dev/null | cut -d= -f2- || true)
fi
# macOS desktop notifications are OPT-IN (default off). Pick up NOTIFY_MACOS from .env too.
if [ -z "${NOTIFY_MACOS:-}" ] && [ -f .env ]; then
  NOTIFY_MACOS=$(grep -E '^NOTIFY_MACOS=' .env 2>/dev/null | cut -d= -f2- || true)
fi
NOTIFY_MACOS="${NOTIFY_MACOS:-0}"

# Delivery ledger (outbox): record every player event we actually post, so the
# startup reconciler (scripts/reconcile.sh) can tell what was delivered vs. missed
# and backfill only the gaps. One line per event: "<ts>|<connected|disconnected>|<player>".
LEDGER_FILE="${LEDGER_FILE:-bedrock-data/monitoring/posted-events.log}"
ledger_add() {  # ledger_add <ts> <event> <player>
  [ -n "$1" ] || return 0
  mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || return 0
  local key="$1|$2|$3"
  grep -qxF "$key" "$LEDGER_FILE" 2>/dev/null || printf '%s\n' "$key" >> "$LEDGER_FILE"
}
# pull the "YYYY-MM-DD HH:MM:SS" stamp off a bedrock log line (drops the :mmm millis)
ts_of() { printf '%s' "$1" | sed -nE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}):[0-9]+ INFO\].*/\1/p'; }

# macOS desktop notification — OPT-IN (NOTIFY_MACOS=1), no-op otherwise. Prefer
# terminal-notifier (shows reliably on Sequoia); fall back to osascript (posts as
# "Script Editor", often suppressed).
notify_macos() {  # notify_macos <message> <sound>
  [ "${NOTIFY_MACOS:-0}" = "1" ] || return 0
  local msg="$1" sound="${2:-Ping}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$TITLE" -message "$msg" -sound "$sound" -group minecraft-notify >/dev/null 2>&1
  else
    local safe=${msg//\\/\\\\}; safe=${safe//\"/\\\"}
    osascript -e "display notification \"$safe\" with title \"$TITLE\" sound name \"$sound\"" >/dev/null 2>&1
  fi
}

# iPhone / anywhere via ntfy.sh — ON whenever NTFY_TOPIC is set (the default), no-op otherwise.
push_ntfy() {  # push_ntfy <message> <tags>
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  local msg="$1" tags="${2:-bell}"
  curl -fsS -H "Title: $TITLE" -H "Tags: $tags" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 \
    || echo "   (ntfy push failed — check network / topic name)"
}

# Announce an event through whichever channels are enabled. The two halves are fully
# independent: ntfy push (default on) and the macOS desktop alert (opt-in) never gate
# each other — disabling one leaves the other working.
notify() {  # notify <message> <macSound> <ntfyTags>
  push_ntfy "$1" "${3:-bell}"
  notify_macos "$1" "${2:-Ping}"
  echo "→ notified: $1"
}

online_count() {  # online_count [name] [want_present:1|0] -> echo "X/Y", or "" on failure
  # Poll `list` until the count actually reflects the event we're reporting: a just-
  # connected player isn't in `list` for ~0.5-0.7s after "Player connected", so a fixed
  # sleep races and under/over-counts by one. We re-issue `list` and wait until <name>
  # is present (join) / absent (leave) before trusting the count. With no name (test
  # mode) we just return the first count we see.
  local who="${1:-}" want="${2:-}" since block cnt names here tries
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  for tries in 1 2 3 4; do
    docker exec "$CONTAINER" send-command "list" >/dev/null 2>&1 || { echo ""; return; }
    for _ in $(seq 1 8); do                     # poll this list's output for ~0.8s
      sleep 0.1
      # latest "players online:" block = its count line + the names line beneath it
      block=$(docker logs --since "$since" "$CONTAINER" 2>&1 | grep -iA1 "players online" | tail -2)
      cnt=$(printf '%s' "$block" | sed -nE 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#p')
      [ -z "$cnt" ] && continue
      [ -z "$who" ] && { printf '%s' "$cnt"; return; }     # test mode: first count wins
      names=$(printf '%s' "$block" | sed -n '2p')
      if printf '%s' "$names" | grep -qiwF -- "$who"; then here=1; else here=0; fi
      [ "$here" = "$want" ] && { printf '%s' "$cnt"; return; }   # list now reflects event
    done
  done
  # Never confirmed the list reflects this event (server lagging, crashing, or down) —
  # the count we have is stale/contradictory (e.g. "0/10" right after a join). Return
  # nothing so the caller posts the event WITHOUT a misleading count.
  printf ''
}

# --- in-game host commands -----------------------------------------------------------
# The chat-bridge pack can't run host actions in its sandbox, so it prints "CHATCMD <name>
# <args>" to the server log; we pick those up below and run them (backup/doctor/mail),
# replying in-game via tellraw. Also delivers queued mail on join.
JUST=$(command -v just 2>/dev/null || echo /opt/homebrew/bin/just)
MAILDIR="bedrock-data/mailbox"

cmd_say() {  # show one line in-game to everyone via tellraw (escape " and \ for JSON safety)
  local t=$1; t=${t//\\/\\\\}; t=${t//\"/\\\"}
  docker exec "$CONTAINER" send-command "tellraw @a {\"rawtext\":[{\"text\":\"$t\"}]}" >/dev/null 2>&1
}

mail_store() {  # mail_store <from> <to> <message>
  local key; key=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$key" ] || return 1
  mkdir -p "$MAILDIR" || return 1
  printf '%s\t%s\n' "$1" "$3" >> "$MAILDIR/$key.txt"
}

deliver_mail() {  # deliver_mail <recipient gamertag> — flush + clear their pending mail on join
  local key box from msg
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'); box="$MAILDIR/$key.txt"
  [ -f "$box" ] || return 0
  while IFS=$(printf '\t') read -r from msg; do
    [ -n "$msg" ] || continue
    cmd_say "§d[Mail]§r $1, from ${from}: ${msg}"
  done < "$box"
  /bin/rm -f "$box"
}

handle_chatcmd() {  # handle_chatcmd "<name> <args...>" — caller backgrounds this
  local rest=$1 name args
  name=${rest%% *}; args=${rest#"$name"}; args=${args# }
  case "$name" in
    backup)
      local who res; who=$(printf '%s' "$args" | tr -d '"\\')
      res=$("$JUST" _backup-request "game:${who:-player}" 2>/dev/null); set -- $res
      case "${1:-ERR}" in
        OK)        cmd_say "§a[Backup]§r ${who}'s snapshot saved ✓ (${3:-?})" ;;
        RATELIMIT) cmd_say "§e[Backup]§r ${who}, slow down — retry in $(( ${2:-0} / 60 ))m $(( ${2:-0} % 60 ))s" ;;
        BUSY)      cmd_say "§e[Backup]§r a backup is already running — try shortly" ;;
        *)         cmd_say "§c[Backup]§r failed — please tell an admin" ;;
      esac ;;
    doctor)
      local sum; sum=$("$JUST" doctor --brief 2>/dev/null | tail -1)
      cmd_say "§b[Doctor]§r ${sum:-no output}" ;;
    map)
      local who res; who=$(printf '%s' "$args" | tr -d '"\\')
      res=$("$JUST" _map-request "game:${who:-player}" 2>/dev/null); set -- $res
      case "${1:-ERR}" in
        OK)        cmd_say "§a[Map]§r posted a fresh survey to #map 🗺" ;;
        RATELIMIT) cmd_say "§e[Map]§r a map was just made — retry in $(( ${2:-0} / 60 ))m $(( ${2:-0} % 60 ))s" ;;
        BUSY)      cmd_say "§e[Map]§r a map is already rendering — hang tight" ;;
        *)         cmd_say "§c[Map]§r render failed — please tell an admin" ;;
      esac ;;
    mail)
      local from to msg
      from=$(printf '%s' "$args" | awk -F'|' '{print $1}')
      to=$(printf '%s' "$args"   | awk -F'|' '{print $2}')
      msg=$(printf '%s' "$args"  | cut -s -d'|' -f3-)
      if mail_store "$from" "$to" "$msg"; then cmd_say "§d[Mail]§r queued for ${to} ✉"; else cmd_say "§c[Mail]§r couldn't queue"; fi ;;
    *) cmd_say "§c[cmd]§r unknown host command: ${name}" ;;
  esac
}

echo "🔔 watching '$CONTAINER' for player connect/disconnect (Ctrl-C to stop)…"
if [ -n "${NTFY_TOPIC:-}" ]; then echo "   iPhone push: ON  (ntfy topic '$NTFY_TOPIC')"; else echo "   iPhone push: off (set NTFY_TOPIC to enable)"; fi
if [ "${NOTIFY_MACOS:-0}" = "1" ]; then echo "   macOS desktop alerts: ON"; else echo "   macOS desktop alerts: off (opt-in — set NOTIFY_MACOS=1)"; fi
[ "${NOTIFY_TEST:-0}" = "1" ] && echo "   TEST mode: will also fire on the 'players online' list line"

# --tail 0 => only NEW log lines (no replay of history), then follow.
docker logs -f --tail 0 "$CONTAINER" 2>&1 | while IFS= read -r line; do
  case "$line" in
    *"Starting Server"*)
      # A stop/restart kills sessions WITHOUT logging "Player disconnected", so the
      # post-restart re-joins would otherwise look like impossible double-joins with no
      # "left" between them. Note it locally (for the log timeline) but DON'T push it —
      # it reached Discord/phone on every (re)start and was just noise.
      echo "→ server (re)started — players will reconnect (not pushed)" ;;
    *"Player connected:"*)
      # A connection ATTEMPT — the player has NOT entered the world yet, and may never
      # (a crash can hit between here and "Player Spawned"). Announce a tentative status;
      # the confirmed join is posted on Player Spawned below. No count yet (list won't
      # reflect them), and nothing recorded to the ledger (this isn't a real session).
      name=$(printf '%s' "$line" | sed -E 's/.*Player connected: ([^,]+),.*/\1/')
      notify "⏳ ${name} connecting…" "Funk" "player,hourglass_flowing_sand" ;;
    *"Player Spawned:"*)
      # The player has actually entered the world — THIS is the real join (fires once per
      # session, not on respawns). By now `list` reflects them, so the count is accurate.
      name=$(printf '%s' "$line" | sed -E 's/.*Player Spawned: (.+) xuid:.*/\1/')
      cnt=$(online_count "$name" 1); msg="✅ ${name} joined"; [ -n "$cnt" ] && msg="${msg} — ${cnt} online"
      notify "$msg" "Glass" "player,white_check_mark,video_game"
      ledger_add "$(ts_of "$line")" joined "$name"
      deliver_mail "$name"
      # learn this player's gamertag→ServerId mapping for offline /coords. Backgrounded so the
      # querytarget round-trip never stalls the log tail; cheap (no world-db read — that hop is
      # done lazily at lookup). Self-maintaining: the map fills in as people play.
      ( python3 scripts/capture_player_map.py "$name" ) & ;;
    *"Player disconnected:"*)
      name=$(printf '%s' "$line" | sed -E 's/.*Player disconnected: ([^,]+),.*/\1/')
      cnt=$(online_count "$name" 0); msg="👋 ${name} left"; [ -n "$cnt" ] && msg="${msg} — ${cnt} online"
      notify "$msg" "Submarine" "player,wave,video_game"
      ledger_add "$(ts_of "$line")" left "$name" ;;
    *"CHATCMD "*)
      # in-game command needing host privileges (emitted by the chat-bridge pack). Background
      # it so a 10–30s backup never stalls the log tail (and with it join/leave notifications).
      rest=${line#*CHATCMD }
      ( handle_chatcmd "$rest" ) & ;;
    *"players online:"*)
      if [ "${NOTIFY_TEST:-0}" = "1" ]; then
        count=$(printf '%s' "$line" | sed -E 's#.*There are ([0-9]+/[0-9]+) players online.*#\1#')
        notify "🔔 TEST OK — server reports ${count} players online" "Ping" "bell,test_tube"
      fi ;;
  esac
done
