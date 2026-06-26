#!/usr/bin/env python3
"""Extract the overworld surface heightmap from the world LevelDB → /out/heightmap.bin.

Each chunk stores a 16x16 surface heightmap as the first 512 bytes (256 x int16 LE) of
its Data3D (tag 0x2B, 1.18+) or Data2D (tag 0x2D, legacy) record. We prefer Data3D when
both exist. Output is flat little-endian records, 520 bytes each:

    <cx:int32><cz:int32><256 x int16>      # chunk coords + its 16x16 heights

Runs in the mc-tools container (amulet-leveldb). render_map.py turns this into a PNG on
the host (which has numpy/matplotlib; the tools image deliberately does not).
"""
import struct
from bedrock_nbt import open_db

T_DATA3D = 0x2B
T_DATA2D = 0x2D


def main():
    db = open_db()  # /db (a copy of the world db, mounted by `just map`)
    best = {}  # (cx,cz) -> (priority, 512-byte heightmap)   priority: Data3D(2) > Data2D(1)
    for k in db.keys():
        # overworld chunk keys are 9 bytes: <cx i32><cz i32><tag u8>.
        # other dimensions add a 4-byte dim field (13 bytes) — skip those (dim != 0).
        if len(k) == 9:
            cx, cz = struct.unpack_from("<ii", k, 0)
            tag = k[8]
        elif len(k) == 13:
            cx, cz, dim = struct.unpack_from("<iii", k, 0)
            if dim != 0:
                continue
            tag = k[12]
        else:
            continue  # SubChunk (10/14 B) and other records aren't heightmaps
        if tag not in (T_DATA3D, T_DATA2D):
            continue
        v = db.get(k)
        if not v or len(v) < 512:
            continue
        prio = 2 if tag == T_DATA3D else 1
        cur = best.get((cx, cz))
        if cur is None or prio > cur[0]:
            best[(cx, cz)] = (prio, v[:512])

    lo = hi = None
    with open("/out/heightmap.bin", "wb") as f:
        for (cx, cz), (_, hb) in best.items():
            f.write(struct.pack("<ii", cx, cz))
            f.write(hb)
            for j in range(0, 512, 2):
                h = struct.unpack_from("<h", hb, j)[0]
                lo = h if lo is None or h < lo else lo
                hi = h if hi is None or h > hi else hi
    print(f"exported {len(best)} overworld chunks (height range {lo}..{hi}) -> /out/heightmap.bin")


if __name__ == "__main__":
    main()
