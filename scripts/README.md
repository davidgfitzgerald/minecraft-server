# `scripts/`

Host + container scripts behind the Bedrock server: world-data tools, the
Discord chat bridge, the world-map renderer, and the ops/health daemons. Almost
nothing here is run by hand — most are invoked by the [`Justfile`](../Justfile)
recipes or installed as macOS **launchd** agents.

The directory is intentionally **flat**: the `mc-tools` container mounts the
whole dir at `/scripts`, the Python tools import each other as siblings
(`from bedrock_nbt import …`), and the Justfile / launchd plists reference these
paths directly — so moving files into subfolders has a large blast radius for
little gain. Organise by the index below, not by folders.

Conventions:
- **`*-agent.sh`** — a launchd installer (`install` / `uninstall` subcommands),
  wrapping a long-running host daemon. Driven by `just bot-install`, etc.
- **World-data tools** import `bedrock_nbt.py` and run **inside the `mc-tools`
  container** (built from `tools.Dockerfile`) — they never need anything
  installed on the Mac.

## Index

### World / player-data tools — run in the `mc-tools` container
Read/edit the Bedrock world LevelDB (`bedrock-data/worlds/<level>/db`). See the
[usage sections below](#world--player-data-tools-usage).

| Script | Purpose |
|---|---|
| `bedrock_nbt.py` | Shared LevelDB open + little-endian NBT parsing helpers (imported by the rest). |
| `profile_report.py` | Full human-readable report: every character's inventory, armor, XP, enchantments. |
| `account_map.py` | Dumps the account→profile mapping (`MsaId` / `PlatformOnlineId` / `ServerId`). |
| `apply_profile.py` | Copies one character's data onto another's profile key (`SRC_KEY`→`DST_KEY`). Server must be stopped. |
| `restore_profile.py` | Restores `DST_KEY` from the snapshot `apply_profile.py` saved. Server must be stopped. |
| `audit_keys.py` | Lists every key in the world DB (find `player_server_<uuid>` keys). |
| `saved_pos.py` | Reads a player's last-saved position from the DB (offline `/coords`). |
| `check_chunk.py` / `scan_chunks.py` / `find_void.py` | Chunk-level inspection / diagnostics. |
| `export_heightmap.py` | Surface heightmap + true-block colour → `heightmap.bin` (map step 1). |
| `export_players.py` | Every player's last-saved `Pos`/`DimensionId` → offline overlay. |

### Map render — host (numpy + matplotlib)
| Script | Purpose |
|---|---|
| `render_map.py` | Stitches `heightmap.bin` into a north-up, hill-shaded PNG; overlays players. |
| `players_overlay.py` | Merges online (live) + offline (saved) player positions → `players.json`. |
| `online_players.py` | Queries the running server (`list` + `querytarget`) for live positions + gamertags. |

### Chat / Discord bridge
| Script | Purpose |
|---|---|
| `chat-bot.py` | Discord bot: `#in-game-chat` ⇄ Minecraft, slash + `!` commands. |
| `chat-bot-agent.sh` | launchd installer for `chat-bot.py`. |
| `chat-relay.sh` | Relays server-console lines to the Discord webhook. |
| `bridge.sh` | Discord → Minecraft chat injector. |
| `notify.sh` | Tails server logs → join/leave pushes, in-game `CHATCMD` host actions, mail. |
| `notify-lib.sh` | Shared notify/publish helpers (sourced, not run). |
| `notify-agent.sh` | launchd installer for `notify.sh`. |
| `digest.sh` | Periodic activity digest. |
| `capture_player_map.py` | On join, learns gamertag→ServerId for offline `/coords` + map labels. |

### Health / ops / guards
| Script | Purpose |
|---|---|
| `doctor.sh` | Health check: players, CPU, memory, tunnel (`just doctor`). |
| `guard.sh` | Confirmation gate — refuses stop/restart while players are online. |
| `monitor.sh` | Self-healing watchdog (restarts a genuinely-down server). |
| `reconcile.sh` | Backfills join/leave events missed across a bounce. |
| `graceful-kick.sh` | Warns + kicks players ahead of planned downtime. |
| `uptime.sh` / `uptime_graph.py` / `uptime-agent.sh` | Daily uptime graph (from healthchecks.io flips) + its launchd installer. |

### Build
| File | Purpose |
|---|---|
| `tools.Dockerfile` | The `mc-tools` image: `python:3.11` + `amulet-leveldb`, built native (`just tools-build`). |

---

## World / player-data tools usage

These run inside a throwaway container with
[`amulet-leveldb`](https://pypi.org/project/amulet-leveldb/) (Mojang's LevelDB
fork), so nothing needs installing on the Mac. It builds from source on the
host's native architecture (arm64 included) — no `--platform` pin needed.

The NBT inside each player record is little-endian, uncompressed; these scripts
parse it directly (no external NBT lib needed).

### Read-only: generate the profile report

Safe to run while the server is up (it reads a **copy** of the db):

```bash
cd /path/to/minecraft-server
LIVE="bedrock-data/worlds/${LEVEL_NAME}/db"
/bin/rm -rf bedrock-data/_live_db && cp -a "$LIVE" bedrock-data/_live_db   # note: /bin/rm — `rm` is aliased to `trash`
docker run --rm \
  -v "$PWD/bedrock-data/_live_db":/db \
  -v "$PWD/scripts/profile_report.py":/work/profile_report.py:ro \
  python:3.11 bash -c "pip install -q amulet-leveldb 2>/dev/null && python /work/profile_report.py" \
  > player-profiles-report.md
```

### Read-write: transfer a character onto another profile

The world LevelDB can't be open twice, so **stop the server first**. Mount the
**real** world db (not a copy) read-write, plus `bedrock-data` as `/out` for the
safety snapshot.

```bash
cd /path/to/minecraft-server
WORLD_DB="$PWD/bedrock-data/worlds/${LEVEL_NAME}/db"

docker compose stop bedrock
docker run --rm \
  -e SRC_KEY="player_server_<source-uuid>" \
  -e DST_KEY="player_server_<destination-uuid>" \
  -v "$WORLD_DB":/db \
  -v "$PWD/bedrock-data":/out \
  -v "$PWD/scripts/apply_profile.py":/work/apply_profile.py:ro \
  python:3.11 bash -c "pip install -q amulet-leveldb 2>/dev/null && python /work/apply_profile.py"
docker compose start bedrock
```

To undo, run the same pattern with `restore_profile.py` (only `DST_KEY` needed).

### Finding profile keys

Run `just accounts` (account → profile mapping) or `just audit` (every key in the world DB)
to list the `player_server_<uuid>` keys and see which belongs to which player — then use
those as `SRC_KEY` / `DST_KEY` above.

### Always back up first

```bash
TS=$(date +%Y%m%d-%H%M%S)
cp -a "bedrock-data/worlds/${LEVEL_NAME}" \
      "bedrock-data/backups/${LEVEL_NAME}_$TS"
```

## World map renderer

`just map` renders the overworld to a PNG. It's a two-step pipeline:

| Script | Where | Purpose |
|---|---|---|
| `export_heightmap.py` | `mc-tools` container | reads the world db, writes a surface heightmap + true-block colour (`heightmap.bin`). |
| `online_players.py` | host (needs docker) | queries the **running server** (`list` + `querytarget`) for online players' live positions, labelled with real **gamertags**. This is what live `just map` overlays. |
| `export_players.py` | `mc-tools` container | extracts **every** player's last-saved `Pos`/`DimensionId` from the db → offline overlay (labelled via the gitignored gamertag→ServerId map; unmapped players get opaque short ids). |
| `players_overlay.py` | host | merges the online + offline sources into the `players.json` the renderer reads. |
| `render_map.py` | host (numpy + matplotlib) | stitches the heightmap into a north-up, hill-shaded PNG; overlays the player positions. |

The container scripts share `bedrock_nbt.py` (little-endian NBT + LevelDB
helpers). The generated `world-map.png` is **gitignored** — it's a render of the
real world and may reveal player positions.
