# Self-Hosted Minecraft Bedrock Server

A self-hosted **Bedrock Dedicated Server** in Docker, exposed to the internet through a
**playit.gg** tunnel (no port-forwarding, works for consoles), wrapped in a batteries-included
operations layer:

- 📲 **Notifications** — phone push (ntfy) on every join/leave; optional macOS desktop alerts
- 📈 **Monitoring** — crash / tunnel-down / high-CPU-mem alerts, a daily digest, and a 4-panel **uptime graph**
- 💬 **Two-way Discord chat** — in-game chat appears in `#in-game-chat`, and Discord messages appear in-game
- 🎮 **Commands anywhere** — `!cmd` in-game and `/cmd` (or `!cmd`) in Discord share one rate-limited surface
- 🗺️ **World map** — render the overworld to a hill-shaded PNG and post it to `#map`
- 🗄️ **Backups** — consistent world snapshots, self-rotating, with one command
- 🩺 **Health check** — `just doctor` (also `!doctor` / `/doctor`) for an at-a-glance status report
- 🛡️ **Safety guards** — nothing restarts/stops the server while a player is online
- 🧙 **`just setup`** — an interactive wizard that gets a fresh clone running

> Runs on an Apple-Silicon Mac (the x86 Bedrock server runs under box64). The server stack is
> Docker; a few host-side helpers run as macOS launchd agents — see [Architecture](#architecture).

> **Version:** date-based (CalVer `YYYY.MM.DD`) — current in [`VERSION`](VERSION), history in [`CHANGELOG.md`](CHANGELOG.md).

---

## Quick start

### Requirements

| Tool | Needed for | Install |
|---|---|---|
| **Docker** (+ daemon running) | the server stack | [OrbStack](https://orbstack.dev) or [Docker Desktop](https://docker.com/products/docker-desktop) |
| **just** | the task runner | `brew install just` |
| **Go** | the `just setup` wizard only | `brew install go` (or [go.dev/dl](https://go.dev/dl/)) |
| **python3** | chat bot + uptime graph (optional features) | `brew install python3` |
| **terminal-notifier** | macOS desktop alerts (opt-in only) | `brew install terminal-notifier` |

### Set it up

```bash
git clone <this-repo> && cd minecraft-server
just setup
```

`just setup` launches an **interactive, idempotent wizard** that:

1. Checks your machine for the tools above and prints install hints for anything missing.
2. Walks you through `.env` one prompt at a time (pre-filled from any existing `.env` — accept to keep, or edit). Only **playit's secret key** is required; everything else is optional and skippable.
3. Writes `.env` (creating it from `.env.example` on a fresh clone, or merging in place without clobbering existing values/comments).
4. Offers to start the stack and install the background agents — each step is safe to re-run, and anything already done is marked as such.

Re-run `just setup` any time; it never breaks what's already configured or running.

> Don't want the wizard? `cp .env.example .env`, fill it in, and run `docker compose up -d`.
> See [Manual setup](#manual-setup-no-wizard).

### Get the public address

```bash
just tunnel        # prints your playit address, e.g. <random>.ply.gg:12345
```

Give that host + port to your friends. See [Connecting](#connecting).

---

## Architecture

Two homes, by design (see *why* below):

### 🐳 Docker containers (`docker compose up -d` starts all four)
| Service | Image | Job |
|---|---|---|
| **bedrock** | itzg/minecraft-bedrock-server | the game server |
| **playit** | playit-agent | outbound tunnel → public address |
| **monitor** | docker:cli | reads logs/stats, fires health alerts, writes CSVs (mounts the docker socket **read-only**) |
| **bridge** | curlimages/curl | subscribes to the ntfy bus, fans events out to Discord webhooks |

### 🖥️ Host launchd agents (macOS, start at login, auto-restart)
| Agent | Manage with | Job |
|---|---|---|
| `com.mcserver.notify` | `just notify-*` | join/leave → phone push (+ opt-in desktop alert) |
| `com.mcserver.uptime` | `just uptime-*` | daily uptime graph → `#monitoring` |
| `com.mcserver.chatbot` | `just bot-*` | Discord `#in-game-chat` → in-game chat |

**Why some things run on the host (not in containers):**
- **macOS desktop notifications** can't be sent from a Linux container — that's a host-only API.
- The **chat bot** drives `docker exec … send-command` (read-**write** daemon control). A writable
  docker socket inside a container is root-equivalent on the host; running the controller *outside*
  what it controls is safer and avoids a lifecycle paradox.
- Host agents keep **observing/announcing even while the stack is down or being recreated**.

(The `monitor` container is the exception that proves the rule: it only *reads* the daemon, so it
mounts the socket **read-only** and is safely containerized.)

---

## Connecting

> Addresses below are **examples** — get yours with `just tunnel`.

### PC (Minecraft for Windows — Bedrock)
**Play → Servers tab → Add Server** → name it, enter the tunnel **host** + **port** → **Save** → **Join**.

### PS5 / Xbox / Switch (via BedrockConnect)
Consoles have no "Add Server", so they use a DNS redirect into the featured-server list:

1. Console network settings → set **DNS to Manual**:
   - **Primary:** `45.55.68.52` (Xbox/Switch can use `104.238.130.180`)
   - **Secondary:** `8.8.8.8`
2. Launch Minecraft → **Play → Servers** → open any **featured server** → **BedrockConnect** loads.
3. **Connect to a Server** → enter your tunnel **host** + **port** → check **Add to server list** → connect.
4. When done, set console DNS back to **Automatic**.

**Quick check:** phone on **mobile data** (Wi-Fi off) → Add Server → tunnel host+port. If the phone
connects, the full internet path works and consoles will too.

---

## Everyday commands

```bash
just                 # list every recipe
just up              # start (guarded; announces return to #server-status with 🟢)
just down "reason"   # stop (guarded; kicks players cleanly first; announces 🛠️)
just restart         # bounce bedrock only (keeps logs)
just status          # container status        just players   # who's online
just tunnel          # public address          just logs      # follow all logs
just backup          # consistent world snapshot (auto-rotates oldest)
just doctor          # one-shot health report   just map       # render the overworld → world-map.png
```

Timestamps everywhere are **UK time** (`TZ=Europe/London`), matching Discord and the graphs.
`just up`/`down`/`restart` prompt for a `#server-status` message (Enter for a default); the
announcement is prefixed 🟢 (up) or 🛠️ (down).

---

## Features

### 📲 Notifications (phone + opt-in desktop)

`scripts/notify.sh` (the `notify` agent) tails the server log and announces joins/leaves. The two
output channels are **independent**:

- **Phone push via [ntfy.sh](https://ntfy.sh)** — the default. On whenever `NTFY_TOPIC` is set.
- **macOS desktop alert** — **opt-in, off by default.** Enable with `NOTIFY_MACOS=1` in `.env`
  (uses `terminal-notifier`).

```bash
just notify-install / notify-uninstall / notify-running    # manage the permanent agent
just notify-test          # prove the pipeline without logging in
```

`NTFY_TOPIC` doubles as a **pub/sub bus**: publishers POST events, and subscribers (your phone's
ntfy app, the `bridge` container → Discord) react.

### 📈 Monitoring, alerts & Discord routing

The **monitor** container detects and publishes: **server down/up**, the box64
**heap-corruption crash** family (`invalid next size` / `corrupted size vs` / `double free`),
**tunnel-down** (playit heartbeat silence), **high CPU/memory**, and a **daily digest**. Thresholds
via `.env` (`MONITOR_CPU_ALERT` %, `MONITOR_MEM_ALERT` MiB, `MONITOR_ALERT_COOLDOWN` s).

The **bridge** routes each event to a per-channel Discord webhook by category:

| Category | Events | Webhook (`.env`) → channel |
|---|---|---|
| `player` | joins / leaves | `DISCORD_WEBHOOK_PLAYER` → `#player-activity` |
| `alert` | crash, up/down, tunnel, CPU/mem | `DISCORD_WEBHOOK_SERVER_STATUS` → `#server-status` |
| `monitor` | daily digest, uptime graph | `DISCORD_WEBHOOK_MONITOR` → `#monitoring` |
| `chat` | in-game chat relay | `DISCORD_WEBHOOK_CHAT` → `#in-game-chat` |

Any category left unset falls back to `DISCORD_WEBHOOK_URL`. Reload the bridge after editing webhooks
(never touches bedrock): `docker compose up -d --no-deps bridge`.

### 📊 Uptime graph

A 4-panel daily PNG (status strip · players · CPU · memory) in UK time → `#monitoring`. The status
strip is driven by **healthchecks.io flip history** (so it reflects real player-reachability, not just
"is the container up"). Needs `HEALTHCHECK_URL`, `HEALTHCHECK_API_KEY`, `DISCORD_WEBHOOK_MONITOR`.

```bash
just uptime               # post the last 24h now
just uptime-preview       # render locally WITHOUT posting
just uptime-install       # schedule the daily 00:05 post (launchd)
```

### 💬 Two-way Discord ↔ in-game chat

- **In-game → Discord:** a Bedrock **behavior pack** (`bedrock-data/behavior_packs/chat-bridge`)
  posts chat to `#in-game-chat` via `DISCORD_WEBHOOK_CHAT`. *(Advanced: needs the world's "Beta APIs"
  experiment enabled + the pack added to the world — already configured on the bundled world.)*
- **Discord → in-game:** the **chat bot** (`com.mcserver.chatbot`) listens on the Discord Gateway
  and injects messages with `tellraw`. Loop-safe: it only relays **human** messages from the one
  channel (ignores bots/webhooks), and `tellraw` never re-triggers the outbound relay.

  ```bash
  # .env: CHAT_BOT_TOKEN + IN_GAME_CHAT_CHANNEL_ID  (bot needs MESSAGE CONTENT INTENT)
  just bot-run         # foreground test
  just bot-install     # permanent agent     just bot-logs / bot-running / bot-uninstall
  ```

- **From the console:**
  ```bash
  just say  "dinner in 10"                       # broadcast to everyone (also → #in-game-chat)
  just say-raw "§6§lHeads up!§r §7dinner in 10"  # styled broadcast (§ colour codes)
  just tell Steve "your base is on fire"         # private whisper (not relayed)
  ```

### 🗄️ Backups

```bash
just backup            # flush + consistent snapshot (no player disconnect) → #backups
just backups           # list (🔒 = saved/exempt)     just restore <name>    # restore one
just backup-save <name> / backup-unsave <name>        # protect a snapshot from rotation
just backup-clean      # interactive prune (manual; always keeps the 3 newest)
```

**Rotation is automatic.** After each `just backup`, the newest `BACKUP_KEEP`
(`.env`, default **10**) *unsaved* snapshots are kept and older ones pruned.
Mark any snapshot with `just backup-save <name>` to keep it forever — 🔒 saved
snapshots are exempt from rotation and don't count toward the limit.

Players can also trigger a backup themselves via `!backup` (in-game or Discord),
rate-limited to one per requester every `BACKUP_COOLDOWN` (default 10 min).

### 🩺 Health report

```bash
just doctor            # full report: containers, health, restart counts, CPU/mem, disk, webhooks
just doctor --brief    # one compact line (what !doctor / /doctor reply with)
```

Runnable from in-game (`!doctor`) and Discord (`!doctor` or `/doctor`) too.

### 🎮 Commands (in-game + Discord)

One command surface, two front-ends. In-game chat uses the `!` prefix; Discord
accepts the same `!` prefix **and** native `/` slash commands (in `#in-game-chat`
or `#map`). Because there's no clean Discord↔Minecraft identity mapping,
player-specific commands take the target as an argument in Discord.

| Command | Does | Notes |
|---|---|---|
| `!commands` | list available commands | |
| `!coords [player]` | report a player's coordinates | pass the target in Discord |
| `!backup` | trigger a world snapshot | rate-limited per requester (`BACKUP_COOLDOWN`) |
| `!map` | render the overworld → `#map` | rate-limited per requester (`MAP_COOLDOWN`) |
| `!doctor` | health report | replies with the `--brief` line |
| `!mail <player> <msg>` | leave in-game mail | delivered on the recipient's next join |
| `!shrug` | ¯\\\_(ツ)_/¯ | |

Slash equivalents: `/map`, `/backup`, `/doctor`, `/coords`, `/mail`, `/shrug`.

> The in-game `!` commands live in the chat-bridge behavior pack and activate on
> the next server reload; the Discord side is served by the `chatbot` agent.

### 🗺️ World map

`just map` reads the live world's LevelDB (in a throwaway `mc-tools` container),
extracts a surface heightmap, and renders a north-up, hill-shaded terrain PNG
(`world-map.png`, gitignored — it's a render of the real world). `!map` / `/map`
post it directly to `#map` via `DISCORD_WEBHOOK_MAP`.

```bash
just map                                   # render the live world
just map "bedrock-data/backups/<name>/db"  # render a specific backup (guaranteed-consistent)
```

### 🛡️ Safety guards

1. **Interactive guard** (`scripts/guard.sh`) runs before `up`/`down`/`restart`/`recreate`. If players
   are online it lists them and makes you type the exact count to proceed. Bypass for automation: `FORCE=1`.
2. **Claude Code hook** (`.claude/`) intercepts Claude's own disruptive commands and prompts you first.

Read-only commands and monitor/bridge-only ops are never gated.

---

## Manual setup (no wizard)

1. `cp .env.example .env` and fill it in (only `PLAYIT_SECRET_KEY` is required). Get a playit key:
   sign up at [playit.gg](https://playit.gg) → New agent (Docker) → copy the secret (shown once).
2. `docker compose up -d` — then confirm the tunnel: `docker compose logs -f playit` (want
   `secret key valid` → `agent registered` → `tunnel running`).
3. Create the tunnel at [playit.gg/account/tunnels](https://playit.gg/account/tunnels) → New Tunnel →
   **Minecraft Bedrock** → Free Network → assign your agent → **Origin: Local Address `172.20.0.10`,
   Port `19132`** (it defaults to `127.0.0.1`, which is wrong — the server is a separate container).
4. Optional features: set the relevant `.env` vars and install the agents (`just notify-install`,
   `just uptime-install`, `just bot-install`).

The world persists in `./bedrock-data` (a bind mount) and survives `docker compose down`.
To wipe it: `docker compose down && rm -rf ./bedrock-data`.

---

## Fun commands

```bash
just cmd "gamerule showcoordinates true"
just cmd "execute as @a at @s run setblock ~ ~5 ~ minecraft:diamond_block"
```

> **Note on crashes:** the box64 heap-corruption crashes (`free(): invalid next size`, etc.) are an
> emulation artifact of running x86 Bedrock on Apple Silicon. Restarts clear them; the real cure is
> native x86 hosting. The monitor detects and reports them.
