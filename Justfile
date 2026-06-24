# Minecraft Bedrock server — task runner.
# Install just:  brew install just      List recipes:  just   (or just --list)

set shell := ["bash", "-uc"]
set dotenv-load          # load .env so LEVEL_NAME (and other config) reach the recipes

# the active world folder name (under bedrock-data/worlds/) — set LEVEL_NAME in .env
world := env_var_or_default("LEVEL_NAME", "world")

# flag file marking an INTENTIONAL (manual) stop. `maintenance-down` writes it; the
# next start (up/restart/recreate/maintenance-up) sees it, announces the return to
# Discord (prompting for a message), and clears it. (bedrock-data/ is gitignored.)
maint_flag := "bedrock-data/.maintenance"

# show all recipes
default:
    @just --list

# ───────────────────────── server lifecycle ─────────────────────────

# start the stack (server + tunnel) — guarded: blocks if a player is online (config changes can recreate)
up:
    @./scripts/guard.sh "start/refresh the stack (just up — may recreate changed containers)" players-only
    @echo "starting stack ..."
    docker compose up -d
    @just _on-start    # if returning from a manual stop, announce the return to Discord

# stop & remove the stack (guarded; archives logs first — `down` destroys the container's logs)
down:
    @./scripts/guard.sh "stop & remove the stack (just down)"
    @echo "stopping and removing stack ..."
    @just _archive-logs
    docker compose down

# restart just the bedrock server (guarded; reuses container, so logs are kept).
# Always prompts for a #server-status message (Enter = default); pass one inline to skip: just restart "Quick bounce"
restart MSG="":
    @./scripts/guard.sh "restart the bedrock server (just restart)"
    @echo "restarting bedrock server ..."
    docker compose restart bedrock
    @just _on-start "{{MSG}}" force    # always announce the return to Discord (prompts for a message)

# recreate containers (guarded; needed after editing docker-compose.yml; archives logs first)
recreate:
    @./scripts/guard.sh "recreate containers (just recreate)"
    @echo "recreating containers ..."
    @just _archive-logs
    docker compose up -d --force-recreate
    @just _on-start    # if returning from a manual stop, announce the return to Discord

# internal: snapshot the CURRENT container logs to bedrock-data/logs/ before they're lost
_archive-logs:
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p bedrock-data/logs
    TS=$(date +%Y%m%d-%H%M%S)
    for svc in bedrock playit; do
      out="bedrock-data/logs/${svc}_${TS}.log"
      if docker logs "$svc" > "$out" 2>&1; then
        echo "📝 archived $svc → $out ($(wc -l < "$out" | tr -d ' ') lines, $(du -h "$out" | cut -f1))"
      else
        /bin/rm -f "$out"   # container didn't exist — drop the empty file
      fi
    done

# list archived log snapshots (newest first)
archived:
    @echo "checking archived logs ..."
    @ls -1t bedrock-data/logs/ 2>/dev/null || echo "no archives yet — created on next: just down / just recreate"

# follow all logs
logs:
    @echo "checking all logs ..."
    docker compose logs -f

# follow server logs only
blogs:
    @echo "checking bedrock logs ..."
    docker compose logs -f bedrock

# follow tunnel logs only
plogs:
    @echo "checking playit logs ..."
    docker compose logs -f playit

# container status
status:
    @echo "checking container status ..."
    docker compose ps

# who's online
players:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "checking for players ..."
    since=$(date -u +%Y-%m-%dT%H:%M:%S)
    docker exec bedrock send-command "list" >/dev/null 2>&1 || { echo "no response — is the server up? try: just status"; exit 1; }
    # poll the log; return the instant the reply lands, give up after ~0.5s
    for i in $(seq 1 10); do
      out=$(docker logs --since "$since" bedrock 2>&1 | grep -iA1 "players online" | tail -2)
      [ -n "$out" ] && { echo "$out"; exit 0; }
      sleep 0.05
    done
    echo "timed out (~0.5s) — server slow or down? try: just status"

# run any server console command, e.g. `just cmd "gamerule showcoordinates true"`
cmd +CMD:
    @echo "running cmd: {{CMD}} ..."
    docker exec bedrock send-command "{{CMD}}"

# print the public playit tunnel address
tunnel:
    @echo "printing tunnel address ..."
    @docker compose logs playit 2>&1 | grep -oiE "[a-z0-9.-]+\.(ply\.gg|playit\.gg)(:[0-9]+)?" | tail -1 || echo "not found — try: just plogs"

# crash check for this container-life
crashes:
    @echo "checking for crashes ..."
    @echo "free() crashes since boot: $(docker logs bedrock 2>&1 | grep -c 'free(): invalid next size')"

# ───────────────────────── notifications ────────────────────────────

# macOS (+ optional iPhone via ntfy) notification on player join/leave — host, Ctrl-C to stop
notify:
    @echo "running notify ..."
    @./scripts/notify.sh

# test notifications WITHOUT logging in: starts the watcher, triggers the `list` line, waits
notify-test:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "running notify-test ... (a notification should appear within ~3s)"
    NOTIFY_TEST=1 ./scripts/notify.sh & WPID=$!
    sleep 1
    docker exec bedrock send-command "list" >/dev/null 2>&1 || echo "server not up? try: just status"
    sleep 2
    kill "$WPID" 2>/dev/null || true
    pkill -f "docker logs -f --tail 0 bedrock" 2>/dev/null || true
    echo "✅ notify-test done — did the notification appear?"

# PERMANENTLY run the watcher in the background (launchd; starts at login, auto-restarts)
notify-install:
    @echo "installing notify agent ..."
    @./scripts/notify-agent.sh install

# stop & remove the permanent background watcher
notify-uninstall:
    @echo "removing notify agent ..."
    @./scripts/notify-agent.sh uninstall

# is the permanent background watcher running?
notify-running:
    @echo "checking notify agent ..."
    @./scripts/notify-agent.sh status

# ───────────────────────── backup / restore ─────────────────────────

# full consistent snapshot of the ENTIRE world (no player disconnect)
backup:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "running backup ..."
    WORLD="bedrock-data/worlds/{{world}}"
    [ -d "$WORLD" ] || { echo "world not found: $WORLD"; exit 1; }
    TS=$(date +%Y%m%d-%H%M%S)
    BK="bedrock-data/backups/{{world}}_$TS"
    mkdir -p bedrock-data/backups
    echo "→ flushing world to disk + holding writes…"
    docker exec bedrock send-command "save hold" >/dev/null 2>&1 || { echo "server not running — start it with: just up"; exit 1; }
    sleep 2
    for i in $(seq 1 30); do
      docker exec bedrock send-command "save query" >/dev/null 2>&1
      sleep 1
      docker logs --since 50s bedrock 2>&1 | grep -q "ready to be copied" && break
    done
    cp -a "$WORLD" "$BK"
    docker exec bedrock send-command "save resume" >/dev/null 2>&1
    SIZE=$(du -sh "$BK" | cut -f1)
    DBCOUNT=$(ls "$BK/db" | wc -l | tr -d ' ')
    echo "✅ backup: $BK  ($SIZE, $DBCOUNT db files)"
    # → announce to #backups (Discord). Non-fatal: a webhook hiccup must never fail the backup.
    if [ -n "${DISCORD_WEBHOOK_BACKUP:-}" ]; then
      MSG="🗄️ A fresh world-snapshot has been pressed into stone — \`$(basename "$BK")\` · ${SIZE} · ${DBCOUNT} db files. Should the goblins meet ruin, this is the realm they wake to. 🐐"
      safe=$(printf '%s' "$MSG" | sed 's/"/\\"/g')
      curl -fsS -H "Content-Type: application/json" \
        -d "{\"content\":\"${safe}\"}" "$DISCORD_WEBHOOK_BACKUP" >/dev/null 2>&1 \
        && echo "→ posted to #backups" || echo "   (Discord post failed — backup still OK)"
    else
      echo "   (DISCORD_WEBHOOK_BACKUP unset — skipped #backups post)"
    fi

# list backups (newest first)
backups:
    @echo "running backups..."
    @ls -1t bedrock-data/backups/ 2>/dev/null || echo "no backups yet — run: just backup"

# restore a backup by folder name (stops server; keeps current world as *.pre-restore-*)
restore NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "running restore {{NAME}}..."
    SRC="bedrock-data/backups/{{NAME}}"
    [ -d "$SRC" ] || { echo "no such backup: $SRC"; echo "available:"; ls -1 bedrock-data/backups; exit 1; }
    WORLD="bedrock-data/worlds/{{world}}"
    docker compose stop bedrock
    [ -d "$WORLD" ] && mv "$WORLD" "${WORLD}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    cp -a "$SRC" "$WORLD"
    docker compose start bedrock
    echo "✅ restored {{NAME}} (previous world kept alongside as *.pre-restore-*)"

# interactively prune OLD backups (manual only). Lists all backups oldest→newest, lets you
# delete up to 3 of the OLDEST per run, and NEVER the 3 newest. Posts a summary to #backups.
backup-clean:
    #!/usr/bin/env bash
    set -uo pipefail
    DIR="bedrock-data/backups"
    [ -d "$DIR" ] || { echo "no backups dir yet ($DIR) — run: just backup"; exit 0; }
    # backups are named {{world}}_YYYYMMDD-HHMMSS, so a lexical sort = chronological (oldest→newest)
    N=$(ls -1 "$DIR" 2>/dev/null | wc -l | tr -d ' '); N=${N:-0}
    if [ "$N" -eq 0 ]; then echo "no backups found in $DIR"; exit 0; fi
    # eligible this run = everything except the newest 3, capped at 3
    MAX=$((N - 3)); [ "$MAX" -lt 0 ] && MAX=0; [ "$MAX" -gt 3 ] && MAX=3
    echo "📦 $N backup(s) in $DIR (oldest → newest):"
    i=0
    while IFS= read -r name; do
      i=$((i + 1))
      size=$(du -sh "$DIR/$name" 2>/dev/null | cut -f1)
      if   [ "$i" -gt $((N - 3)) ]; then tag="🔒 newest 3 — always kept"
      elif [ "$i" -le "$MAX" ];     then tag="🗑️  oldest — eligible now"
      else                                tag="·  kept (eligible a later run)"; fi
      printf "  %2d. %-40s %7s  %s\n" "$i" "$name" "${size:-?}" "$tag"
    done < <(ls -1 "$DIR" | sort)
    echo
    if [ "$MAX" -eq 0 ]; then echo "Nothing to delete — the 3 newest backups are always protected (you have $N)."; exit 0; fi
    if [ ! -t 0 ]; then echo "refusing to delete without an interactive terminal."; exit 1; fi
    printf "How many of the OLDEST backups to delete? (0–%s, Enter = 0): " "$MAX"
    read -r CNT; CNT=${CNT:-0}
    case "$CNT" in (*[!0-9]*) echo "not a number — nothing deleted."; exit 1;; esac
    if [ "$CNT" -gt "$MAX" ]; then echo "max is $MAX per run — nothing deleted."; exit 1; fi
    if [ "$CNT" -eq 0 ]; then echo "0 selected — nothing deleted."; exit 0; fi
    echo "About to delete these $CNT oldest backup(s):"
    ls -1 "$DIR" | sort | head -n "$CNT" | sed 's/^/  - /'
    printf "Type 'delete' to confirm (anything else aborts): "
    read -r CONF
    [ "$CONF" = "delete" ] || { echo "aborted — nothing deleted."; exit 1; }
    DELETED=0
    while IFS= read -r name; do
      if /bin/rm -rf "$DIR/$name"; then echo "🗑️  deleted $name"; DELETED=$((DELETED + 1)); fi
    done < <(ls -1 "$DIR" | sort | head -n "$CNT")
    REMAIN=$(ls -1 "$DIR" 2>/dev/null | wc -l | tr -d ' '); REMAIN=${REMAIN:-0}
    echo "✅ deleted $DELETED backup(s); $REMAIN remain."
    # → announce to #backups (Discord). Non-fatal: a webhook hiccup must never fail the cleanup.
    if [ -n "${DISCORD_WEBHOOK_BACKUP:-}" ]; then
      MSG="🧹 Backup cleanup: swept away ${DELETED} of the realm's oldest snapshot(s) — ${REMAIN} still stand watch in the vault. 🐐"
      safe=$(printf '%s' "$MSG" | sed 's/"/\\"/g')
      curl -fsS -H "Content-Type: application/json" \
        -d "{\"content\":\"${safe}\"}" "$DISCORD_WEBHOOK_BACKUP" >/dev/null 2>&1 \
        && echo "→ posted to #backups" || echo "   (Discord post failed — cleanup still done)"
    else
      echo "   (DISCORD_WEBHOOK_BACKUP unset — skipped #backups post)"
    fi

# ───────────────────────── monitoring / analytics ───────────────────

# run the live monitor on the host (Ctrl-C to stop) — writes bedrock-data/monitoring/*.csv
monitor INTERVAL="30":
    @echo "running monitor interval={{INTERVAL}}s ..."
    ./scripts/monitor.sh {{INTERVAL}}

# start ONLY the observability stack (monitor + bus→Discord bridge), e.g. after a
# monitor-down. `just up` already brings these up too; --no-deps so it NEVER touches bedrock.
monitor-up:
    @echo "starting monitor + bridge containers ..."
    docker compose up -d --no-deps monitor bridge

# stop ONLY the observability stack (leaves the game server running)
monitor-down:
    @echo "stopping monitor + bridge containers ..."
    docker compose stop monitor bridge

# follow the bus→Discord bridge log (shows every event flowing through ntfy)
bridge-logs:
    @echo "checking bridge logs ..."
    docker compose logs -f bridge

# publish a digest now (peak players, joins/leaves, crashes) → #monitoring + phone
digest-now:
    @echo "publishing digest ..."
    @./scripts/digest.sh

# post the uptime graph now → #monitoring (4 panels: status/players/CPU/RAM, London time).
# WINDOW: empty=last 24h · yesterday · today · Nh (e.g. 12h) · YYYY-MM-DD. Status is from
# healthchecks.io (matches #server-status); detail panels from the local health.csv.
uptime WINDOW="":
    @./scripts/uptime.sh {{WINDOW}}

# render the uptime graph locally WITHOUT posting to Discord (prints path + summary)
uptime-preview WINDOW="":
    @./scripts/uptime.sh --no-post {{WINDOW}}

# schedule the daily uptime post (previous London day) at 00:05 → #monitoring (launchd)
uptime-install:
    @echo "installing uptime agent ..."
    @./scripts/uptime-agent.sh install

# stop & remove the daily uptime post
uptime-uninstall:
    @echo "removing uptime agent ..."
    @./scripts/uptime-agent.sh uninstall

# is the daily uptime post scheduled?
uptime-running:
    @echo "checking uptime agent ..."
    @./scripts/uptime-agent.sh status

# forensic summary of the CURRENT session logs (relogs, timeline, tunnel events)
analyze:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "running analyze..."
    echo "== gamertag -> XUID (this session) =="
    docker logs bedrock 2>&1 | grep "Player connected" | sed -E 's/.*connected: ([^,]+), xuid: ([0-9]+).*/\2  \1/' | sort -u
    echo; echo "== relogs per player (connects beyond the 1st ≈ desyncs) =="
    docker logs bedrock 2>&1 | grep "Player connected" | sed -E 's/.*connected: ([^,]+),.*/\1/' | sort | uniq -c | sort -rn
    echo; echo "== connect/disconnect timeline =="
    docker logs bedrock 2>&1 | grep -E "Player (connected|disconnected)" | sed -E 's/\[([0-9: -]+):[0-9]{3} INFO\] Player (connected|disconnected): ([^,]+).*/\1  \2  \3/'
    echo; echo "== playit anomalies (session-expired / ERROR) =="
    docker logs playit 2>&1 | grep -iE "session expired|ERROR" | sed -E 's/\.[0-9]+Z//' | tail -10
    echo; echo "== free() crashes: $(docker logs bedrock 2>&1 | grep -c 'free(): invalid next size') =="

# ───────────────────────── maintenance (planned downtime) ───────────
# Take the stack down for planned maintenance WITHOUT tripping alerts:
# announce to #server-status, pause healthchecks.io, silence the monitor, then stop.
# Optional custom message:  just maintenance-down "Laptop off for a few hours"

# announce + stop the stack (guarded). hc.io is NOT paused — the downtime is left to
# show truthfully on the check (and in #server-status via its integration).
maintenance-down MSG="":
    #!/usr/bin/env bash
    set -uo pipefail
    ./scripts/guard.sh "maintenance shutdown (just maintenance-down)" || exit 1
    MSG="{{MSG}}"
    [ -z "$MSG" ] && MSG="🛠️ Server going down for planned maintenance — back soon. 🐐"
    echo "→ announcing maintenance to #server-status ..."
    ( . scripts/notify-lib.sh; publish_bus "$MSG" default "alert,wrench,construction" ) || true
    # stop monitor+bridge FIRST so they don't double-publish their own DOWN alert
    # (hc.io still goes down on its own once pings stop — that's the truthful signal we want)
    echo "→ stopping monitor + bridge ..."
    docker compose stop monitor bridge 2>/dev/null || true
    # then stop the server + tunnel (kept, not removed — logs & state survive for a quick resume)
    echo "→ stopping bedrock + playit ..."
    docker compose stop bedrock playit
    # mark this as an intentional stop so the NEXT start (any of up/restart/recreate/
    # maintenance-up) knows to announce the return to Discord and prompt for a message.
    mkdir -p "$(dirname "{{maint_flag}}")"
    printf 'down_at=%s\nmsg=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MSG" > "{{maint_flag}}"
    echo "✅ maintenance-down complete — stack stopped. hc.io will show DOWN shortly. Resume with ANY of: just up / restart / recreate / maintenance-up"

# bring everything back: start stack → wait ready → restart monitoring → resume + announce
# (announce/prompt is shared with up/restart/recreate via _on-start; `force` = always announce)
maintenance-up MSG="":
    #!/usr/bin/env bash
    set -uo pipefail
    echo "→ starting stack (bedrock + playit + monitor + bridge) ..."
    docker compose up -d
    printf "→ waiting for the server to accept commands "
    ready=0
    for i in $(seq 1 30); do
      if docker exec bedrock send-command "list" >/dev/null 2>&1; then ready=1; echo " ready"; break; fi
      printf "."; sleep 2
    done
    [ "$ready" -eq 1 ] || echo " (timed out after ~60s — continuing anyway; check: just status)"
    just _on-start "{{MSG}}" force
    echo "✅ maintenance-up complete — stack up, monitoring live."

# internal: shared "server is starting" hook. If we're returning from an intentional stop
# (maintenance-down left the flag) OR force is set, announce the return to Discord — using
# MSG, else prompting interactively (Enter = default), else the default — then clear the
# flag. Called by up/restart/recreate/maintenance-up. (hc.io is never paused, so no resume.)
_on-start MSG="" FORCE="":
    #!/usr/bin/env bash
    set -uo pipefail
    # nothing to announce unless we're coming back from a manual stop (flag) or forced
    if [ ! -f "{{maint_flag}}" ] && [ -z "{{FORCE}}" ]; then exit 0; fi
    MSG="{{MSG}}"
    if [ -z "$MSG" ] && [ -t 0 ]; then
      printf "💬 Discord message for #server-status to announce the server is back (Enter for default): "
      read -r MSG
    fi
    [ -z "$MSG" ] && MSG="✅ Server is back up. Reconnect and have fun! 🐐"
    echo "→ announcing return-to-service to #server-status ..."
    ( . scripts/notify-lib.sh; publish_bus "$MSG" default "alert,white_check_mark" ) || true
    rm -f "{{maint_flag}}"
    echo "→ cleared the maintenance flag."

# ───────────────────────── world / player data (read-only) ───────────

# generate player-profiles-report.md (inventory/armor/XP for every character)
report:
    @echo "generating player profiles report ..."
    @just _amulet scripts/profile_report.py > player-profiles-report.md && echo "✅ wrote player-profiles-report.md"

# print account -> profile mappings
accounts:
    @echo "checking account mappings ..."
    @just _amulet scripts/account_map.py

# full key audit of the world database
audit:
    @echo "running audit ..."
    @just _amulet scripts/audit_keys.py

# build the world-tools image once (amulet-leveldb compiled in; ~1-2 min, amd64)
tools-build:
    docker build --platform linux/amd64 -f scripts/tools.Dockerfile -t mc-tools scripts/

# internal: run a world-data python script against a copy of the live world db
_amulet SCRIPT:
    #!/usr/bin/env bash
    set -euo pipefail
    docker image inspect mc-tools >/dev/null 2>&1 || { echo "first run: building mc-tools image (one-time, ~1-2 min)…"; just tools-build; }
    echo "running _amulet {{SCRIPT}} against a copy of the live world db ..."
    /bin/rm -rf bedrock-data/_live_db
    cp -a "bedrock-data/worlds/{{world}}/db" bedrock-data/_live_db
    docker run --rm --platform linux/amd64 \
      -v "$PWD/bedrock-data/_live_db":/db \
      -v "$PWD/scripts":/scripts:ro \
      mc-tools python /scripts/$(basename {{SCRIPT}})

# remove temporary inspection copies (backups + scripts are kept)
clean:
    @echo "cleaning scratch dirs ..."
    @/bin/rm -rf bedrock-data/_live_db bedrock-data/_inspect_db && echo "cleaned scratch dirs"
