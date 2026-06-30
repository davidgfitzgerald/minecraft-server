#!/usr/bin/env python3
"""Extract every player's last-known position from the world LevelDB → JSON.

Each player profile (`player_server_*`) is an uncompressed little-endian NBT record
carrying a `Pos` ([x,y,z]) and `DimensionId` — the LAST SAVED position, which covers
OFFLINE players (and online ones too, lagging live by up to one autosave).

The world DB stores no gamertags, so we attach them from the gitignored map at
/player-map.json (gamertag → ServerId or account uniqueId). Records we can name get the
real gamertag and `named: true`; the rest fall back to a short opaque id. Every entry is
flagged `online: false` here — the host merge (players_overlay.py) overlays live online
players on top. The `~local_player` host record is skipped (it's not a real player).

    python3 export_players.py [out.json]      # default: /out/players.json

Runs in the mc-tools container; render_map.py overlays the result on the map.
"""
import json
import sys

from bedrock_nbt import open_db, parse_le_nbt


def _pos(d):
    p = d.get("Pos")
    if isinstance(p, (list, tuple)) and len(p) == 3:
        try:
            return [float(p[0]), float(p[1]), float(p[2])]
        except (TypeError, ValueError):
            return None
    return None


def _resolve_server_key(db, val):
    """A player-map value → its player_server_ record key. Accepts a player_server_<uuid>
    key directly, or an account uniqueId whose player_<uniqueId> record names the ServerId."""
    if val.startswith("player_server_"):
        return val
    acct = db.get(("player_" + val).encode())
    if acct is not None:
        try:
            sid = parse_le_nbt(acct).get("ServerId")
        except Exception:
            sid = None
        if isinstance(sid, str) and sid.startswith("player_server_"):
            return sid
    return "player_server_" + val


def _name_map(db):
    """server_key → gamertag, inverted from /player-map.json (best-effort)."""
    try:
        m = json.load(open("/player-map.json"))
    except Exception:
        return {}
    out = {}
    for gt, val in m.items():
        try:
            out[_resolve_server_key(db, val)] = gt
        except Exception:
            continue
    return out


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/out/players.json"
    db = open_db()
    names = _name_map(db)
    players = []
    for k in sorted(k for k in db.keys() if k.startswith(b"player_server_")):
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
        gamertag = names.get(kid)
        label = gamertag if gamertag else kid.replace("player_server_", "")[:6]
        dim = d.get("DimensionId", 0)
        players.append({
            "id": label,
            "dim": int(dim) if isinstance(dim, (int, float)) else 0,
            "pos": pos,
            "online": False,
            "named": bool(gamertag),
        })
    with open(out_path, "w") as f:
        json.dump(players, f)
    print(f"exported {len(players)} player position(s) "
          f"({sum(1 for p in players if p['named'])} named) → {out_path}")


if __name__ == "__main__":
    main()
