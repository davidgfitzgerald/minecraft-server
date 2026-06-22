"""Pinpoint THE glitched void chunk using location + biome clues (READ-ONLY).

We know from the players: a persistent, impassable, all-players void in the WEST,
near a SNOW biome, around block X ~ -1000. The void itself has no data on disk
(generation crashes before it saves), but its NEIGHBOURS are fully generated and
carry biome data. So: find enclosed voids near the target X, decode the biomes of
their surrounding chunks, and surface the one ringed by snow.

Run:  TARGET_X=-1000 just _amulet scripts/find_void.py
"""
import logging
import os
import struct
from collections import Counter

from bedrock_nbt import configure_logging, open_db

T_DATA3D = 0x2B     # heightmap + paletted 3D biomes (1.18+)
T_DATA2D = 0x2D     # heightmap + 1-byte-per-column biomes (legacy)
T_SUBCHUNK = 0x2F
VERSION_TAGS = {0x2C, 0x76}
CHUNK_TAGS = {0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34,
              0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x76}

# Bedrock numeric biome ids that are snowy / frozen
SNOW = {10: "frozen_ocean", 11: "frozen_river", 12: "snowy_tundra", 13: "snowy_mountains",
        26: "snowy_beach", 30: "snowy_taiga", 31: "snowy_taiga_hills",
        46: "legacy_frozen_ocean", 47: "deep_frozen_ocean", 140: "ice_spikes",
        182: "jagged_peaks", 183: "frozen_peaks", 184: "snowy_slopes", 185: "grove"}


def parse_chunk_key(k):
    n = len(k)
    if n in (9, 10):
        cx, cz = struct.unpack_from("<ii", k, 0); dim, tag = 0, k[8]
    elif n in (13, 14):
        cx, cz, dim = struct.unpack_from("<iii", k, 0); tag = k[12]
    else:
        return None
    if tag not in CHUNK_TAGS or dim not in (0, 1, 2) or abs(cx) > 2_000_000 or abs(cz) > 2_000_000:
        return None
    return dim, cx, cz, tag


def biome_ids(d3d=None, d2d=None):
    """Collect the set of biome ids present in a chunk from its Data3D or Data2D blob."""
    ids = Counter()
    if d2d is not None and len(d2d) >= 768:
        for b in d2d[512:768]:          # 256 columns, 1 byte each, after 512B heightmap
            ids[b] += 1
        return ids
    if d3d is None or len(d3d) < 512:
        return ids
    pos = 512                            # skip heightmap (256 * int16)
    prev = []
    for _ in range(32):                  # at most ~24 vertical biome sections
        if pos >= len(d3d):
            break
        flag = d3d[pos]; pos += 1
        if flag == 0xFF:                 # "same as section below"
            for b in prev:
                ids[b] += 1
            continue
        bpb = flag >> 1
        if bpb == 0:                     # single-biome section, no packed words
            (bid,) = struct.unpack_from("<i", d3d, pos); pos += 4
            pal = [bid]
        else:
            per_word = 32 // bpb
            word_count = (4096 + per_word - 1) // per_word
            pos += word_count * 4        # skip packed indices; palette is enough
            (pcount,) = struct.unpack_from("<i", d3d, pos); pos += 4
            pal = [struct.unpack_from("<i", d3d, pos + 4 * i)[0] for i in range(pcount)]
            pos += 4 * pcount
        for b in pal:
            ids[b] += 1
        prev = pal
    return ids


def main():
    log = configure_logging("find_void")
    target_x = int(os.environ.get("TARGET_X", "-1000"))
    band = int(os.environ.get("BAND", "320"))          # +/- blocks around target X to consider
    tcx = target_x // 16
    bandc = band // 16
    log.info("target block X=%d (chunk X=%d), searching chunk X in %d..%d", target_x, tcx, tcx - bandc, tcx + bandc)

    db = open_db()
    present, biome_blob = set(), {}     # (dim,cx,cz) -> (data3d, data2d)
    for k in db.keys():
        pk = parse_chunk_key(k)
        if pk is None:
            continue
        dim, cx, cz, tag = pk
        present.add((dim, cx, cz))
        if tag in (T_DATA3D, T_DATA2D):
            d3, d2 = biome_blob.get((dim, cx, cz), (None, None))
            if tag == T_DATA3D:
                d3 = db.get(k)
            else:
                d2 = db.get(k)
            biome_blob[(dim, cx, cz)] = (d3, d2)

    # a chunk counts as complete terrain if it has subchunk (block) data
    complete = set()
    for k in db.keys():
        pk = parse_chunk_key(k)
        if pk and pk[3] == T_SUBCHUNK:
            complete.add((pk[0], pk[1], pk[2]))

    N8 = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
    cands = []
    xs = [x for (_, x, _) in present]; zs = [z for (_, _, z) in present]
    for cx in range(tcx - bandc, tcx + bandc + 1):
        for cz in range(min(zs), max(zs) + 1):
            key = (0, cx, cz)
            if key in present:
                continue
            n_complete = sum((0, cx + dx, cz + dz) in complete for dx, dz in N8)
            if n_complete < 6:
                continue
            # tally biomes across the 8 neighbours
            ring = Counter()
            for dx, dz in N8:
                d3, d2 = biome_blob.get((0, cx + dx, cz + dz), (None, None))
                ring += biome_ids(d3, d2)
            snow_hits = sum(v for b, v in ring.items() if b in SNOW)
            total = sum(ring.values()) or 1
            snow_frac = snow_hits / total
            top = ring.most_common(3)
            cands.append((snow_frac, n_complete, cx, cz, top))

    # rank: snowiest surroundings first, then most enclosed, then nearest to target X
    cands.sort(key=lambda c: (-c[0], -c[1], abs(c[2] - tcx)))

    print(f"\n=== VOID SUSPECTS near block X={target_x} (snow-ringed first) ===\n")
    if not cands:
        print("No enclosed voids in this X band. Widen with BAND=600 or change TARGET_X.")
    for snow_frac, n_complete, cx, cz, top in cands[:12]:
        bx, bz = cx * 16 + 8, cz * 16 + 8
        topnames = ", ".join(f"{SNOW.get(b, 'biome#'+str(b))}={n}" for b, n in top)
        flag = "  <== SNOW-RINGED" if snow_frac > 0.25 else ""
        print(f"  void chunk ({cx},{cz})  center X~{bx} Z~{bz}  "
              f"enclosed {n_complete}/8  snow={snow_frac*100:.0f}%  [{topnames}]{flag}")
    print()
    log.info("done — %d enclosed-void candidates in band", len(cands))


if __name__ == "__main__":
    main()
