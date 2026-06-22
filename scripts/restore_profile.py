"""Restore the destination profile from the snapshot taken by apply_profile.py.
Server MUST be stopped first.

Env vars:
  DST_KEY  destination player_server_<uuid> key to restore
Reads /out/_profile_orig.nbt (created on the first apply_profile.py run).
"""
import logging
import os

from bedrock_nbt import configure_logging, open_db

log = logging.getLogger("restore_profile")


def main():
    configure_logging("restore_profile")
    dst = os.environ["DST_KEY"].encode()
    bpath = "/out/_profile_orig.nbt"
    if not os.path.exists(bpath):
        raise SystemExit(f"no snapshot at {bpath} — nothing to restore")
    val = open(bpath, "rb").read()
    log.info("restoring %s from %s (%d bytes)", dst.decode(), bpath, len(val))
    db = open_db()
    db.put(dst, val)
    db.close()
    log.info("done")


if __name__ == "__main__":
    main()
