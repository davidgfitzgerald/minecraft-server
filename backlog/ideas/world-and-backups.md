# Ideas — World & backups

Raw brainstorm. Promote any to `../pending/` to commit to building it.

28. **Off-site backup sync** — push world snapshots to cloud storage (S3 / rclone /
    Backblaze) so a dead laptop doesn't lose the world.
29. **Backup retention policy** — keep N dailies + N weeklies, auto-prune the rest, report
    what was pruned to `#backups`.
30. **One-command restore** — `just restore <snapshot>` that safely stops, swaps in a
    snapshot, and brings the server back (with a guard + confirm).
31. **Backup integrity check** — verify each snapshot opens (db file count / size sanity)
    and flag a corrupt backup immediately.
32. **Scheduled backups** — launchd/cron periodic snapshots independent of player activity,
    complementing the on-leave backup idea.
33. **World map renderer** — periodically render an overhead map (e.g. via an offline
    renderer) and post it to Discord / the status page.
34. **Player inventory snapshots** — periodic per-player NBT snapshots (the repo already has
    `bedrock_nbt.py` / profile tooling) so a griefed inventory can be restored.
35. **Backup-on-command via Discord** — `/backup` slash command that names the snapshot
    after the requester, for "I'm about to do something risky" moments.
