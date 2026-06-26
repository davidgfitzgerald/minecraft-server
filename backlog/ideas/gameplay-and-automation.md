# Ideas — In-game gameplay & automation

Raw brainstorm. Promote any to `../pending/` to commit to building it.

10. **Scheduled day/weather control** — cron a `time set day` / `weather clear` at a set
    hour so the server is always pleasant when people log on.
11. **Welcome kit on first join** — detect a brand-new player and `give` them a starter
    kit + a `tellraw` welcome with the server rules.
12. **In-game `!commands` via chat** — parse chat messages starting with `!` (in the
    chat-bridge pack) for lightweight commands like `!tps`, `!online`, `!coords`.
13. **AFK auto-kick tuning** — make `PLAYER_IDLE_TIMEOUT` schedule-aware (shorter during
    peak, longer overnight) to free slots without booting active builders.
14. **Auto-broadcast tips** — periodic friendly `say` messages (rotating tips / lore) so
    the world feels alive.
15. **Coordinate bookmarks** — `!sethome` / `!home`-style waypoint store persisted on the
    host (Bedrock has no native homes), teleporting via `send-command`.
16. **Auto-difficulty events** — flip to hard + a mob-spawn burst for a timed "blood moon"
    event announced in Discord.
17. **Build-protection backup trigger** — snapshot before running any destructive admin
    command (fill/clone) issued through the bot.
18. **Seasonal world themes** — scripted decorations / mob changes around holidays, toggled
    by a flag.
