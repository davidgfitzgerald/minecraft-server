# Ideas — Ops & tooling

Raw brainstorm. Promote any to `../pending/` to commit to building it.

44. **Version pinning + update notifier** — alert when `itzg/minecraft-bedrock-server`
    pulls a new Bedrock version (currently `VERSION: LATEST`), so a breaking update doesn't
    surprise you. Optionally pin and update on command.
45. **Native x86 host migration** — track the real fix for the box64 heap crash: run the
    x86 Bedrock server on native x86 hardware (cloud VM / mini PC) instead of emulation.
46. **`just doctor`** — one command that checks every moving part (containers, tunnel,
    webhooks, launchd agents, disk, .env completeness) and prints a green/red report.
47. **Secret rotation helper** — `just rotate-webhooks` to swap Discord webhook URLs and
    the playit key across `.env` + the chat-bridge pack in one step.
48. **Config drift check** — warn when `docker-compose.yml` changed but the stack hasn't
    been `just recreate`d to apply it.
49. **Resource auto-tuning** — suggest (or apply) `VIEW_DISTANCE` / memory tweaks based on
    observed peak player count and crash history.
50. **Self-test on boot** — after `just up`, automatically run a synthetic join probe +
    webhook ping and report "all systems go" (or what failed) to `#server-status`.
