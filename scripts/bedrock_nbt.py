"""Shared helpers for reading/inspecting the Bedrock world LevelDB.

Imported by profile_report.py / account_map.py / audit_keys.py. These run inside a
python:3.11 container with `amulet-leveldb` installed; the whole scripts/ dir is
mounted so this module sits next to its importers (see the Justfile `_amulet` recipe).

Bedrock player records are little-endian, uncompressed NBT — `parse_le_nbt` decodes
them directly (no external NBT library needed).
"""
import logging
import struct

from leveldb import LevelDB

# Bedrock enchantment id -> name
ENCH = {0: "protection", 1: "fire_protection", 2: "feather_falling", 3: "blast_protection",
4: "projectile_protection", 5: "thorns", 6: "respiration", 7: "depth_strider", 8: "aqua_affinity",
9: "sharpness", 10: "smite", 11: "bane_of_arthropods", 12: "knockback", 13: "fire_aspect", 14: "looting",
15: "efficiency", 16: "silk_touch", 17: "unbreaking", 18: "fortune", 19: "power", 20: "punch", 21: "flame",
22: "infinity", 23: "luck_of_the_sea", 24: "lure", 25: "frost_walker", 26: "mending", 27: "curse_binding",
28: "curse_vanishing", 29: "impaling", 30: "riptide", 31: "loyalty", 32: "channeling", 33: "multishot",
34: "piercing", 35: "quick_charge", 36: "soul_speed", 37: "swift_sneak", 38: "wind_burst", 39: "density", 40: "breach"}

ARMOR_NAMES = ["head", "chest", "legs", "feet"]


def configure_logging(name):
    """Set up stderr logging (keeps stdout clean for reports) and log the invocation."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
    log = logging.getLogger(name)
    log.info("invoked %s.py", name)
    return log


def open_db(path="/db"):
    """Open the world LevelDB read-only-ish (no create)."""
    return LevelDB(path, create_if_missing=False)


def parse_le_nbt(data):
    """Decode one little-endian, uncompressed Bedrock NBT blob into native Python."""
    pos = 0
    def u8():
        nonlocal pos; v = data[pos]; pos += 1; return v
    def i8():
        nonlocal pos; v = struct.unpack_from('<b', data, pos)[0]; pos += 1; return v
    def i16():
        nonlocal pos; v = struct.unpack_from('<h', data, pos)[0]; pos += 2; return v
    def u16():
        nonlocal pos; v = struct.unpack_from('<H', data, pos)[0]; pos += 2; return v
    def i32():
        nonlocal pos; v = struct.unpack_from('<i', data, pos)[0]; pos += 4; return v
    def i64():
        nonlocal pos; v = struct.unpack_from('<q', data, pos)[0]; pos += 8; return v
    def f32():
        nonlocal pos; v = struct.unpack_from('<f', data, pos)[0]; pos += 4; return v
    def f64():
        nonlocal pos; v = struct.unpack_from('<d', data, pos)[0]; pos += 8; return v
    def s():
        nonlocal pos; n = u16(); b = data[pos:pos+n]; pos += n; return b.decode('utf-8', 'replace')
    def payload(t):
        nonlocal pos
        if t == 1: return i8()
        if t == 2: return i16()
        if t == 3: return i32()
        if t == 4: return i64()
        if t == 5: return f32()
        if t == 6: return f64()
        if t == 7:
            n = i32(); v = list(data[pos:pos+n]); pos += n; return v
        if t == 8: return s()
        if t == 9:
            et = u8(); n = i32()
            return [] if et == 0 else [payload(et) for _ in range(n)]
        if t == 10:
            d = {}
            while True:
                tt = u8()
                if tt == 0: break
                nm = s(); d[nm] = payload(tt)
            return d
        if t == 11:
            n = i32(); return [i32() for _ in range(n)]
        if t == 12:
            n = i32(); return [i64() for _ in range(n)]
        raise ValueError(f"bad tag {t}")
    t = u8(); _ = s(); return payload(t)


def fmt_item(slot):
    """Format one inventory/armor slot dict as a human line, or None if empty/air."""
    if not isinstance(slot, dict):
        return None
    name = slot.get("Name")
    if not name or name == "minecraft:air":
        return None
    name = name.replace("minecraft:", "")
    parts = [f"{name} x{slot.get('Count','?')}"]
    dmg = slot.get("Damage")
    if dmg:
        parts.append(f"dmg={dmg}")
    tag = slot.get("tag")
    if isinstance(tag, dict):
        ench = tag.get("ench")
        if isinstance(ench, list) and ench:
            es = [f"{ENCH.get(e.get('id'), 'ench#'+str(e.get('id')))} {e.get('lvl')}" for e in ench if isinstance(e, dict)]
            if es:
                parts.append("ENCH[" + ", ".join(es) + "]")
        disp = tag.get("display")
        if isinstance(disp, dict) and disp.get("Name"):
            parts.append(f'named "{disp.get("Name")}"')
    sn = slot.get("Slot")
    return (f"slot {sn:>2}: " if sn is not None else "         ") + "  ".join(parts)


def list_container(d, key):
    """Return formatted non-empty item lines for the container `key` in player NBT `d`."""
    out = []
    for slot in (d.get(key) or []):
        line = fmt_item(slot)
        if line:
            out.append(line)
    return out


def build_account_map(db):
    """Map each `player_server_<uuid>` ServerId -> {MsaId, PlatformOnlineId, ...}."""
    acct = {}
    for k in db.keys():
        if k.startswith(b"player_") and not k.startswith(b"player_server_"):
            try:
                d = parse_le_nbt(db.get(k))
                sid = d.get("ServerId")
                if sid:
                    acct.setdefault(sid, {})
                    for f in ("MsaId", "SelfSignedId", "PlatformOnlineId", "PlatformOfflineId"):
                        if d.get(f):
                            acct[sid][f] = d.get(f)
            except Exception:
                pass
    return acct
