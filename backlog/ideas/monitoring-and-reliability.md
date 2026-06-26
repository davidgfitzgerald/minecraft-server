# Ideas — Monitoring & reliability

Raw brainstorm. Promote any to `../pending/` to commit to building it.

19. **Crash-loop detector** — if RestartCount climbs N times within M minutes with no
    `Server started.`, escalate to an urgent "needs manual fix" alert (the current
    monitor catches each crash; this catches a *stuck* loop).
20. **Pre-emptive heap-crash restart** — when memory crosses the early-warning threshold
    *and* the server is empty, do a graceful restart to dodge the box64 corruption crash.
21. **Crash-rate dashboard** — track crashes/day over time (from RestartCount deltas) to
    see whether view-distance / version changes actually help.
22. **TPS / tick-time sampling** — scrape tick timing from logs (or a behavior-pack probe)
    and alert on sustained lag, not just CPU%.
23. **Tunnel auto-heal** — on a sustained playit "tunnel down", auto-restart the playit
    container before alerting that friends can't join.
24. **Synthetic join probe** — periodically ping the Bedrock port (RakNet unconnected-ping)
    to confirm it's actually reachable through the tunnel, not just "container up".
25. **Disk-space guard** — alert (and pause auto-backups) when `bedrock-data/` free space
    drops below a threshold, so backups can't fill the disk.
26. **Log anomaly watch** — flag unusual error spikes in the bedrock log (beyond the known
    heap-corruption signature) as a heads-up.
27. **Status page** — tiny static page (served locally or via the tunnel) showing up/down,
    players, and last crash, fed by the monitoring CSVs.
