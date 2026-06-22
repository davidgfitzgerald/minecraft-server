"""Inspect ONE chunk's integrity on disk. Set CHUNK_X / CHUNK_Z (chunk coords).
Reports the tags present, subchunk validity, version, and neighbour completeness —
to tell a genuinely broken/missing chunk from a healthy one (i.e. a client-side glitch)."""
import os
import struct

from bedrock_nbt import configure_logging, open_db

T_SUBCHUNK = 0x2F
VERSION_TAGS = {0x2C, 0x76}
TAG_NAME = {0x2B: "Data3D", 0x2C: "Version", 0x2D: "Data2D", 0x2E: "Data2DLegacy",
            0x2F: "SubChunk", 0x30: "LegacyTerrain", 0x31: "BlockEntity", 0x32: "Entity",
            0x33: "PendingTicks", 0x35: "BiomeState", 0x36: "FinalizedState",
            0x39: "HardSpawnAreas", 0x3A: "RandomTicks", 0x3B: "CheckSums", 0x76: "Version(legacy)"}
SUB_OK = {1, 8, 9}


def chunk_keys(db, cx, cz):
    """All overworld record keys (9/10 byte) for chunk (cx,cz)."""
    prefix = struct.pack("<ii", cx, cz)
    out = []
    for k in db.keys():
        if k.startswith(prefix) and len(k) in (9, 10):
            out.append(k)
    return out


def complete(db, cx, cz):
    prefix = struct.pack("<ii", cx, cz)
    has_sub = has_ver = False
    for k in db.keys():
        if k.startswith(prefix) and len(k) in (9, 10):
            if k[8] == T_SUBCHUNK:
                has_sub = True
            if k[8] in VERSION_TAGS:
                has_ver = True
    return has_sub and has_ver


def main():
    log = configure_logging("check_chunk")
    cx = int(os.environ.get("CHUNK_X", "-58"))
    cz = int(os.environ.get("CHUNK_Z", "-5"))
    db = open_db()

    keys = chunk_keys(db, cx, cz)
    print(f"\n=== chunk ({cx},{cz})  blocks X {cx*16}..{cx*16+15}  Z {cz*16}..{cz*16+15} ===")
    if not keys:
        print("  NO KEYS — chunk is absent on disk (ungenerated / a hole).")
    tags, bad = {}, []
    for k in keys:
        tag = k[8]
        suby = struct.unpack_from("<b", k, 9)[0] if len(k) == 10 else None
        tags.setdefault(tag, []).append(suby)
        if tag == T_SUBCHUNK:
            v = db.get(k)
            if not v or v[0] not in SUB_OK:
                bad.append((suby, "empty" if not v else f"bad storage-version {v[0]}"))
    print("  tags present: " + ", ".join(f"{TAG_NAME.get(t, hex(t))}"
          + (f"×{len(tags[t])}" if t == T_SUBCHUNK else "") for t in sorted(tags)))
    has_sub = T_SUBCHUNK in tags
    has_ver = bool(VERSION_TAGS & set(tags))
    print(f"  subchunks: {len(tags.get(T_SUBCHUNK, []))}   version key: {has_ver}   "
          f"finalized: {0x36 in tags}")
    if bad:
        print(f"  ⚠️ CORRUPT subchunks: {bad}")
    verdict = ("HEALTHY (complete: terrain + version present)" if has_sub and has_ver and not bad
               else "ABSENT" if not keys
               else "SUSPECT")
    print(f"  VERDICT: {verdict}")

    print("\n  neighbours (complete = generated terrain + version):")
    for dz in (1, 0, -1):
        row = ""
        for dx in (-1, 0, 1):
            if dx == 0 and dz == 0:
                row += "  [self] "
            else:
                row += "  ✅    " if complete(db, cx + dx, cz + dz) else "  ❌    "
        print("   " + row)
    log.info("done — chunk (%d,%d): %s", cx, cz, verdict)


if __name__ == "__main__":
    main()
