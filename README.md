# Self-Hosted Minecraft Bedrock Server

Runs a Bedrock Dedicated Server **and** a playit.gg tunnel in Docker, so friends can
join from anywhere — including consoles — with no port forwarding.

---

## 1. `docker-compose.yml`

```yaml
services:
  bedrock:
    image: itzg/minecraft-bedrock-server
    container_name: bedrock
    environment:
      EULA: "TRUE"
      SERVER_NAME: "hello-world"
      GAMEMODE: "survival"
      DIFFICULTY: "normal"
      VERSION: "LATEST"          # tracks current Bedrock version so it matches auto-updated clients
    ports:
      - "19132:19132/udp"        # keeps direct LAN play / PS5 "LAN Games" discovery working
    volumes:
      - ./bedrock-data:/data     # world persists here, next to this file
    networks:
      mc:
        ipv4_address: 172.20.0.10
    stdin_open: true             # itzg image expects -i
    tty: true                    # ...and -t, so you can attach to the console
    restart: unless-stopped

  playit:
    image: ghcr.io/playit-cloud/playit-agent:0.17
    container_name: playit
    environment:
      - SECRET_KEY=${PLAYIT_SECRET_KEY}
    networks:
      - mc
    depends_on:
      - bedrock
    restart: unless-stopped

networks:
  mc:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
```

---

## 2. Create a playit.gg agent

1. Sign up at https://playit.gg
2. Setup wizard → choose **Docker** (shortcut: https://playit.gg/account/agents/new-docker)
3. Give the agent any name
4. Copy the generated key into a `.env` file next to the compose file:

   ```dotenv
   PLAYIT_SECRET_KEY=some-long-series-of-characters
   ```

   > The key is shown only once. Add `.env` to `.gitignore` — the compose file is safe to commit, the key is not.

---

## 3. Start it

```bash
docker compose up -d
```

Confirm the agent actually connected:

```bash
docker compose logs -f playit
```

You want `secret key valid` → `agent registered` → `tunnel running`.
If you see `Error: InvalidSecret`, the key in `.env` is wrong — regenerate it (step 2).

> Use `-d` (detached). If you run it in the foreground, the agent dies the moment you close the terminal.

---

## 4. Create the tunnel

The agent **must be running/online** for this (an offline agent shows a `?` and "tunnel type not supported").

1. Go to https://playit.gg/account/tunnels → **New Tunnel**
2. Name: anything
3. Tunnel Type: **Minecraft Bedrock**
4. Public Endpoint: **Free Network**
5. Assign to Agent: your agent → **Next**
6. Open the tunnel → **Origin Configuration** tab → set:
   - **Local Address:** `172.20.0.10`
   - **Local Port:** `19132`

   > Critical: it defaults to `127.0.0.1`, which points the agent at *itself*. The server is a
   > separate container at `172.20.0.10` (the static IP pinned in the compose file).

7. Grab the tunnel's public address, e.g. **`<random>.ply.gg:12345`** (or an `IP:port`)
   (the part before `:` is the host, the number after is the port — yours will differ).

---

## 5. Connect

### PC / phone / tablet
Minecraft → **Servers** tab → **Add Server** → enter the IP and port → Join. Done.

### Console (PS5 / Xbox / Switch)
Consoles have no "Add Server" button, so they need **BedrockConnect** (a DNS redirect into the
featured-server list):

1. Console network settings → set DNS to **Manual**:
   - **Primary DNS:** `45.55.68.52`  (PS5; Xbox/Switch can use `104.238.130.180`)
   - **Secondary DNS:** `8.8.8.8`
2. Minecraft → **Servers** tab → click **any featured server** (not The Hive — its DNSSEC blocks the redirect)
3. In the BedrockConnect menu → **Connect to a Server** → enter the tunnel **IP** and **port**
4. Set DNS back to **Automatic** when you're done (otherwise featured servers stay redirected).

---

## Quick verification

Phone on **mobile data** (Wi-Fi off) → Minecraft → Add Server → tunnel IP + port.
If the phone connects, the full internet path works and the PS5 will too.

---

## Day-to-day commands

```bash
docker compose up -d                                   # start
docker compose down                                    # stop
docker compose logs -f                                 # watch both containers
docker compose down -v --remove-orphans && \
  docker compose up -d --force-recreate                # full clean restart
```

The world lives in `./bedrock-data` (a bind mount) and **survives** `down -v`.
To wipe the world too: `docker compose down && rm -rf ./bedrock-data`.

## Player join/leave notifications (macOS + iPhone)

Get a desktop banner **and** an iPhone push whenever a player connects/disconnects
(e.g. `👋 Steve left — 0/10 online`). The watcher (`scripts/notify.sh`) tails
`docker logs` on the **host** and runs permanently as a launchd LaunchAgent. The recipes
are in the `Justfile` (`just notify*`), but the steps below are the **manual/external**
parts that must be redone on a fresh machine.

### One-time setup

1. **Install `terminal-notifier`** (host dependency — plain `osascript` notifications post
   as "Script Editor" and macOS 15 *Sequoia* silently suppresses them):

   ```bash
   brew install terminal-notifier
   ```

   First run may need approval: **System Settings → Notifications → terminal-notifier →
   Allow Notifications**. Also make sure no **Focus / Do Not Disturb** is active.

2. **iPhone push via [ntfy.sh](https://ntfy.sh)** (optional — skip for Mac-only):
   - Install the **ntfy** app (App Store — by *Philipp Heckel* / `binwiederhier`, bundle
     `io.heckel.ntfy`; free, no account).
   - In the app: **Subscribe to topic** → server `ntfy.sh` → enter a **private, random**
     topic name (treat it like a password — anyone who knows it can read your pings),
     e.g. `mc-<your-server>-<random>`.
   - Add that exact topic to `.env`:

     ```dotenv
     NTFY_TOPIC=mc-yourserver-xxxxxxxxxx
     ```

     > ⚠️ Ensure `.env` **ends with a newline** before appending, or the new line glues onto
     > the end of `PLAYIT_SECRET_KEY` and corrupts it. Verify with:
     > `grep -c '^NTFY_TOPIC=' .env` (should print `1`).

3. **Install the permanent watcher** (writes `~/Library/LaunchAgents/com.mcserver.notify.plist`,
   starts at login, auto-restarts if it dies or the container recreates):

   ```bash
   just notify-install
   ```

### Commands

```bash
just notify-install     # set up + start the permanent background watcher (launchd)
just notify-uninstall   # stop + remove it
just notify-running     # is it alive? (pid / state)
just notify            # run once in the foreground (ad-hoc; Ctrl-C to stop)
just notify-test       # prove it works WITHOUT logging in (fires on the `list` line)
```

After editing `.env` or `scripts/notify.sh`, reload the running agent:

```bash
launchctl kickstart -k gui/$(id -u)/com.mcserver.notify
```

The agent logs to `bedrock-data/logs/notify-agent.log`; it prints `iPhone push: ON` there
when `NTFY_TOPIC` is picked up.

### Alerts & the event bus (crashes, tunnel, resources, Discord)

`NTFY_TOPIC` doubles as a **pub/sub bus**: anything can publish, and any number of
subscribers react. On top of join/leave this gives server-health alerts and a Discord feed.

```
 PUBLISHERS ─POST─▶  ntfy.sh/<topic>  ─stream─▶  SUBSCRIBERS
 • host watcher        (the bus)                 • iPhone ntfy app (push)
   joins / leaves                                • bridge container → Discord + prints
 • monitor container                             • any `curl .../json` listener
   crash, tunnel-down, CPU/mem, daily digest
```

- The **monitor** container (`scripts/monitor.sh`) detects and publishes: **server down/up**
  (container liveness — catches *any* stop/crash/OOM, not just the box64 one), the box64
  `free(): invalid next size` **crash**, server **ready**, **tunnel-down** (silence of
  playit's `tunnel running` heartbeat),
  **high CPU/memory** (cooldown-limited; memory is an early warning for the heap crash),
  and a **daily digest**. Thresholds via env: `MONITOR_CPU_ALERT` (%, default 300),
  `MONITOR_MEM_ALERT` (MiB, default 1500), `MONITOR_ALERT_COOLDOWN` (s, default 600).
- The **bridge** container (`scripts/bridge.sh`) subscribes to the bus, prints every event,
  and forwards to Discord if `DISCORD_WEBHOOK_URL` is set.

Start the whole observability stack (both containers, opt-in `monitor` profile):

```bash
just monitor-up      # start monitor + bridge
just bridge-logs     # watch events flow through the bus
just monitor-down    # stop them
just digest-now      # publish a digest on demand (peak players, joins/leaves, crashes) → #monitoring
```

**Discord (optional, manual) — routed to per-category channels:** every event carries a
category tag (`player` / `alert` / `monitor`) and the bridge posts it to the matching
channel's webhook. In Discord, create channels (e.g. `#player-activity`, `#alerts`,
`#monitoring`); for each, *Edit Channel → Integrations → Webhooks → New Webhook → Copy URL*.
Put them in `.env`:

```dotenv
DISCORD_WEBHOOK_PLAYER=https://discord.com/api/webhooks/XXXX/YYYY    # joins/leaves
DISCORD_WEBHOOK_ALERT=https://discord.com/api/webhooks/XXXX/YYYY     # crash/tunnel/resource
DISCORD_WEBHOOK_MONITOR=https://discord.com/api/webhooks/XXXX/YYYY   # daily digest
# DISCORD_WEBHOOK_URL=...   # optional single catch-all; used for any category left unset
```

Reload the bridge to pick them up (monitor-only, never touches bedrock):
`docker compose --profile monitor up -d --no-deps bridge`. Routing categories:

| Category | Events | Channel |
|---|---|---|
| `player`  | joins / leaves (+ online count) | `#player-activity` |
| `alert`   | crash, server-up, tunnel down/up, high CPU/mem + cleared | `#alerts` |
| `monitor` | daily digest | `#monitoring` |

## Safety guards (don't disconnect players)

Two layers stop the server being restarted/stopped while someone's playing:

1. **Interactive guard** — `scripts/guard.sh` runs before the disruptive recipes
   (`just down` / `restart` / `recreate` / `up`). If players are online it prints who,
   and you must **type the exact player count** to proceed (no reflexive "y"). With nobody
   online it's a simple y/N. Bypass for automation: `FORCE=1 just down`. Fails closed if
   there's no terminal to confirm on.

2. **Claude Code hook** — `.claude/hooks/claude-guard-hook.sh`, registered as a `PreToolUse`
   hook on `Bash` in `.claude/settings.json`. It intercepts *Claude's own* commands: any
   `docker compose down` / `… stop|restart|rm bedrock|playit` / `--force-recreate` /
   `just down|restart|recreate|up` triggers an **approval prompt to you** (naming any online
   players) — for every such command, whether or not players are online. Nothing disruptive
   runs without your explicit OK. (It deliberately over-matches on those phrases — erring safe.)

Read-only commands (`logs`, `ps`, `just players`, `just status`) and monitor/bridge-only ops
are never gated.

# Fun Commands

Once the server is running, you can attach to the console:

```bash
docker exec bedrock send-command "gamerule showcoordinates true"
```

```bash
docker exec bedrock send-command "execute as @a at @s run setblock ~ ~5 ~ minecraft:diamond_block"
```