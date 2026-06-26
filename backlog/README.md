# Backlog

A lightweight kanban for this server's features. Each feature is a single `.md` file
that **moves between folders** as it progresses — no tool, no board, just `git mv`.

```
backlog/
├── pending/       ← agreed, not started   (full plan + task list inside)
├── in-progress/   ← actively being built  (tick the task list as you go)
├── completed/     ← shipped               (kept as a record)
└── ideas/         ← raw brainstorm bucket  (promote to pending/ when you commit to one)
```

**Workflow**
1. Brainstorm freely in `ideas/` (grouped by theme, many per file).
2. When you decide to build one, pull it into its own file in `pending/` with a real
   implementation plan + task checklist.
3. `git mv backlog/pending/<x>.md backlog/in-progress/` when you start; tick `- [ ]` → `- [x]`.
4. `git mv` to `completed/` when it ships.

## Currently pending
- [auto-backup-on-leave](pending/auto-backup-on-leave.md) — snapshot the world when players leave (flag-gated)
- [discord-slash-commands](pending/discord-slash-commands.md) — `/ping`, `/status`, `/restart`, … from Discord

## Ideas bucket
See [`ideas/`](ideas/) — ~50 ideas across Discord, gameplay, monitoring, world/backups,
community, and ops. Promote any to `pending/` when you want to build it.
