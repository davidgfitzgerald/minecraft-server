"""Copy one player's full saved data (inventory + armor + XP + enchants + position)
onto another player's profile key. The server MUST be stopped first (the world
LevelDB cannot be open in two processes).

Env vars:
  SRC_KEY  source player_server_<uuid> key to copy FROM
  DST_KEY  destination player_server_<uuid> key to overwrite

The first run snapshots the destination to /out/_profile_orig.nbt so it can be
restored later (see restore_profile.py / README).
"""
import logging
import os

from bedrock_nbt import configure_logging, open_db

log = logging.getLogger("apply_profile")


def main():
    configure_logging("apply_profile")
    src = os.environ["SRC_KEY"].encode()
    dst = os.environ["DST_KEY"].encode()
    log.info("SRC=%s  DST=%s", src.decode(), dst.decode())
    db = open_db()

    bpath = "/out/_profile_orig.nbt"
    if not os.path.exists(bpath):
        try:
            cur = db.get(dst)
            open(bpath, "wb").write(cur)
            log.info("saved original destination profile -> %s (%d bytes)", bpath, len(cur))
        except Exception as e:
            log.warning("no existing destination to snapshot: %s", e)

    val = db.get(src)
    db.put(dst, val)
    v2 = db.get(dst)
    log.info("applied %s -> %s: %d bytes, verified=%s", src.decode(), dst.decode(), len(val), v2 == val)
    db.close()


if __name__ == "__main__":
    main()
