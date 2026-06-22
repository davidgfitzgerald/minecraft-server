"""Full audit of every key in the world LevelDB. Lists all printable/named keys
(where player data lives) and counts the binary chunk keys. Also flags ANY key
whose NBT contains PlayerLevel/Inventory, regardless of its name — so a player
stored under an unexpected key can't hide."""
import logging

from bedrock_nbt import configure_logging, open_db, parse_le_nbt

log = logging.getLogger("audit_keys")


def main():
    configure_logging("audit_keys")
    db = open_db()

    total = 0
    named = []
    binary = 0
    player_like = []
    for k in db.keys():
        total += 1
        is_named = False
        try:
            s = k.decode("ascii")
            if s.isprintable():
                is_named = True
        except Exception:
            pass
        if is_named:
            named.append((s, len(db.get(k))))
        else:
            binary += 1
        # detect a player record under ANY key
        try:
            d = parse_le_nbt(db.get(k))
            if isinstance(d, dict) and ("PlayerLevel" in d or ("Inventory" in d and "Armor" in d)):
                n_items = sum(1 for it in (d.get("Inventory") or [])
                              if isinstance(it, dict) and it.get("Name") not in (None, "minecraft:air"))
                keyrepr = s if is_named else k.hex()
                player_like.append((keyrepr, d.get("PlayerLevel", "?"), n_items))
        except Exception:
            pass

    print(f"TOTAL KEYS: {total}  | named/printable: {len(named)}  | binary(chunk) keys: {binary}")
    print("\n=== ALL NAMED KEYS (this is where any player data would be) ===")
    for s, sz in sorted(named):
        print(f"  {s}   ({sz} bytes)")
    print("\n=== EVERY key that parses as a PLAYER record (level / item count) — by ANY key name ===")
    for kr, lvl, ni in sorted(player_like, key=lambda x: -(x[1] if isinstance(x[1], int) else 0)):
        print(f"  level={lvl:<3} items={ni:<3} key={kr}")
    print(f"\nplayer-record keys found: {len(player_like)}")
    log.info("done — %d keys total (%d named, %d chunk), %d player records",
             total, len(named), binary, len(player_like))


if __name__ == "__main__":
    main()
