#!/usr/bin/env python3
"""Merge OFFLINE saved positions (export_players.py, from the world DB) with LIVE ONLINE
positions (queried from the running server) into one players.json for the map overlay.

Each entry carries an `online` flag so render_map.py can style them differently (online =
bright marker, offline = faint "last seen"). Online players are queried live here for an
up-to-the-second position; any offline record for a player who's currently online is
dropped (by gamertag) so we don't draw both a live dot and a stale one for the same person.

    players_overlay.py --offline <offline.json> --out <players.json>

Runs on the HOST (needs docker for the live query). Stdlib only; reuses online_players.py.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from online_players import online_names, position_of  # noqa: E402


def _arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def main():
    offline_path = _arg("--offline")
    out_path = _arg("--out", "players.json")
    try:
        offline = json.load(open(offline_path)) if offline_path else []
    except Exception:
        offline = []

    # live online players (real gamertags + current position)
    online, online_lc = [], set()
    for name in online_names():
        r = position_of(name)
        if r is None:
            continue
        dim, pos = r
        online.append({"id": name, "dim": dim, "pos": pos, "online": True})
        online_lc.add(name.lower())

    merged = list(online)
    for e in offline:
        # skip the saved dot for anyone we're already drawing live
        if e.get("named") and str(e.get("id", "")).lower() in online_lc:
            continue
        e = dict(e)
        e["online"] = False
        merged.append(e)

    with open(out_path, "w") as f:
        json.dump(merged, f)
    print(f"players_overlay: {len(online)} online + {len(merged) - len(online)} offline "
          f"→ {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
