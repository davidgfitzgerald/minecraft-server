"""Chunk-integrity scanner for the Bedrock world LevelDB (READ-ONLY).

Walks every raw key, groups them into chunks by (dimension, chunkX, chunkZ),
and flags chunks that the game engine would fail to load or render correctly —
the classic "glitched chunk that won't load" / void hole / missing-blocks bug.

Bedrock stores a chunk as MANY keys sharing a coordinate prefix, one per data
"tag" (subchunk blocks, heightmap, biomes, version, finalized-state, ...). A
chunk breaks when that set is internally inconsistent, most commonly:
  * block data present but the chunk-VERSION key is missing  -> engine refuses it
  * a subchunk record is truncated / has a bad storage-version byte
  * version/finalized keys present but NO terrain at all      -> void column

Key layout (little-endian):
  overworld : <int cx><int cz>          <tag>[<sbyte subY>]   = 9 or 10 bytes
  nether/end: <int cx><int cz><int dim> <tag>[<sbyte subY>]   = 13 or 14 bytes

Run (against a copy of the live db, safe while server is up):
  just _amulet scripts/scan_chunks.py
Optionally narrow the region with env vars (block coords, inclusive):
  REGION=1500   -> scans chunks within +/-1500 blocks in X and Z (default)
"""
import logging
import os
import struct

from bedrock_nbt import configure_logging, open_db

# --- Bedrock chunk record tags (decimal) -------------------------------------
T_DATA3D = 0x2B          # 43  heightmap + 3D biomes (1.18+)
T_DATA2D = 0x2D          # 45  heightmap + biomes (legacy)
T_DATA2D_LEGACY = 0x2E   # 46
T_SUBCHUNK = 0x2F        # 47  block data, one record per vertical subchunk (+subY)
T_LEGACY_TERRAIN = 0x30  # 48  pre-1.0 whole-column terrain
T_FINALIZED = 0x36       # 54  generation stage (0=needs gen, 1=needs pop, 2=done)
T_VERSION_NEW = 0x2C     # 44  chunk version (current location, 1.16.100+)
T_VERSION_OLD = 0x76     # 118 chunk version (legacy location)

VERSION_TAGS = {T_VERSION_NEW, T_VERSION_OLD}
# every tag we recognise as belonging to a chunk column
CHUNK_TAGS = {0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34,
              0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x76}
TAG_NAME = {0x2B: "Data3D", 0x2C: "Version", 0x2D: "Data2D", 0x2E: "Data2DLegacy",
            0x2F: "SubChunk", 0x30: "LegacyTerrain", 0x31: "BlockEntity",
            0x32: "Entity", 0x33: "PendingTicks", 0x34: "BlockExtra",
            0x35: "BiomeState", 0x36: "FinalizedState", 0x37: "ConversionData",
            0x38: "BorderBlocks", 0x39: "HardSpawnAreas", 0x3A: "RandomTicks",
            0x3B: "CheckSums", 0x76: "Version(legacy)"}
DIM_NAME = {0: "overworld", 1: "nether", 2: "end"}

# valid first byte of a SubChunk record = its storage format version
SUBCHUNK_STORAGE_VERSIONS = {1, 8, 9}


def parse_chunk_key(k):
    """Return (dim, cx, cz, tag, subY) if k is a chunk record key, else None."""
    n = len(k)
    if n in (9, 10):
        cx, cz = struct.unpack_from("<ii", k, 0)
        dim, tag = 0, k[8]
        suby = struct.unpack_from("<b", k, 9)[0] if n == 10 else None
    elif n in (13, 14):
        cx, cz, dim = struct.unpack_from("<iii", k, 0)
        tag = k[12]
        suby = struct.unpack_from("<b", k, 13)[0] if n == 14 else None
    else:
        return None
    if tag not in CHUNK_TAGS or dim not in DIM_NAME:
        return None
    # guard against printable/named keys that happen to be the right length
    if abs(cx) > 2_000_000 or abs(cz) > 2_000_000:
        return None
    return dim, cx, cz, tag, suby


def subchunk_problem(val):
    """Return a short reason string if this SubChunk record looks corrupt, else None."""
    if not val:
        return "empty subchunk record"
    ver = val[0]
    if ver not in SUBCHUNK_STORAGE_VERSIONS:
        return f"bad storage-version byte {ver} (expected 1/8/9)"
    if ver in (8, 9):
        if len(val) < 2:
            return "truncated (no layer count)"
        layers = val[1]
        if layers > 8:                       # sane upper bound on block-storage layers
            return f"implausible layer count {layers}"
    return None


def main():
    log = configure_logging("scan_chunks")
    region = int(os.environ.get("REGION", "1500"))
    cmin, cmax = -(region // 16) - 1, (region // 16) + 1
    log.info("scanning chunks within +/-%d blocks (chunk %d..%d in X and Z)", region, cmin, cmax)

    db = open_db()
    # chunks[(dim,cx,cz)] = {"tags": {tag: [subY,...]}, "bad_sub": [(subY,reason)], "verval": int|None}
    chunks = {}
    skipped_region = 0
    for k in db.keys():
        pk = parse_chunk_key(k)
        if pk is None:
            continue
        dim, cx, cz, tag, suby = pk
        if not (cmin <= cx <= cmax and cmin <= cz <= cmax):
            skipped_region += 1
            continue
        c = chunks.setdefault((dim, cx, cz), {"tags": {}, "bad_sub": [], "verval": None})
        c["tags"].setdefault(tag, []).append(suby)
        if tag == T_SUBCHUNK:
            prob = subchunk_problem(db.get(k))
            if prob:
                c["bad_sub"].append((suby, prob))
        elif tag in VERSION_TAGS:
            v = db.get(k)
            c["verval"] = v[0] if v else None

    log.info("grouped %d chunks in region (%d chunk-keys outside region skipped)",
             len(chunks), skipped_region)

    # --- sanity summary: confirms the scanner reads the right tags ---
    n_ver = sum(1 for c in chunks.values() if VERSION_TAGS & set(c["tags"]))
    n_sub = sum(1 for c in chunks.values() if T_SUBCHUNK in c["tags"])
    n_fin = sum(1 for c in chunks.values() if T_FINALIZED in c["tags"])
    print("\n=== SANITY SUMMARY (should be ~all chunks, else tag-parse is wrong) ===")
    print(f"  chunks with a Version key:     {n_ver}/{len(chunks)}")
    print(f"  chunks with SubChunk terrain:  {n_sub}/{len(chunks)}")
    print(f"  chunks with FinalizedState:    {n_fin}/{len(chunks)}")

    # --- HOLE detection: a chunk absent but boxed in by generated neighbours ---
    # An ungenerated gap inside explored terrain reads in-game as "a chunk that
    # won't load / void hole" even though there is nothing corrupt on disk.
    present = set(chunks.keys())
    # a chunk is "complete" if fully generated (has both version + terrain)
    complete = {key for key, c in chunks.items()
                if (VERSION_TAGS & set(c["tags"])) and T_SUBCHUNK in c["tags"]}
    N8 = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
    holes = []
    by_dim_xs = {}
    for (dim, cx, cz) in present:
        by_dim_xs.setdefault(dim, set()).add((cx, cz))
    for dim, coords in by_dim_xs.items():
        xs = [x for x, _ in coords]; zs = [z for _, z in coords]
        for cx in range(min(xs), max(xs) + 1):
            for cz in range(min(zs), max(zs) + 1):
                if (dim, cx, cz) in present:
                    continue
                # how enclosed is this gap? count neighbours, and how many are COMPLETE
                n_present = sum((dim, cx + dx, cz + dz) in present for dx, dz in N8)
                n_complete = sum((dim, cx + dx, cz + dz) in complete for dx, dz in N8)
                if n_present >= 4:
                    holes.append((n_complete, n_present, dim, cx, cz))
    # rank: most fully-enclosed first = the prime "generation-crash void" suspects
    holes.sort(key=lambda h: (-h[0], -h[1]))
    enclosed = [h for h in holes if h[0] == 8]   # boxed in by 8 COMPLETE chunks
    print(f"\n=== HOLES — {len(holes)} gaps; {len(enclosed)} fully enclosed by 8 complete chunks ===")
    print("(fully-enclosed gaps deep in finished terrain = prime generation-crash suspects)\n")
    for n_complete, n_present, dim, cx, cz in holes[:25]:
        star = "  <== PRIME SUSPECT" if n_complete == 8 else ""
        print(f"  {DIM_NAME[dim]} chunk ({cx},{cz})  center block X~{cx*16+8} Z~{cz*16+8}  "
              f"complete-neighbours {n_complete}/8{star}")
    if len(holes) > 25:
        print(f"  ... and {len(holes)-25} more (less enclosed, likely natural frontier gaps)")

    flagged = []
    for (dim, cx, cz), c in chunks.items():
        tags = c["tags"]
        has_sub = T_SUBCHUNK in tags
        has_version = bool(VERSION_TAGS & set(tags))
        has_terrain = has_sub or T_LEGACY_TERRAIN in tags
        reasons = []
        sev = 0
        if has_sub and not has_version:
            reasons.append("block data present but NO chunk-version key -> engine refuses/garbles load")
            sev = max(sev, 3)
        if c["bad_sub"]:
            for suby, why in sorted(c["bad_sub"], key=lambda x: (x[0] is None, x[0])):
                reasons.append(f"corrupt SubChunk Y={suby}: {why}")
            sev = max(sev, 3)
        if has_version and not has_terrain:
            reasons.append("version/keys present but NO terrain (no SubChunk/LegacyTerrain) -> void column")
            sev = max(sev, 2)
        if c["verval"] == 0:
            reasons.append("chunk-version value is 0 (invalid)")
            sev = max(sev, 3)
        if has_terrain and not (T_DATA3D in tags or T_DATA2D in tags or T_DATA2D_LEGACY in tags):
            reasons.append("terrain present but NO heightmap/biome (Data2D/Data3D) -> lighting/render glitch")
            sev = max(sev, 1)
        if reasons:
            flagged.append((sev, dim, cx, cz, c, reasons))

    flagged.sort(key=lambda x: (-x[0], x[1], x[2], x[3]))

    print(f"\n=== CHUNK INTEGRITY SCAN — region +/-{region} blocks ===")
    print(f"chunks examined: {len(chunks)}    flagged: {len(flagged)}\n")
    if not flagged:
        print("No broken chunks found in this region. The glitch may be outside it,")
        print("client-side only, or in an ungenerated chunk (no keys to inspect).")
        print("Try a wider sweep:  REGION=4000 just _amulet scripts/scan_chunks.py")
    sev_label = {3: "HIGH", 2: "MED", 1: "LOW"}
    for sev, dim, cx, cz, c, reasons in flagged:
        bx0, bz0 = cx * 16, cz * 16
        present = ",".join(TAG_NAME.get(t, hex(t)) for t in sorted(c["tags"]))
        print(f"[{sev_label.get(sev,'?'):4}] {DIM_NAME[dim]} chunk ({cx},{cz})  "
              f"blocks X {bx0}..{bx0+15}  Z {bz0}..{bz0+15}  ver={c['verval']}")
        print(f"        tags present: {present}")
        for r in reasons:
            print(f"        - {r}")
    print()
    log.info("done — %d chunks flagged of %d examined", len(flagged), len(chunks))


if __name__ == "__main__":
    main()
