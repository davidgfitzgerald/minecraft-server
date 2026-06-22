"""Full player-profiles report: inventory / armor / XP / enchantments for every
character in the world LevelDB. Prints the report to stdout; logs go to stderr
(via bedrock_nbt.configure_logging) so the report stays clean when redirected."""
import logging

from bedrock_nbt import (build_account_map, configure_logging, fmt_item,
                         list_container, open_db, parse_le_nbt, ARMOR_NAMES)

log = logging.getLogger("profile_report")


def report(db, acct, title, key):
    d = parse_le_nbt(db.get(key))
    lvl = d.get("PlayerLevel", 0)
    prog = d.get("PlayerLevelProgress", 0.0)
    print(f"\n## {title}")
    ids = acct.get(key.decode("utf-8", "replace")) if key.startswith(b"player_server_") else None
    if ids:
        print(f"- **Account:** PlatformOnlineId=`{ids.get('PlatformOnlineId','-')}`  MsaId=`{ids.get('MsaId','-')}`")
    print(f"- **XP level:** {lvl}   (progress {round(prog*100)}% to next)")
    inv = list_container(d, "Inventory")
    armlines = []
    for i, slot in enumerate(d.get("Armor") or []):
        line = fmt_item(slot)
        if line:
            nm = ARMOR_NAMES[i] if i < len(ARMOR_NAMES) else f"slot{i}"
            armlines.append(f"{nm}: {line.split(': ', 1)[-1]}")
    off = list_container(d, "Offhand")
    ench_chest = list_container(d, "EnderChestInventory")
    print("- **Armor:** " + ("; ".join(armlines) if armlines else "(none)"))
    if off:
        print("- **Offhand:** " + "; ".join(o.split(': ', 1)[-1] for o in off))
    print(f"- **Inventory ({len(inv)} items):**")
    if inv:
        print("```")
        for line in inv:
            print(line)
        print("```")
    else:
        print("  (empty)")
    if ench_chest:
        print(f"- **Ender chest ({len(ench_chest)} items):**")
        print("```")
        for line in ench_chest:
            print(line)
        print("```")


def main():
    configure_logging("profile_report")
    db = open_db()
    acct = build_account_map(db)
    profiles = sorted(k for k in db.keys() if k.startswith(b"player_server_"))
    log.info("opened world db: %d player_server profiles, %d account-mapping entries",
             len(profiles), len(acct))
    print("# Player Profiles Report")
    print("\nFull inventory / armor / XP for every character stored in the world.\n")
    report(db, acct, "~local_player  (original host character)", b"~local_player")
    for k in profiles:
        report(db, acct, k.decode("utf-8", "replace"), k)
    log.info("done — reported %d profiles (+ ~local_player)", len(profiles))


if __name__ == "__main__":
    main()
