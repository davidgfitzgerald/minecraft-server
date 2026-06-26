#!/usr/bin/env python3
"""Extract every player's last-known position from the world LevelDB → /out/players.json.

Each player profile (`~local_player` + `player_server_*`) is an uncompressed little-endian
NBT record carrying a `Pos` ([x,y,z]) and `DimensionId`. This is the LAST SAVED position,
so it covers BOTH online and offline players (online ones update on the server's autosave,
so they can lag a live position by up to the autosave interval).

Labels are opaque short ids derived from the record key — NOT gamertags (kept out on
purpose). Runs in the mc-tools container; render_map.py overlays the result on the map.
"""
import json
from bedrock_nbt import open_db, parse_le_nbt


def _pos(d):
    p = d.get("Pos")
    if isinstance(p, (list, tuple)) and len(p) == 3:
        try:
            return [float(p[0]), float(p[1]), float(p[2])]
        except (TypeError, ValueError):
            return None
    return None


def main():
    db = open_db()
    keys = [b"~local_player"] + sorted(k for k in db.keys() if k.startswith(b"player_server_"))
    players = []
    for k in keys:
        v = db.get(k)
        if not v:
            continue
        try:
            d = parse_le_nbt(v)
        except Exception:
            continue
        pos = _pos(d)
        if pos is None:
            continue
        kid = k.decode("utf-8", "replace")
        label = "host" if kid == "~local_player" else kid.replace("player_server_", "")[:6]
        dim = d.get("DimensionId", 0)
        players.append({"id": label, "dim": int(dim) if isinstance(dim, (int, float)) else 0, "pos": pos})
    with open("/out/players.json", "w") as f:
        json.dump(players, f)
    print(f"exported {len(players)} player position(s)")


if __name__ == "__main__":
    main()
