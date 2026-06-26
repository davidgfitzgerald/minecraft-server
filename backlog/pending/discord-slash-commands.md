# Discord bot slash commands (`/ping`, `/restart`, …)

**Status:** ⏳ Pending

Add Discord application (slash) commands to the existing bot so the server can be
operated from Discord, not just the terminal.

## Where it hooks in
- The bot is `scripts/chat-bot.py` (discord.py, connected via `CHAT_BOT_TOKEN`; runs
  permanently as the `com.mcserver.chatbot` launchd agent **on the host** — so it can
  already shell out to `docker`/`just`, the same way it runs `docker exec bedrock
  send-command` for chat injection).
- Use discord.py `app_commands` (a slash-command tree), synced to the guild on startup.

## Proposed commands
- `/ping` — bot gateway latency + server liveness (`docker inspect` running/health).
- `/status` — players online, uptime, last crash/restart count, tunnel up/down.
- `/list` — current online players (proxies the in-game `list`).
- `/say <msg>` — broadcast to in-game chat (reuse the `scripts/chat-relay.sh` path).
- `/backup` — trigger `just backup` on demand.
- `/restart` — restart the server (see below).

## `/restart` — let Discord users restart the server
Goal: anyone in the channel (initially unrestricted) can bounce the server when it's
stuck, without terminal access.

- On invoke: ack within Discord's 3s window ("restarting…"), run the restart on the host
  (`just restart` / `docker compose restart bedrock`), then edit the reply with the result.
- **Players-online guard:** `scripts/guard.sh` currently *blocks* restarts while players
  are online (the [[server-safety-guards]] guard + Claude hook). A user `/restart` is the
  "I'm stuck, bounce it" case — so warn-and-confirm ("2 players online — restart anyway?
  react ✅") or expose `/restart force`. **Don't silently bypass the guard.**
- **Rate-limit:** cooldown (one restart per N min) so it can't be spammed.
- **Audit:** post "🔄 <user> restarted the server via Discord" to `#server-status`
  (existing `alert` category → `DISCORD_WEBHOOK_SERVER_STATUS`).
- **Auth (later):** start unrestricted as requested; leave a hook to gate by Discord role
  or an allow-list (mirror the `ALLOW_LIST_USERS` convention) once proven.

## Implementation plan
- [ ] Add `discord.app_commands` tree to `chat-bot.py`; sync to the guild in `on_ready`
- [ ] Implement `/ping` (gateway latency + `docker inspect` running/health)
- [ ] Implement `/status` (players, uptime, restart count, tunnel)
- [ ] Implement `/list` (online players via `send-command list` + log scrape)
- [ ] Implement `/say <msg>` (reuse `chat-relay.sh` / in-game broadcast)
- [ ] Implement `/backup` (shell out to `just backup`, report result)
- [ ] Implement `/restart`: deferred ack → run restart → edit reply with outcome
- [ ] Wire `/restart` through `guard.sh`; add confirm flow + `/restart force`
- [ ] Add restart cooldown + `#server-status` audit post
- [ ] Confirm long-running shell-outs don't block the discord.py event loop (use a thread/executor)
- [ ] Register/sync commands; smoke-test each in the guild
- [ ] (Later) role / allow-list gating for `/restart`
- [ ] Document the commands + permissions in `README.md`

## Done when
The listed slash commands work in the guild, `/restart` safely bounces the server with a
confirm-or-force path and an audit line, and nothing blocks the bot's gateway loop.
