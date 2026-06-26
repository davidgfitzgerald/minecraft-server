# Ideas — Discord & notifications

Raw brainstorm. Promote any to `../pending/` to commit to building it.

1. **Rich join/leave embeds** — replace plain `#player-activity` text with Discord embeds
   (player avatar from their gamertag, session length on leave, current online count).
2. **"Who's online" live message** — one pinned message in `#server-status` the bot edits
   in place every minute, instead of spamming new lines.
3. **First-join-of-the-day shout** — special message the first time anyone logs in each
   day ("🌅 server's alive — Steve is on").
4. **@mention on empty→occupied** — ping a role when the server goes from 0 → 1 player so
   friends know it's worth hopping on.
5. **Crash thread auto-create** — on a crash alert, open a Discord thread with the tail of
   the crash log attached, so each incident has its own discussion space.
6. **Daily recap embed** — extend the uptime graph post with a leaderboard (most time
   online, most joins) pulled from `monitoring/events.csv`.
7. **Death / advancement feed** — relay in-game death messages and advancements to a
   `#highlights` channel via the chat-bridge pack.
8. **Quiet hours** — suppress non-urgent notifications overnight (configurable window),
   still letting crash/down alerts through.
9. **Notification digest mode** — batch low-priority events into a single message every N
   minutes instead of one-per-event, to cut channel noise.
