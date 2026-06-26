# Changelog

All notable changes to this project. Versioning is **date-based** (CalVer
`YYYY.MM.DD`) — each release is stamped with the day it was cut, not a semver
number. The current version also lives in [`VERSION`](VERSION).

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
