# Auto-backup when a player leaves (flag-toggled)

**Status:** ⏳ Pending
**Flag:** `BACKUP_ON_LEAVE` (default `off`)

Run a world backup automatically on player-leave, gated behind an opt-in flag that
`just setup` can toggle (same pattern as the other feature flags written to `.env`).

## Why
Captures the session's final state without anyone remembering to run `just backup`.
Pairs well with the crash alerting — if the server later dies, the last good world is
already snapshotted.

## Where it hooks in
- `scripts/notify.sh` already tails `docker logs bedrock` and detects leaves (the
  `"Player disconnected"` / ledger `left` branch) — natural trigger point.
- Reuse the existing `just backup` recipe (snapshots the world + posts a summary to
  `#backups` via `DISCORD_WEBHOOK_BACKUP`). Call it async so the watcher never blocks.

## Design decisions to settle first
- **Every leave vs server-empties:** backing up on *every* leave during a busy session =
  overlapping snapshots + disk churn. Strong default: only when the **last** player
  leaves (0 online). Offer both via the flag value: `last` (recommended) vs `always`.
- **Debounce/lock:** lockfile + min-interval (skip if a backup ran in the last N min) to
  avoid pile-ups with a manual `just backup` or a quick re-leave.
- **Crash-safe:** a crash-induced leave (no clean "disconnected") won't fire this — fine,
  crash alerting covers that case separately.

## Implementation plan
- [ ] Add `BACKUP_ON_LEAVE` to `.env.example` with doc comment (values: `off` | `last` | `always`)
- [ ] Add a toggle in the `just setup` wizard (`tools/` Go/Bubbletea) that writes it to `.env`
- [ ] In `scripts/notify.sh` leave branch: read the flag; if enabled, decide whether to fire
- [ ] Implement "last player left" detection (online count reaches 0) for the `last` mode
- [ ] Add a lockfile + min-interval guard (env: `BACKUP_ON_LEAVE_MIN_INTERVAL`, default e.g. 10m)
- [ ] Fire `just backup` in the background (`&` / `nohup`) so the watcher loop keeps tailing
- [ ] Verify the existing `#backups` Discord post still fires from the triggered backup
- [ ] Test: connect + leave a test client; confirm backup runs in `last` and `always` modes
- [ ] Document the flag + behaviour in `README.md`

## Done when
A player leaving (per the chosen mode) produces a world snapshot + `#backups` post, the
flag cleanly turns it on/off via `just setup`, and rapid leaves don't stack backups.
