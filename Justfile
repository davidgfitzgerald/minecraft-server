# Minecraft Bedrock server — task runner.
# Install just:  brew install just      List recipes:  just   (or just --list)

set shell := ["bash", "-uc"]
set dotenv-load          # load .env so LEVEL_NAME (and other config) reach the recipes

# the active world folder name (under bedrock-data/worlds/) — set LEVEL_NAME in .env
world := env_var_or_default("LEVEL_NAME", "world")

# flag file marking an INTENTIONAL (manual) stop. `down` writes it; the next start
# (up/restart/recreate) sees it, announces the return to Discord (prompting for a
# message), and clears it. (bedrock-data/ is gitignored.)
maint_flag := "bedrock-data/.maintenance"

# show all recipes
default:
    @just --list

# ───────────────────────── first-run setup ─────────────────────────

# interactive, idempotent setup wizard — guides you through .env and starting the
# services. Safe to re-run: it keeps whatever is already configured/running.
setup: _require-go
    @cd "{{justfile_directory()}}/tools/setup" && MC_ROOT="{{justfile_directory()}}" go run .

# preflight: the wizard is a small Go/Bubbletea TUI, so it needs Go. If Go is missing,
# print an OS-aware install hint and stop (just has no built-in `require`, so we do it here).
_require-go:
    #!/usr/bin/env bash
    set -uo pipefail
    command -v go >/dev/null 2>&1 && exit 0
    echo "❌ 'just setup' needs Go (the wizard is a small Bubbletea TUI) — not installed."
    case "$(uname -s)" in
      Darwin) echo "   → Install:  brew install go        (or download: https://go.dev/dl/)" ;;
      Linux)  echo "   → Install:  https://go.dev/dl/      (or e.g. sudo apt install golang)" ;;
      *)      echo "   → Install Go: https://go.dev/dl/" ;;
    esac
    echo "   Then re-run:  just setup"
    exit 1

# ───────────────────────── server lifecycle ─────────────────────────

# start the stack (server + tunnel) — guarded: blocks if a player is online (config changes can recreate).
# If returning from a `just down`, waits for readiness then announces the return to #server-status.
# Prompts for a message (Enter = default); pass one inline to skip:  just up "We're back!"
up MSG="":
    #!/usr/bin/env bash
    set -uo pipefail
    ./scripts/guard.sh "start/refresh the stack (just up — may recreate changed containers)" players-only || exit 1
    echo "starting stack ..."
    docker compose up -d
    # only when returning from an intentional stop: wait for the server to accept commands before announcing
    if [ -f "{{maint_flag}}" ]; then
      printf "→ waiting for the server to accept commands "
      for i in $(seq 1 30); do
        if docker exec bedrock send-command "list" >/dev/null 2>&1; then echo " ready"; break; fi
        printf "."; sleep 2
      done
    fi
    just _on-start "{{MSG}}"   # if returning from a manual stop, announce the return to Discord
    ./scripts/reconcile.sh || true   # backfill any join/leave that was missed while down (phantom-online fix)

# stop & remove the stack (guarded; archives logs first — `down` destroys the container's logs).
# Announces to #server-status and silences the monitor first so it doesn't fire its own DOWN alert
# (hc.io is NOT paused — downtime shows truthfully). Pass a message inline:  just down "Laptop off a while"
down MSG="":
    #!/usr/bin/env bash
    set -uo pipefail
    ./scripts/guard.sh "stop & remove the stack (just down)" || exit 1
    MSG="{{MSG}}"
    if [ -z "$MSG" ] && [ -t 0 ]; then
      printf "💬 Discord message for #server-status to announce the server is going down (Enter for default): "
      read -r MSG
    fi
    [ -z "$MSG" ] && MSG="Server going down — back soon."
    MSG="🛠️ ${MSG}"   # always flag #server-status DOWN announcements with the maintenance emoji
    echo "→ announcing to #server-status ..."
    ( . scripts/notify-lib.sh; publish_bus "$MSG" default "alert,wrench,construction" ) || true
    just _shutdown-countdown "going down" || true   # optional in-game countdown (SHUTDOWN_COUNTDOWN)
    # disconnect online players cleanly FIRST — while the watcher + bridge are still up —
    # so their "left" reaches #player-activity instead of leaving a phantom-online entry.
    ./scripts/graceful-kick.sh || true
    echo "stopping and removing stack ..."
    just _archive-logs
    # stop monitor+bridge FIRST so they don't publish their own DOWN alert as bedrock stops
    # (hc.io still goes down on its own once pings stop — that's the truthful signal we want)
    echo "→ stopping monitor + bridge ..."
    docker compose stop monitor bridge 2>/dev/null || true
    docker compose down
    # mark this as an intentional stop so the NEXT start (up/restart/recreate) announces the return
    mkdir -p "$(dirname "{{maint_flag}}")"
    printf 'down_at=%s\nmsg=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MSG" > "{{maint_flag}}"
    echo "✅ down complete — stack stopped & removed. hc.io will show DOWN shortly."

# restart just the bedrock server (guarded; reuses container, so logs are kept).
# Always prompts for a #server-status message (Enter = default); pass one inline to skip: just restart "Quick bounce"
restart MSG="":
    @./scripts/guard.sh "restart the bedrock server (just restart)"
    @just _shutdown-countdown "restarting" || true   # optional in-game countdown (SHUTDOWN_COUNTDOWN)
    @echo "restarting bedrock server ..."
    docker compose restart bedrock
    @just _on-start "{{MSG}}" force    # always announce the return to Discord (prompts for a message)
    @./scripts/reconcile.sh || true    # backfill any join/leave missed across the bounce

# recreate containers (guarded; needed after editing docker-compose.yml; archives logs first)
recreate:
    @./scripts/guard.sh "recreate containers (just recreate)"
    @just _shutdown-countdown "restarting" || true   # optional in-game countdown (SHUTDOWN_COUNTDOWN)
    @echo "recreating containers ..."
    @just _archive-logs
    docker compose up -d --force-recreate
    @just _on-start    # if returning from a manual stop, announce the return to Discord
    @./scripts/reconcile.sh || true    # backfill any join/leave missed across the recreate

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
        if [ "$svc" = bedrock ]; then
          # A crash in this now-archived container won't be in the live `docker logs` the
          # monitor reads after a recreate, so catch it here and alert #server-status
          # directly. The bridge is still running at this point (down/recreate stop it AFTER
          # _archive-logs), so the bus event is delivered.
          n=$(grep -ciE 'invalid next size|corrupted size vs|double free or corruption' "$out" || true)
          if [ "${n:-0}" -gt 0 ]; then
            echo "   💥 $n box64 heap-corruption crash line(s) in this log — alerting #server-status"
            ( . scripts/notify-lib.sh; publish_bus "💥 SERVER CRASH x${n} (box64 heap corruption) found in $(basename "$out") during shutdown/recreate — manual restart likely needed" urgent "alert,boom,skull" ) || true
          fi
        fi
      else
        /bin/rm -f "$out"   # container didn't exist — drop the empty file
      fi
    done

# internal: OPTIONAL pre-shutdown countdown. When SHUTDOWN_COUNTDOWN (seconds) is set
# AND players are online, warn everyone in-game every 10s before a down/restart/recreate.
# No-op when the var is unset/0 or nobody's online (so automation never waits for an empty
# server). ARG = the verb shown to players ("going down" / "restarting"). Off by default.
_shutdown-countdown REASON="going down":
    #!/usr/bin/env bash
    set -uo pipefail
    SECS="${SHUTDOWN_COUNTDOWN:-}"; case "$SECS" in ""|0|*[!0-9]*) exit 0;; esac
    # how many players are online right now? ("" if the server isn't responding)
    count_online() {
      docker exec bedrock send-command "list" >/dev/null 2>&1 || { echo ""; return; }
      sleep 0.5
      docker logs --since 4s bedrock 2>&1 \
        | grep -oE 'There are [0-9]+/[0-9]+ players online' | tail -1 \
        | grep -oE '[0-9]+' | head -1
    }
    online="$(count_online)"
    [ "${online:-0}" -gt 0 ] 2>/dev/null || { echo "→ countdown: nobody online — skipping the wait."; exit 0; }
    echo "→ ${SECS}s in-game countdown before {{REASON}} (${online} online)…"
    t="$SECS"
    while [ "$t" -gt 0 ]; do
      echo "   ⏳ ${t}s — warning ${online} player(s)…"
      docker exec bedrock send-command "tellraw @a {\"rawtext\":[{\"text\":\"§c§l⚠ Server {{REASON}} in ${t}s§r\"}]}" >/dev/null 2>&1 || true
      if [ "$t" -le 10 ]; then step="$t"; else step=10; fi   # handles a non-multiple-of-10 SECS
      sleep "$step"
      t=$((t - step))
      # if everyone left in the meantime, stop waiting and go down now.
      online="$(count_online)"
      [ "${online:-0}" -gt 0 ] 2>/dev/null || { echo "   ✅ everyone left — shutting down now (no need to wait)."; exit 0; }
    done
    echo "   ⏳ 0s — {{REASON}} now."
    docker exec bedrock send-command 'tellraw @a {"rawtext":[{"text":"§c§lServer going down now — see you soon!§r"}]}' >/dev/null 2>&1 || true

# list archived log snapshots (newest first)
archived:
    @echo "checking archived logs ..."
    @ls -1t bedrock-data/logs/ 2>/dev/null || echo "no archives yet — created on next: just down / just recreate"

# follow logs — all services by default, or one:  just logs bedrock|playit|monitor|bridge
logs SVC="":
    docker compose logs -f {{SVC}}

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

# broadcast a chat message to EVERYONE in-game (no quotes needed):  just say dinner in 10 mins
say +MSG:
    #!/usr/bin/env bash
    set -uo pipefail
    docker exec bedrock send-command "say {{MSG}}" >/dev/null 2>&1 \
      && echo "→ sent to in-game chat: {{MSG}}" \
      || { echo "❌ server not reachable — is it up? try: just status"; exit 1; }
    bash scripts/chat-relay.sh "{{MSG}}"   # mirror server broadcasts into #in-game-chat

# broadcast a STYLED message to EVERYONE in-game via tellraw (supports §-colour codes,
# more visible than `say`):  just say-raw "§6§lHeads up!§r §7dinner in 10"
say-raw +MSG:
    #!/usr/bin/env bash
    set -uo pipefail
    # tellraw @a renders §-formatting and is harder to miss than a plain [Server] line.
    docker exec bedrock send-command 'tellraw @a {"rawtext":[{"text":"{{MSG}}"}]}' >/dev/null 2>&1 \
      && echo "→ broadcast to everyone in-game: {{MSG}}" \
      || { echo "❌ server not reachable — is it up? try: just status"; exit 1; }
    bash scripts/chat-relay.sh "{{MSG}}"   # mirror server broadcasts into #in-game-chat (§-codes stripped)

# TEST the in-game-chat relay WITHOUT logging in: fires a fake chat line through the
# chat-bridge pack → #in-game-chat.  e.g.  just chattest hello from the console
chattest +MSG:
    #!/usr/bin/env bash
    set -uo pipefail
    docker exec bedrock send-command "scriptevent chatbridge:chattest {{MSG}}" >/dev/null 2>&1 \
      && echo "→ fired test chat: '{{MSG}}' — check #in-game-chat in a second or two" \
      || { echo "❌ server not reachable — is it up? (just status)"; exit 1; }

# whisper to ONE player (gamertag first):  just tell Steve your base is on fire
tell PLAYER +MSG:
    #!/usr/bin/env bash
    set -uo pipefail
    docker exec bedrock send-command "tell {{PLAYER}} {{MSG}}" >/dev/null 2>&1 \
      && echo "→ whispered to {{PLAYER}}: {{MSG}}" \
      || { echo "❌ server not reachable — is it up? try: just status"; exit 1; }

# print the public playit tunnel address
tunnel:
    @echo "printing tunnel address ..."
    @docker compose logs playit 2>&1 | grep -oiE "[a-z0-9.-]+\.(ply\.gg|playit\.gg)(:[0-9]+)?" | tail -1 || echo "not found — try: just plogs"

# ───────────────────────── notifications ────────────────────────────

# run the watcher in the FOREGROUND to test it live (Ctrl-C to stop) — host
# macOS (+ optional iPhone via ntfy) notification on player join/leave
notify-run:
    @echo "running notify ..."
    @./scripts/notify.sh

# reconcile #player-activity against the logs NOW — backfill any join/leave the live
# watcher missed (crash / kill / laptop asleep) so phantom-online players are healed.
# Runs automatically on up/restart/recreate; run it by hand any time too.
reconcile:
    @echo "running reconcile ..."
    @./scripts/reconcile.sh

# preview reconcile WITHOUT posting or touching the ledger (shows what it would backfill)
reconcile-preview:
    @echo "running reconcile (dry-run) ..."
    @RECONCILE_DRY_RUN=1 ./scripts/reconcile.sh

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

# bounce the running watcher to pick up edited notify.sh (e.g. the join→map capture)
notify-restart:
    @echo "restarting notify agent ..."
    @./scripts/notify-agent.sh restart

# is the permanent background watcher running?
notify-running:
    @echo "checking notify agent ..."
    @./scripts/notify-agent.sh status

# tail the notify agent's log
notify-logs:
    @tail -n 40 -f bedrock-data/logs/notify-agent.log

# ───────────── Chat bot: Discord #in-game-chat → Minecraft in-game chat ─────────────
# Needs CHAT_BOT_TOKEN + IN_GAME_CHAT_CHANNEL_ID in .env. First use auto-creates an
# isolated venv and installs discord.py. The reverse direction (game → Discord) is the
# chat-bridge pack, not this bot.

# run the bot in the FOREGROUND to test it live (Ctrl-C to stop)
bot-run:
    @./scripts/chat-bot-agent.sh run

# install the bot as a permanent background agent (starts at login, auto-restarts)
bot-install:
    @echo "installing chat-bot agent ..."
    @./scripts/chat-bot-agent.sh install

# stop & remove the permanent background bot
bot-uninstall:
    @echo "removing chat-bot agent ..."
    @./scripts/chat-bot-agent.sh uninstall

# bounce the running bot to pick up edited chat-bot.py (re-syncs slash commands)
bot-restart:
    @echo "restarting chat-bot agent ..."
    @./scripts/chat-bot-agent.sh restart

# is the permanent background bot running?
bot-running:
    @echo "checking chat-bot agent ..."
    @./scripts/chat-bot-agent.sh status

# tail the bot's log (shows each Discord→Minecraft relay)
bot-logs:
    @tail -n 40 -f bedrock-data/logs/chat-bot-agent.log

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
      MSG="🗄️ World snapshot saved — \`$(basename "$BK")\` · ${SIZE} · ${DBCOUNT} db files."
      safe=$(printf '%s' "$MSG" | sed 's/"/\\"/g')
      curl -fsS -H "Content-Type: application/json" \
        -d "{\"content\":\"${safe}\"}" "$DISCORD_WEBHOOK_BACKUP" >/dev/null 2>&1 \
        && echo "→ posted to #backups" || echo "   (Discord post failed — backup still OK)"
    else
      echo "   (DISCORD_WEBHOOK_BACKUP unset — skipped #backups post)"
    fi
    just _rotate-backups || true    # prune old snapshots (keep newest BACKUP_KEEP unsaved + all saved)

# list backups (newest first; 🔒 = saved/exempt from rotation)
backups:
    #!/usr/bin/env bash
    set -uo pipefail
    DIR="bedrock-data/backups"
    [ -d "$DIR" ] || { echo "no backups yet — run: just backup"; exit 0; }
    echo "📦 backups (newest first; 🔒 = saved/exempt, keep=${BACKUP_KEEP:-10}):"
    ls -1t "$DIR" 2>/dev/null | while IFS= read -r n; do
      [ -d "$DIR/$n" ] || continue       # skip the sibling .saved marker files
      if [ -e "$DIR/$n.saved" ]; then tag="🔒"; else tag="  "; fi
      sz=$(du -sh "$DIR/$n" 2>/dev/null | cut -f1)
      printf "  %s %-44s %s\n" "$tag" "$n" "${sz:-?}"
    done

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

# mark a backup as SAVED so rotation never prunes it (creates a sibling .saved marker)
backup-save NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    DIR="bedrock-data/backups"
    [ -d "$DIR/{{NAME}}" ] || { echo "no such backup: {{NAME}}"; echo "available:"; ls -1 "$DIR" 2>/dev/null; exit 1; }
    touch "$DIR/{{NAME}}.saved"
    echo "🔒 saved: {{NAME}} — exempt from rotation."

# un-mark a saved backup so rotation may prune it again
backup-unsave NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    /bin/rm -f "bedrock-data/backups/{{NAME}}.saved"
    echo "🔓 unsaved: {{NAME}} — rotation may prune it now."

# internal: keep the newest BACKUP_KEEP *unsaved* snapshots; delete older unsaved ones.
# 🔒 saved backups are always kept and don't count toward the limit. Called after `just backup`.
_rotate-backups:
    #!/usr/bin/env bash
    set -uo pipefail
    DIR="bedrock-data/backups"
    KEEP="${BACKUP_KEEP:-10}"; case "$KEEP" in ""|*[!0-9]*) KEEP=10;; esac
    [ -d "$DIR" ] || exit 0
    # unsaved backup dirs, oldest→newest (the {{world}}_YYYYMMDD-HHMMSS name sorts chronologically)
    unsaved=$(ls -1 "$DIR" 2>/dev/null | sort | while IFS= read -r n; do
      [ -d "$DIR/$n" ] || continue
      [ -e "$DIR/$n.saved" ] && continue
      echo "$n"
    done)
    total=$(printf '%s\n' "$unsaved" | grep -c .)
    if [ "$total" -le "$KEEP" ]; then
      echo "→ rotation: $total unsaved ≤ keep=$KEEP (saved snapshots always kept) — nothing to prune."
      exit 0
    fi
    prune=$((total - KEEP))
    echo "→ rotation: keep newest $KEEP unsaved + all saved; pruning $prune oldest unsaved…"
    DELETED=0
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if /bin/rm -rf "$DIR/$n"; then echo "  🗑️  pruned $n"; DELETED=$((DELETED + 1)); fi
    done < <(printf '%s\n' "$unsaved" | head -n "$prune")
    REMAIN=$(ls -1 "$DIR" 2>/dev/null | while IFS= read -r n; do [ -d "$DIR/$n" ] && echo x; done | grep -c .)
    echo "✅ rotation: pruned $DELETED; $REMAIN backup(s) remain (incl. saved)."
    if [ "$DELETED" -gt 0 ] && [ -n "${DISCORD_WEBHOOK_BACKUP:-}" ]; then
      MSG="♻️ Backup rotation: pruned ${DELETED} old snapshot(s); keeping newest ${KEEP} + saved (${REMAIN} total)."
      safe=$(printf '%s' "$MSG" | sed 's/"/\\"/g')
      curl -fsS -H "Content-Type: application/json" -d "{\"content\":\"${safe}\"}" "$DISCORD_WEBHOOK_BACKUP" >/dev/null 2>&1 || true
    fi

# stack health report.  `just doctor` (full) — also reused by in-game/Discord !doctor (--brief).
doctor *ARGS:
    @./scripts/doctor.sh {{ARGS}}

# internal: rate-limited, lock-guarded backup trigger shared by in-game (!backup via
# notify.sh) and Discord (!backup via chat-bot.py). Arg = requester id, e.g. "game:Steve".
# Prints ONE machine-parsable status line: OK <name> <size> | RATELIMIT <sec> | BUSY | ERR <msg>
_backup-request WHO:
    #!/usr/bin/env bash
    set -uo pipefail
    WHO="{{WHO}}"
    COOL="${BACKUP_COOLDOWN:-600}"; case "$COOL" in ""|*[!0-9]*) COOL=600;; esac
    CDIR="bedrock-data/.backup-cooldowns"; mkdir -p "$CDIR"
    key=$(printf '%s' "$WHO" | tr -c 'A-Za-z0-9._-' '_'); cf="$CDIR/$key"
    now=$(date +%s)
    if [ -f "$cf" ]; then
      last=$(cat "$cf" 2>/dev/null || echo 0); case "$last" in ""|*[!0-9]*) last=0;; esac
      rem=$((COOL - (now - last)))
      [ "$rem" -gt 0 ] && { echo "RATELIMIT $rem"; exit 0; }
    fi
    LOCK="bedrock-data/.backup.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then echo "BUSY"; exit 0; fi
    trap '/bin/rmdir "$LOCK" 2>/dev/null || true' EXIT
    out=$(just backup 2>&1) || { echo "ERR backup-failed"; exit 0; }
    printf '%s\n' "$now" > "$cf"     # start the cooldown only on a successful backup
    name=$(printf '%s\n' "$out" | sed -nE 's#^✅ backup: bedrock-data/backups/([^ ]+) .*#\1#p' | tail -1)
    size=$(printf '%s\n' "$out" | sed -nE 's#^✅ backup: .*\(([^,]+),.*#\1#p' | tail -1)
    echo "OK ${name:-snapshot} ${size:-?}"

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

# tail the uptime agent's log
uptime-logs:
    @tail -n 40 -f bedrock-data/logs/uptime-agent.log

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
    echo; echo "== heap-corruption crashes: $(docker logs bedrock 2>&1 | grep -ciE 'invalid next size|corrupted size vs|double free or corruption') =="

# internal: shared "server is starting" hook. If we're returning from an intentional stop
# (a `just down` left the flag) OR force is set, announce the return to Discord — using
# MSG, else prompting interactively (Enter = default), else the default — then clear the
# flag. Called by up/restart/recreate. (hc.io is never paused, so no resume.)
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
    [ -z "$MSG" ] && MSG="Server is back up. Reconnect and have fun!"
    MSG="🟢 ${MSG}"   # always flag #server-status UP announcements as "server back online"
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

# render a top-down terrain map of the overworld → world-map.png. Live renders also
# overlay ONLINE players (gamertag + live position); offline players are omitted (the
# world DB stores no gamertags). DB defaults to the live world (snapshotted to scratch
# first, never read in place); pass a backup's db for a guaranteed-consistent, player-less
# render, e.g.  just map "bedrock-data/backups/<name>/db"
map DB="":
    #!/usr/bin/env bash
    set -euo pipefail
    docker image inspect mc-tools >/dev/null 2>&1 || { echo "first run: building mc-tools image (~1-2 min)…"; just tools-build; }
    SRC="{{DB}}"; [ -n "$SRC" ] || SRC="bedrock-data/worlds/{{world}}/db"
    [ -d "$SRC" ] || { echo "no world db at: $SRC"; exit 1; }
    echo "→ copying db to scratch (never read the source in place)…"
    /bin/rm -rf bedrock-data/_live_db; cp -a "$SRC" bedrock-data/_live_db
    mkdir -p bedrock-data/_maptmp
    echo "→ extracting heightmap in mc-tools…"
    docker run --rm --platform linux/amd64 \
      -v "$PWD/bedrock-data/_live_db":/db \
      -v "$PWD/scripts":/scripts:ro \
      -v "$PWD/bedrock-data/_maptmp":/out \
      mc-tools python /scripts/export_heightmap.py
    echo "→ rendering on host…"
    # the render needs python3 + matplotlib/numpy. The first python3 on PATH (esp. under
    # the chat-bot launchd agent) may NOT have them, so pick the first interpreter that does
    # — including the pyenv one by absolute path, where they're actually installed.
    PYBIN=""
    for p in "$HOME/.pyenv/shims/python3" python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
      "$p" -c 'import matplotlib, numpy' >/dev/null 2>&1 && { PYBIN="$p"; break; }
    done
    [ -n "$PYBIN" ] || { echo "no python3 with matplotlib+numpy found (pip install matplotlib numpy)"; exit 1; }
    # overlay ONLINE players (real gamertag + live position from the running server) on LIVE
    # renders only — a backup's historical terrain shouldn't get current player dots. Offline
    # players are omitted (the world DB stores no gamertags). Best-effort: never fail the render.
    PLAYERS=""
    if [ -z "{{DB}}" ] && python3 scripts/online_players.py bedrock-data/_maptmp/players.json 2>/dev/null; then
      [ -s bedrock-data/_maptmp/players.json ] && PLAYERS="bedrock-data/_maptmp/players.json"
    fi
    "$PYBIN" scripts/render_map.py bedrock-data/_maptmp/heightmap.bin world-map.png $PLAYERS
    echo "✅ wrote world-map.png (rendered with $PYBIN${PLAYERS:+ · online players overlaid})"

# internal: render the overworld map AND post it to #map. Shared by in-game/Discord !map.
# Lock-guarded (renders are heavy) + rate-limited per requester. Arg = requester id, e.g.
# "game:Steve". Prints ONE status line: OK | RATELIMIT <sec> | BUSY | ERR <msg>
_map-request WHO:
    #!/usr/bin/env bash
    set -uo pipefail
    WHO="{{WHO}}"
    COOL="${MAP_COOLDOWN:-300}"; case "$COOL" in ""|*[!0-9]*) COOL=300;; esac
    CDIR="bedrock-data/.map-cooldowns"; mkdir -p "$CDIR"
    key=$(printf '%s' "$WHO" | tr -c 'A-Za-z0-9._-' '_'); cf="$CDIR/$key"
    now=$(date +%s)
    if [ -f "$cf" ]; then
      last=$(cat "$cf" 2>/dev/null || echo 0); case "$last" in ""|*[!0-9]*) last=0;; esac
      rem=$((COOL - (now - last))); [ "$rem" -gt 0 ] && { echo "RATELIMIT $rem"; exit 0; }
    fi
    LOCK="bedrock-data/.map.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then echo "BUSY"; exit 0; fi
    trap '/bin/rmdir "$LOCK" 2>/dev/null || true' EXIT
    hook="${DISCORD_WEBHOOK_MAP:-}"
    [ -n "$hook" ] || { echo "ERR no-webhook"; exit 0; }
    just map >/dev/null 2>&1 || { echo "ERR render-failed"; exit 0; }
    printf '%s\n' "$now" > "$cf"     # start the cooldown only once a render succeeds
    cap="🗺️ Fresh survey of the realm — requested by ${WHO#*:}."
    PAYLOAD=$(mktemp)
    CAP="$cap" P="$PAYLOAD" python3 -c 'import json,os;open(os.environ["P"],"w").write(json.dumps({"content":os.environ["CAP"]}))' 2>/dev/null \
      || printf '{"content":"%s"}' "🗺️ Fresh survey of the realm." > "$PAYLOAD"
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
      -F "payload_json=<$PAYLOAD" -F "file=@world-map.png;type=image/png" "$hook")
    /bin/rm -f "$PAYLOAD"
    case "$code" in 2*) echo "OK posted";; *) echo "ERR discord-$code";; esac

# internal: guard-aware manual restart trigger shared by Discord /restart + !restart
# (chat-bot.py). Restarts bedrock ONLY when a restart is genuinely WARRANTED — i.e. the
# server isn't actually serving — so it can never bounce a healthy server people are
# playing on, and rate-limits so a flood of /restart can't crash-loop the box. Arg =
# requester id, e.g. "discord:Steve". Prints ONE status line:
#   OK | HEALTHY | RATELIMIT <sec> | ERR <msg>
_restart-request WHO:
    #!/usr/bin/env bash
    set -uo pipefail
    WHO="{{WHO}}"
    # WARRANTED? Only bounce a server that isn't serving. The server is considered "serving"
    # (so a restart is REFUSED) when it BOTH answers a live `list` AND isn't Docker-unhealthy.
    # `list` succeeding proves the game loop is alive and reachable → players could be on it →
    # never restart. The unhealthy check is the debounced (~90s) backstop the autoheal watchdog
    # also uses. A crashed/hung/down server fails one or both → restart proceeds.
    health=$(docker inspect -f '{{{{.State.Health.Status}}' bedrock 2>/dev/null || echo missing)
    reachable=0
    docker exec bedrock send-command "list" >/dev/null 2>&1 && reachable=1
    if [ "$reachable" = "1" ] && [ "$health" != "unhealthy" ]; then
      echo "HEALTHY"; exit 0
    fi
    # rate-limit (GLOBAL, not per-user — the action is server-wide): one restart per cooldown,
    # so repeated /restart during a crash-loop can't pile bounce-on-bounce onto a struggling box.
    COOL="${RESTART_COOLDOWN:-120}"; case "$COOL" in ""|*[!0-9]*) COOL=120;; esac
    CDIR="bedrock-data/.restart-cooldowns"; mkdir -p "$CDIR"; cf="$CDIR/global"
    now=$(date +%s)
    if [ -f "$cf" ]; then
      last=$(cat "$cf" 2>/dev/null || echo 0); case "$last" in ""|*[!0-9]*) last=0;; esac
      rem=$((COOL - (now - last))); [ "$rem" -gt 0 ] && { echo "RATELIMIT $rem"; exit 0; }
    fi
    printf '%s\n' "$now" > "$cf"   # start the cooldown on ATTEMPT (even a failed one) to stop spam
    # in-place restart keeps the container's logs; `docker restart` SIGKILLs a wedged process
    # after the stop-timeout, so this clears the hung-but-running crash autoheal also targets.
    docker compose restart bedrock >/dev/null 2>&1 || { echo "ERR restart-failed"; exit 0; }
    echo "OK restarted"

# internal: read an OFFLINE player's last-saved coords from the world DB, resolving the
# gamertag via the gitignored map (bedrock-data/player-map.json → ServerId). Used by
# !coords / /coords as a fallback when the player isn't online. Reads a COPY of the live
# db (never in place). Prints ONE status line:  OK <dim> <x> <y> <z> | NOMAP | NORECORD
_coords-offline GAMERTAG:
    #!/usr/bin/env bash
    set -uo pipefail
    [ -f bedrock-data/player-map.json ] || { echo "NOMAP"; exit 0; }
    docker image inspect mc-tools >/dev/null 2>&1 || just tools-build >/dev/null 2>&1 || { echo "NORECORD"; exit 0; }
    /bin/rm -rf bedrock-data/_coords_db
    cp -a "bedrock-data/worlds/{{world}}/db" bedrock-data/_coords_db
    out=$(docker run --rm --platform linux/amd64 \
      -e LOOKUP_GAMERTAG="{{GAMERTAG}}" \
      -v "$PWD/bedrock-data/_coords_db":/db \
      -v "$PWD/scripts":/scripts:ro \
      -v "$PWD/bedrock-data/player-map.json":/player-map.json:ro \
      mc-tools python /scripts/saved_pos.py 2>/dev/null)
    /bin/rm -rf bedrock-data/_coords_db
    printf '%s\n' "$out" | grep -E '^(OK|NOMAP|NORECORD)' | tail -1 || echo "NORECORD"

# remove temporary inspection copies (backups + scripts are kept)
clean:
    @echo "cleaning scratch dirs ..."
    @/bin/rm -rf bedrock-data/_live_db bedrock-data/_maptmp && echo "cleaned scratch dirs"
