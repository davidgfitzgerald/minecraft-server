# Minecraft Bedrock server — task runner.
# Install just:  brew install just      List recipes:  just   (or just --list)

set shell := ["bash", "-uc"]
set dotenv-load          # load .env so LEVEL_NAME (and other config) reach the recipes

# the active world folder name (under bedrock-data/worlds/) — set LEVEL_NAME in .env
world := env_var_or_default("LEVEL_NAME", "world")

# show all recipes
default:
    @just --list

# ───────────────────────── server lifecycle ─────────────────────────

# start the stack (server + tunnel) — guarded: blocks if a player is online (config changes can recreate)
up:
    @./scripts/guard.sh "start/refresh the stack (just up — may recreate changed containers)" players-only
    @echo "starting stack ..."
    docker compose up -d

# stop & remove the stack (guarded; archives logs first — `down` destroys the container's logs)
down:
    @./scripts/guard.sh "stop & remove the stack (just down)"
    @echo "stopping and removing stack ..."
    @just _archive-logs
    docker compose down

# restart just the bedrock server (guarded; reuses container, so logs are kept)
restart:
    @./scripts/guard.sh "restart the bedrock server (just restart)"
    @echo "restarting bedrock server ..."
    docker compose restart bedrock

# recreate containers (guarded; needed after editing docker-compose.yml; archives logs first)
recreate:
    @./scripts/guard.sh "recreate containers (just recreate)"
    @echo "recreating containers ..."
    @just _archive-logs
    docker compose up -d --force-recreate

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
    echo "✅ backup: $BK  ($(du -sh "$BK" | cut -f1), $(ls "$BK/db" | wc -l | tr -d ' ') db files)"

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

# ───────────────────────── monitoring / analytics ───────────────────

# run the live monitor on the host (Ctrl-C to stop) — writes bedrock-data/monitoring/*.csv
monitor INTERVAL="30":
    @echo "running monitor interval={{INTERVAL}}s ..."
    ./scripts/monitor.sh {{INTERVAL}}

# start the observability stack (monitor + bus→Discord bridge). --no-deps so it NEVER touches bedrock
monitor-up:
    @echo "starting monitor + bridge containers ..."
    docker compose --profile monitor up -d --no-deps monitor bridge

# stop the observability stack
monitor-down:
    @echo "stopping monitor + bridge containers ..."
    docker compose --profile monitor stop monitor bridge

# follow the bus→Discord bridge log (shows every event flowing through ntfy)
bridge-logs:
    @echo "checking bridge logs ..."
    docker compose --profile monitor logs -f bridge

# publish a digest now (peak players, joins/leaves, crashes) → #monitoring + phone
digest-now:
    @echo "publishing digest ..."
    @./scripts/digest.sh

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
