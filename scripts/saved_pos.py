"""Look up an OFFLINE player's last-saved position from the world LevelDB, via the
gitignored gamertag→ServerId map (mounted at /player-map.json).

The world DB stores no gamertags/XUIDs (Mojang doesn't write them — see the project
notes), so the gamertag→`player_server_<uuid>` link is supplied externally by the map
file. Reads env LOOKUP_GAMERTAG (case-insensitive) and prints ONE status line:
    OK <Dimension> <x> <y> <z>   |   NOMAP   |   NORECORD

Runs in the mc-tools container (amulet-leveldb), same as the other world-data scripts.
"""
import json
import os

from bedrock_nbt import open_db, parse_le_nbt

DIMS = {0: "Overworld", 1: "Nether", 2: "End"}


def _resolve_server_key(db, val):
    """Map a player-map value to its player_server_ record key. Accepts either a
    `player_server_<uuid>` key directly, or an account `uniqueId` (what querytarget /
    the join-capture stores) whose `player_<uniqueId>` account record names the ServerId."""
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
    return "player_server_" + val  # last resort: treat as a bare server uuid


def main():
    gt = (os.environ.get("LOOKUP_GAMERTAG") or "").strip().lower()
    try:
        mapping = json.load(open("/player-map.json"))
    except Exception:
        print("NOMAP")
        return
    # case-insensitive gamertag lookup
    val = next((v for k, v in mapping.items() if k.strip().lower() == gt), None)
    if not val:
        print("NOMAP")
        return

    db = open_db()
    raw = db.get(_resolve_server_key(db, val).encode())
    if raw is None:
        print("NORECORD")
        return
    try:
        d = parse_le_nbt(raw)
        pos = d.get("Pos")
        x, y, z = (round(float(v)) for v in pos)
    except Exception:
        print("NORECORD")
        return
    dim = d.get("DimensionId", 0)
    dim = int(dim) if isinstance(dim, (int, float)) else 0
    print(f"OK {DIMS.get(dim, f'dim{dim}')} {x} {y} {z}")


if __name__ == "__main__":
    main()
