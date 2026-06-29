# Changelog

All notable changes to this project. Versioning is **date-based** (CalVer
`YYYY.MM.DD`) — each release is stamped with the day it was cut, not a semver
number. The current version also lives in [`VERSION`](VERSION).

> **Multiple releases in one day:** the day's first release is the bare date
> (`2026.06.26`); each subsequent same-day release appends an incrementing micro
> counter starting at `.1` (`2026.06.26.1`, `2026.06.26.2`, …).

---

## Unreleased

### Added

- **Self-healing watchdog (`mc-autoheal`) — automatic recovery from the box64
  "hung but running" crash.** A new `willfarrell/autoheal` container `docker restart`s
  bedrock once its Docker HEALTH goes `unhealthy`. This closes a real gap: when the
  box64 heap-corruption crash kills the server process but leaves the wrapper holding
  PID 1, the container never exits, so `RestartCount` never climbs and the
  `restart: unless-stopped` policy never fires — the server just sits there dead. The
  watchdog is guarded against false positives: bedrock's healthcheck now pins an
  explicit cadence (3 missed game-port pings ≈ 90s before `unhealthy`, never a single
  lag/compaction blip) with a generous `start_period: 180s` so a slow world-load stays
  `starting` rather than tripping a restart, and `just down` removes the container so
  autoheal never fights intentional maintenance.
- **`!restart` / `/restart` — manual server restart from in-game chat or Discord.**
  A human-in-the-loop counterpart to the autoheal watchdog: when the `🔴 SERVER DOWN`
  alert lands, anyone can force a restart without shell access. Abuse-resistant **by
  construction** — the shared `just _restart-request` recipe only restarts when it's
  WARRANTED (the server fails a live `list` probe *or* is Docker-`unhealthy`); a server
  that's actually serving is refused with a friendly "no restart needed", so it can
  never bounce a healthy server people are playing on. A global cooldown
  (`RESTART_COOLDOWN`, default 120s) stops a `/restart` flood from bounce-looping a
  struggling box.
- **`!players` / `/players` (alias `!online` / `/online`).** See who's online from
  in-game chat or Discord. In-game the chat-bridge pack reads the live player list
  straight from the Script API (instant, no host roundtrip); Discord queries the
  running server's `list` via the shared `online_players` parser. Lands in the same
  shared command surface and the `!commands` listing.

### Changed

- **Memory-alert thresholds retuned to cut false alarms.** The high-memory alarm
  default rose from `2500` to `3500` MiB (`MONITOR_MEM_ALERT`) and the repeat-reminder
  cooldown from `600`s to `3600`s (`MONITOR_ALERT_COOLDOWN`). Steady-state with a
  player online sits at ~2.5 GiB and held flat for hours without crashing, so the old
  2.5 GiB early-warning was firing every 10 min on normal working set rather than a
  genuine runaway toward the box64 heap crash. 3.5 GiB still leaves headroom on the
  7.8 GiB host. Defaults updated in `docker-compose.yml`; override either in `.env`.

---

## 2026.06.26.2

The "graceful shutdown & live map" release: lifecycle commands can warn players
before stopping, the map shows who's online, and crash alerts call out
compaction-correlated faults.

### Added

- **Optional pre-shutdown countdown.** Set `SHUTDOWN_COUNTDOWN` (seconds) and
  `down` / `restart` / `recreate` warn online players in-game every 10s
  (60s, 50s, … 10s) before stopping. Off by default; skipped when nobody's
  online (automation never waits for an empty server). Can be set inline for a
  single shutdown. The operator sees the countdown tick down in the terminal,
  and if every player leaves mid-countdown it stops waiting and shuts down at
  once instead of stalling for the full duration.
- **Online-player overlay on the map.** Live `just map` / `!map` / `/map` renders now
  overlay a marker + **gamertag** + live coordinates for every player currently online
  (positions queried from the running server via `online_players.py`). Offline players
  are omitted — the world DB stores no gamertags, so a saved position can't be named.
  Rendering a backup db skips the overlay.

### Changed

- **Crash alert** now flags when a crash lands **during a LevelDB AutoCompaction
  pass** — a common trigger for the box64 heap faults. Makes compaction-correlated
  crashes obvious at a glance (e.g. the idle 15:34 crash that prompted this).

---

## 2026.06.26.1

Justfile audit — trimmed the recipe list (55 → 52 public) and fixed a backup bug.

### Removed

- **`just backup-clean`** — superseded by the automatic rotation that runs after
  every `just backup`. It also kept only the newest 3 and **ignored 🔒 saved
  markers**, so it could delete a snapshot you'd explicitly saved. Use
  `backup-save` / `backup-unsave` + auto-rotation instead.
- **`just crashes`** — its since-boot crash count is already reported by
  `just analyze` (and crash state by `doctor` / the monitor).
- **`just blogs` / `just plogs` / `just bridge-logs`** — folded into one
  parametrized recipe (below).

### Changed

- **`just logs [service]`** now follows all services by default, or a single one:
  `just logs bedrock` · `just logs playit` · `just logs monitor` · `just logs bridge`.
- **`just notify`** (foreground watcher) renamed to **`just notify-run`** for
  symmetry with `bot-run`. The `notify-install` / `-uninstall` / `-running` agent
  recipes are unchanged.
- **`just clean`** no longer references a scratch dir (`_inspect_db`) that was
  never created.

### Added

- **`just notify-logs`** and **`just uptime-logs`** — tail those agents' logs,
  matching the existing `bot-logs`.

---

## 2026.06.26

The "commands & map" release: in-game and Discord now share a command surface,
the world can render itself to a picture, and backups self-rotate.

### Added

- **Shared command surface — `!cmd` in-game *and* `/cmd` (or `!cmd`) in Discord.**
  Both front-ends route to the same host-side recipes, so behaviour and
  rate-limits are identical wherever you type:
  - `!commands` — list available commands.
  - `!coords [player]` — report a player's coordinates (in Discord you pass the
    target, since there's no Discord↔Minecraft identity mapping).
  - `!backup` — trigger a snapshot, **rate-limited to one per requester every
    `BACKUP_COOLDOWN` (default 10 min)** and globally lock-guarded.
  - `!doctor` — run the health report (see below) and reply with a compact line.
  - `!map` — render the overworld and post it to `#map` (rate-limited per
    requester via `MAP_COOLDOWN`, default 5 min).
  - `!mail <player> <message>` / `!shrug` — in-game mailbox (delivered on the
    recipient's next join) and a bit of fun.
- **Discord native slash commands.** `/map`, `/backup`, `/doctor`, `/coords`,
  `/mail`, `/shrug` are registered with Discord's `/` picker (guild-scoped sync,
  instant). The `!` prefix remains fully intact alongside them.
- **World map renderer (`just map`).** Reads the live world's LevelDB in a
  throwaway `mc-tools` container, extracts a surface heightmap, and renders a
  north-up, hill-shaded terrain PNG on the host (`scripts/export_heightmap.py` +
  `scripts/render_map.py`). `!map` / `/map` post it straight to `#map`.
- **`just doctor`** (`scripts/doctor.sh`) — one-shot health report: container
  status, health-check state, restart counts, CPU/mem, disk headroom, and
  configured webhook count. `--brief` prints a single compact line (used by the
  `!doctor` / `/doctor` replies).
- **Backup rotation.** After every `just backup`, `_rotate-backups` keeps the
  newest `BACKUP_KEEP` (default 10) **unsaved** snapshots and prunes older ones.
  Mark a snapshot to keep forever with `just backup-save <name>` (🔒, exempt from
  rotation and from the count); undo with `just backup-unsave <name>`.
- **`VERSION` + this `CHANGELOG.md`.**

### Changed

- **Crash alerting is now fully automated.** The monitor detects the box64
  heap-corruption crash family via the container's `RestartCount` (survives
  container replacement, unlike a log tail) and publishes a `CRASH` alert to
  `#server-status`; log archival also scans for the cause. No manual posting.
- **`just backups`** now shows 🔒 markers and the active keep-count.
- **`.env` / `.env.example`** gained `DISCORD_WEBHOOK_MAP`, `MAP_CHANNEL_ID`, and
  a tuning block (`BACKUP_KEEP`, `BACKUP_COOLDOWN`, `MAP_COOLDOWN`), each with the
  WHAT / WHY / GET documentation style used throughout.

### Data protection

- Identifiable data (gamertags, account IDs, the real world name) is kept out of
  every committable file. Map/player exports use **opaque short ids, not
  gamertags**, and the generated `world-map.png` is gitignored (it renders the
  real world). Real values live only in gitignored files (`.env`, local notes).

---

## Earlier

See the git history before `2026.06.26` for the foundational layers:

- **`just setup` wizard** (Go/Bubbletea) + README rewrite.
- **Two-way Discord ↔ Minecraft chat**, decoupled notifier, reconcile hardening.
- **UK-time uptime graphs** (healthchecks.io-driven status strip) + monitoring.
- **Notifications, safety guards, backups, and the playit-tunnelled Docker stack.**
