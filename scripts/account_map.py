"""Dump the account -> profile mapping records (MsaId / PlatformOnlineId / ServerId)
from the world LevelDB."""
import logging

from bedrock_nbt import configure_logging, open_db, parse_le_nbt

log = logging.getLogger("account_map")


def main():
    configure_logging("account_map")
    db = open_db()
    n = 0
    print("=== account -> profile mapping records ===")
    for k in sorted(db.keys()):
        if k.startswith(b"player_") and not k.startswith(b"player_server_"):
            keyname = k.decode("utf-8", "replace")
            try:
                d = parse_le_nbt(db.get(k))
                scal = {kk: vv for kk, vv in d.items() if isinstance(vv, (int, float, str))}
                print(f"\nKEY: {keyname}")
                print("   ", scal)
                n += 1
            except Exception as e:
                print(f"\nKEY: {keyname}  parse error {e}")
    log.info("done — %d account-mapping records", n)


if __name__ == "__main__":
    main()
