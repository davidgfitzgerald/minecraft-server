# Ideas — 50 chat/bot commands

Command ideas usable from **in-game chat** (`!cmd`) and **Discord**. Legend:
`🧑` = acts on the caller → from Discord you must pass `<player>` (no clean Discord→gamertag map);
`🛡️` = should be gated to admins/allow-list eventually; the rest are open.

Built already: `!commands`, `!coords` 🧑, `!backup` 🛡️-ish (rate-limited), `!doctor`, `!shrug`, `!mail` 🧑.

## Info & status
1. `!online` — who's connected + count.
2. `!players` — count / max slots.
3. `!ping` — bot + server alive, gateway latency.
4. `!status` — one-line health (alias of `!doctor --brief`).
5. `!uptime` — how long the server's been up.
6. `!version` — Bedrock server version.
7. `!seed` — world seed.
8. `!tps` — tick health (Bedrock has no native TPS — must be derived).
9. `!whereis <player>` 🧑 — another player's coords.
10. `!motd` — show the message of the day.

## Movement & location 🧑 (mostly)
11. `!home` 🧑 — teleport to your saved home.
12. `!sethome` 🧑 — save your current spot as home.
13. `!back` 🧑 — return to your last position / death.
14. `!spawn` — show (or tp to) world spawn.
15. `!warp <name>` 🧑 — tp to a named warp.
16. `!setwarp <name>` 🛡️ — create a warp.
17. `!warps` — list warps.
18. `!top` 🧑 — tp to the highest block above you.
19. `!deathloc` 🧑 — your last death coordinates.
20. `!distance <player>` 🧑 — distance between you and them.

## World & environment
21. `!time` — current in-game time.
22. `!settime <day|night>` 🛡️ — set time.
23. `!weather` — current weather.
24. `!setweather <clear|rain>` 🛡️ — set weather.
25. `!difficulty` — show difficulty.
26. `!worldborder` — show border info.
27. `!daycount` — in-game day number.

## Stats & social
28. `!playtime` 🧑 — your total time online.
29. `!leaderboard` — playtime ranking.
30. `!joins` 🧑 — your join count.
31. `!streak` 🧑 — your login streak.
32. `!firstseen <player>` 🧑 — when they first joined.
33. `!lastseen <player>` 🧑 — when they were last online.
34. `!rank` 🧑 — your role/rank.

## Comms
35. `!mailbox` 🧑 — read your pending mail.
36. `!msg <player> <text>` 🧑 — private message an online player.
37. `!shout <text>` 🛡️ — broadcast a server-wide message.
38. `!discord` — show the Discord invite link in-game.
39. `!me <action>` — emote ("* Steve waves").
40. `!poll <question>` — start a quick reaction poll.

## Fun & novelty
41. `!roll <n>` — dice roll (1–n).
42. `!flip` — coin flip.
43. `!8ball <question>` — magic 8-ball.
44. `!slap <player>` 🧑 — fun broadcast ("Steve slaps Alex with a trout").
45. `!quote` — random server quote / lore line.
46. `!hug <player>` 🧑 — wholesome broadcast.
47. `!dance` — broadcast a little dance emote.

## Admin / ops 🛡️
48. `!restart` 🛡️ — restart the server (guarded + confirm).
49. `!save` 🛡️ — force a world save (`save hold`/`resume`).
50. `!backups` 🛡️ — list recent snapshots (newest first, 🔒 saved marked).
