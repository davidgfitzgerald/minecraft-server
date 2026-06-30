#!/usr/bin/env python3
"""Extract the overworld surface (height + true block colour) from the world LevelDB → /out/heightmap.bin.

Per chunk we emit two things:
  * the 16x16 surface heightmap (256 x int16) from Data3D (0x2B, 1.18+) / Data2D (0x2D) —
    render_map.py uses it for HILLSHADE relief only.
  * an RGB colour for each column's actual TOP BLOCK, decoded from the SubChunk block storage
    (0x2F) and looked up in BLOCK_COLORS below. So the map shows real blocks: water is water,
    cherry leaves are pink, every wool/terracotta/wood type its own colour, etc.

Output record (little-endian), 1288 bytes each:

    <cx:int32><cz:int32><256 x int16 height><256 x (uint8 r, g, b)>

Runs in the mc-tools container (amulet-leveldb = raw LevelDB only; SubChunk/NBT decode is
hand-rolled here). render_map.py turns this into a PNG on the host.
"""
import struct
from bedrock_nbt import open_db

T_DATA3D = 0x2B
T_DATA2D = 0x2D
T_SUBCHUNK = 0x2F
WORLD_FLOOR = -64  # Bedrock 1.18+: stored heightmap is the surface Y offset from here


def _h(s):
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def _mix(a, b, t):
    return tuple(int(round(a[i] * (1 - t) + b[i] * t)) for i in range(3))


DEFAULT = _h("9a9a93")   # unrecognised non-air block
TERRA = _h("97604a")     # plain terracotta base

# blocks that sit ON the surface but aren't the surface — skip and colour the block beneath
SKIP = {
    "air", "cave_air", "void_air",
    "torch", "wall_torch", "soul_torch", "soul_wall_torch", "redstone_torch",
    "redstone_wall_torch", "lever", "stone_button", "rail", "powered_rail",
    "detector_rail", "activator_rail", "tripwire", "tripwire_hook", "ladder",
    "snow_layer",  # thin snow over real ground (full snow_block handled below)
}

# 16 Minecraft dye colours (wool/concrete/terracotta/glass/etc.)
DYE = {
    "white": _h("e9ecec"), "orange": _h("f07613"), "magenta": _h("bd44b3"),
    "light_blue": _h("3aafd9"), "yellow": _h("f8c627"), "lime": _h("70b919"),
    "pink": _h("ed8dac"), "gray": _h("3e4447"), "light_gray": _h("8e8e86"),
    "cyan": _h("158991"), "purple": _h("8932b8"), "blue": _h("3c44aa"),
    "brown": _h("835432"), "green": _h("5e7c16"), "red": _h("b02e26"),
    "black": _h("1d1c21"),
}
DYED = {"wool", "carpet", "concrete", "concrete_powder", "stained_glass",
        "stained_glass_pane", "shulker_box", "bed", "candle", "banner"}

# per-wood-type tone (planks/logs/stairs/fences/…)
WOOD = {
    "oak": _h("b08a55"), "spruce": _h("6e5132"), "birch": _h("d3c98c"),
    "jungle": _h("a87b54"), "acacia": _h("b56a37"), "dark_oak": _h("43301c"),
    "mangrove": _h("78403c"), "cherry": _h("e2b3bb"), "bamboo": _h("c9b25a"),
    "crimson": _h("6a344b"), "warped": _h("39786f"), "pale_oak": _h("c2bca8"),
}
LEAF = {
    "oak": _h("4f7a2f"), "spruce": _h("44604a"), "birch": _h("6e8a3f"),
    "jungle": _h("3a7a26"), "acacia": _h("6a8a35"), "dark_oak": _h("3c5e28"),
    "mangrove": _h("4f7a3a"), "cherry": _h("eaa0c4"), "azalea": _h("5f8a3a"),
    "flowering_azalea": _h("7fa05a"), "pale_oak": _h("b8c2a6"), "pale": _h("b8c2a6"),
}

EXACT = {
    # ground
    "grass_block": _h("5b8c39"), "moss_block": _h("5a8a3a"), "mycelium": _h("6f6275"),
    "podzol": _h("5a3f23"), "dirt": _h("866043"), "coarse_dirt": _h("7a5638"),
    "rooted_dirt": _h("8a6a4a"), "farmland": _h("6b4a2b"), "dirt_path": _h("8a7340"),
    "grass_path": _h("8a7340"), "mud": _h("3f3a37"), "muddy_mangrove_roots": _h("4a3f33"),
    "clay": _h("a3a7b0"), "gravel": _h("837e7c"), "suspicious_gravel": _h("837e7c"),
    "sand": _h("dbcf9a"), "suspicious_sand": _h("d6c98f"), "red_sand": _h("be6a37"),
    "sandstone": _h("d8c79a"), "red_sandstone": _h("b5703a"),
    # stone family
    "stone": _h("8a8a8a"), "cobblestone": _h("7f7f7f"), "mossy_cobblestone": _h("6f7a5f"),
    "andesite": _h("8f8f8f"), "diorite": _h("cfcfcf"), "granite": _h("a87b66"),
    "tuff": _h("6b6e66"), "calcite": _h("dcded9"), "dripstone_block": _h("95786a"),
    "pointed_dripstone": _h("95786a"), "deepslate": _h("4a4a4f"), "cobbled_deepslate": _h("4f4f55"),
    "bedrock": _h("565656"), "obsidian": _h("17121f"), "crying_obsidian": _h("241433"),
    "basalt": _h("4a4a52"), "smooth_basalt": _h("48484f"), "blackstone": _h("2c2730"),
    "amethyst_block": _h("9a72d0"), "budding_amethyst": _h("9a72d0"),
    "magma": _h("9b3a1c"), "magma_block": _h("9b3a1c"),
    "netherrack": _h("6e3636"), "soul_sand": _h("514034"), "soul_soil": _h("4a3a30"),
    "crimson_nylium": _h("822f3a"), "warped_nylium": _h("2a6a5a"),
    "raw_iron_block": _h("b29982"), "raw_copper_block": _h("a06a4a"), "iron_block": _h("d8d8d8"),
    "gold_block": _h("f3d23a"), "diamond_block": _h("6ad7cf"), "emerald_block": _h("3fbf6f"),
    # water / ice / snow
    "water": _h("3a6fb0"), "flowing_water": _h("3a6fb0"), "bubble_column": _h("3a6fb0"),
    "seagrass": _h("3a6fb0"), "tall_seagrass": _h("3a6fb0"), "kelp": _h("3a6fb0"),
    "kelp_plant": _h("3a6fb0"), "lava": _h("d4602a"), "flowing_lava": _h("d4602a"),
    "wheat": _h("c7b34a"), "carrots": _h("5a8a3a"), "potatoes": _h("5a8a3a"),
    "beetroot": _h("6a8a3a"), "smooth_stone": _h("9a9a9a"), "dirt_with_roots": _h("8a6a4a"),
    "azalea_leaves_flowered": _h("7fa05a"),
    "ice": _h("a9c8ef"), "packed_ice": _h("95b8e0"), "blue_ice": _h("74a8e0"), "frosted_ice": _h("a9c8ef"),
    "snow": _h("f4f7fb"), "snow_block": _h("f4f7fb"), "powder_snow": _h("eef3fb"),
    # leaves / foliage / plants
    "vine": _h("4a6a2f"), "moss_carpet": _h("5a8a3a"), "pale_moss_block": _h("9aa890"),
    "pale_moss_carpet": _h("9aa890"), "glow_lichen": _h("6a9a7a"), "hanging_roots": _h("8a6a4a"),
    "grass": _h("6aa83f"), "short_grass": _h("6aa83f"), "tall_grass": _h("6aa83f"),
    "fern": _h("5f9a3a"), "large_fern": _h("5f9a3a"), "short_dry_grass": _h("b6a45a"),
    "tall_dry_grass": _h("b6a45a"), "dead_bush": _h("9a7b46"), "deadbush": _h("9a7b46"),
    "bush": _h("5a7a3a"), "firefly_bush": _h("5a7a3a"), "leaf_litter": _h("b07a3a"),
    "sugar_cane": _h("8ab35a"), "reeds": _h("8ab35a"), "bamboo": _h("8aa83f"),
    "bamboo_sapling": _h("8aa83f"), "cactus": _h("4a7a3a"), "lily_pad": _h("3a6a3a"),
    "sweet_berry_bush": _h("3a5a2a"), "cocoa": _h("8a5a2a"), "nether_wart": _h("7a1f1f"),
    "pumpkin": _h("d6791d"), "carved_pumpkin": _h("d6791d"), "lit_pumpkin": _h("e08a2a"),
    "melon": _h("5a8a3a"), "melon_block": _h("5a8a3a"), "hay_block": _h("c2a01f"),
    "brown_mushroom_block": _h("8a6a4a"), "red_mushroom_block": _h("b0392f"),
    "mushroom_stem": _h("e0dccd"), "nether_wart_block": _h("7a1f1f"), "warped_wart_block": _h("1f7a72"),
    "brown_mushroom": _h("8a6a4a"), "red_mushroom": _h("b0392f"),
    "chorus_plant": _h("6a4a6a"), "chorus_flower": _h("9a7a9a"),
    # flowers (real Minecraft-ish colours)
    "dandelion": _h("e6c21f"), "poppy": _h("cf3320"), "blue_orchid": _h("2aa6d6"),
    "allium": _h("a05ad0"), "azure_bluet": _h("d8e0ea"), "red_tulip": _h("c92a1f"),
    "orange_tulip": _h("e07a1c"), "white_tulip": _h("e8ecec"), "pink_tulip": _h("e89ac0"),
    "oxeye_daisy": _h("e6ecd0"), "cornflower": _h("4a6ad0"), "lily_of_the_valley": _h("e8ecec"),
    "wither_rose": _h("29302a"), "torchflower": _h("e07a1c"), "pitcher_plant": _h("5a6ad0"),
    "pink_petals": _h("eca3c4"), "wildflowers": _h("d6c84a"), "spore_blossom": _h("e08aa8"),
    "sunflower": _h("f1c21a"), "lilac": _h("c79ad6"), "rose_bush": _h("b03a3a"),
    "peony": _h("e0a8d0"), "cactus_flower": _h("e07a9a"),
    # built / misc
    "glass": _h("cfe6ee"), "glass_pane": _h("cfe6ee"), "tinted_glass": _h("2a2730"),
    "bricks": _h("9a5a4a"), "stone_bricks": _h("8a8a86"), "mossy_stone_bricks": _h("76806a"),
    "nether_bricks": _h("352026"), "bookshelf": _h("9a7a4a"), "crafting_table": _h("9a6b43"),
    "furnace": _h("6a6a6a"), "chest": _h("9a7032"), "barrel": _h("9a7a4a"),
    "campfire": _h("8a5a2a"), "lantern": _h("c79a3a"), "scaffolding": _h("c9b25a"),
    "composter": _h("8a6a3a"), "beehive": _h("c79a4a"), "bee_nest": _h("c7a04a"),
    "bed": _h("b03030"),
    # mod-ish blocks seen in this world
    "cinnabar": _h("a8322f"), "sulfur": _h("d8c021"), "sulfur_spike": _h("e0cc3a"),
    "fence_gate": WOOD["oak"], "trapdoor": _h("6a4a2a"),
}


def get_color(name):
    """Return an (r,g,b) for the column's top block, 'skip' to look beneath it, or None if unknown."""
    n = name.split(":", 1)[-1]
    if n in SKIP:
        return "skip"
    if n in EXACT:
        return EXACT[n]
    if "leaves" in n:
        for w, col in LEAF.items():
            if n == w + "_leaves":
                return col
        for w, col in LEAF.items():
            if w in n:
                return col
        return LEAF["oak"]
    for w, base in WOOD.items():  # wood-typed building blocks (planks/log/stairs/fence/…)
        if n.startswith(w + "_") or n.startswith("stripped_" + w + "_"):
            return base
    for c, dye in DYE.items():   # dyed materials → that dye colour
        if n.startswith(c + "_"):
            rest = n[len(c) + 1:]
            if "terracotta" in rest:
                return _mix(TERRA, dye, 0.5)
            if rest in DYED:
                return dye
    if n.endswith("_rail"):
        return "skip"
    if n in ("terracotta", "hardened_clay") or "terracotta" in n:
        return TERRA
    if "deepslate" in n:
        return _h("4a4a4f")
    if "blackstone" in n:
        return _h("2c2730")
    if "red_sandstone" in n:
        return _h("b5703a")
    if "sandstone" in n:
        return _h("d8c79a")
    if "_bricks" in n or n == "bricks" or "brick" in n:
        return _h("8a8a86")
    if n.endswith("_wall") or n.startswith("smooth_") or "cobblestone" in n or "stone" in n:
        return _h("8a8a8a")
    if "copper" in n:
        return _h("c66e4f")
    if "_ore" in n or "_block" in n and "ore" in n:
        return _h("8a8a8a")
    if "concrete" in n or "wool" in n or "_glass" in n or "glazed" in n:
        return _h("b8b8b8")
    if "_planks" in n or "_log" in n or "_wood" in n or "_stairs" in n or "_slab" in n:
        return WOOD["oak"]
    return None


def decode_subchunk(v):
    """Decode a SubChunk value → (bits, blockdata, palette_names) for storage layer 0."""
    ver = v[0]
    if ver == 9:
        off = 3
    elif ver == 8:
        off = 2
    elif ver == 1:
        off = 1
    else:
        return None
    header = v[off]; off += 1
    bits = header >> 1
    if bits == 0:
        return (0, b"", ["minecraft:air"])
    bpw = 32 // bits
    words = (4096 + bpw - 1) // bpw
    blockdata = v[off:off + words * 4]; off += words * 4
    pcount = struct.unpack_from("<i", v, off)[0]; off += 4
    names = []
    for _ in range(pcount):
        tag, off = _nbt_at(v, off)
        names.append(tag.get("name", "minecraft:air"))
    return (bits, blockdata, names)


def _nbt_at(data, pos):
    """Decode one LE-NBT tag at `pos`; return (value, new_pos). Enough for block palette tags."""
    def s(p):
        n = struct.unpack_from("<H", data, p)[0]; p += 2
        return data[p:p + n].decode("utf-8", "replace"), p + n

    def payload(t, p):
        if t == 1: return data[p], p + 1
        if t == 2: return struct.unpack_from("<h", data, p)[0], p + 2
        if t == 3: return struct.unpack_from("<i", data, p)[0], p + 4
        if t == 4: return struct.unpack_from("<q", data, p)[0], p + 8
        if t == 5: return struct.unpack_from("<f", data, p)[0], p + 4
        if t == 6: return struct.unpack_from("<d", data, p)[0], p + 8
        if t == 7:
            n = struct.unpack_from("<i", data, p)[0]; p += 4; return list(data[p:p + n]), p + n
        if t == 8: return s(p)
        if t == 9:
            et = data[p]; p += 1; n = struct.unpack_from("<i", data, p)[0]; p += 4
            out = []
            for _ in range(n):
                val, p = payload(et, p); out.append(val)
            return out, p
        if t == 10:
            d = {}
            while True:
                tt = data[p]; p += 1
                if tt == 0: break
                nm, p = s(p); val, p = payload(tt, p); d[nm] = val
            return d, p
        if t == 11:
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            out = []
            for _ in range(n):
                out.append(struct.unpack_from("<i", data, p)[0]); p += 4
            return out, p
        if t == 12:
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            out = []
            for _ in range(n):
                out.append(struct.unpack_from("<q", data, p)[0]); p += 8
            return out, p
        raise ValueError(f"bad nbt tag {t}")
    t = data[pos]; pos += 1
    _name, pos = s(pos)
    return payload(t, pos)


def block_at(dec, lx, ly, lz):
    bits, blockdata, names = dec
    if bits == 0:
        return names[0]
    bi = (lx << 8) | (lz << 4) | ly
    bpw = 32 // bits
    word = struct.unpack_from("<I", blockdata, (bi // bpw) * 4)[0]
    pidx = (word >> ((bi % bpw) * bits)) & ((1 << bits) - 1)
    return names[pidx] if pidx < len(names) else "minecraft:air"


def main():
    db = open_db()
    best = {}      # (cx,cz) -> (priority, 512B heightmap)   Data3D(2) > Data2D(1)
    subkeys = {}   # (cx,cz) -> {subY: key bytes}
    for k in db.keys():
        if len(k) == 9:
            cx, cz = struct.unpack_from("<ii", k, 0); tag = k[8]
        elif len(k) == 10 and k[8] == T_SUBCHUNK:
            cx, cz = struct.unpack_from("<ii", k, 0)
            subkeys.setdefault((cx, cz), {})[struct.unpack_from("<b", k, 9)[0]] = k
            continue
        else:
            continue  # other dimensions / record types
        if tag not in (T_DATA3D, T_DATA2D):
            continue
        v = db.get(k)
        if not v or len(v) < 512:
            continue
        prio = 2 if tag == T_DATA3D else 1
        cur = best.get((cx, cz))
        if cur is None or prio > cur[0]:
            best[(cx, cz)] = (prio, v[:512])

    unknown = {}
    lo = hi = None
    nrec = 0
    with open("/out/heightmap.bin", "wb") as f:
        for (cx, cz), (_, hb) in best.items():
            heights = struct.unpack("<256h", hb)
            rgb = bytearray(768)
            sk = subkeys.get((cx, cz), {})
            cache = {}

            def getdec(si):
                if si not in cache:
                    key = sk.get(si)
                    if key is None:
                        cache[si] = None
                    else:
                        try:
                            cache[si] = decode_subchunk(db.get(key))
                        except Exception:
                            cache[si] = None
                return cache[si]

            for idx in range(256):
                lx, lz = idx & 15, idx >> 4   # flat index = z*16 + x
                stored = heights[idx]
                if lo is None or stored < lo: lo = stored
                if hi is None or stored > hi: hi = stored
                startY = stored + WORLD_FLOOR
                col = DEFAULT
                for y in range(startY + 1, startY - 6, -1):   # scan to first real surface block
                    dec = getdec(y >> 4)
                    if dec is None:
                        continue
                    name = block_at(dec, lx, y & 15, lz)
                    c = get_color(name)
                    if c == "skip":
                        continue
                    if c is None:
                        unknown[name] = unknown.get(name, 0) + 1
                        col = DEFAULT
                    else:
                        col = c
                    break
                rgb[idx * 3:idx * 3 + 3] = bytes(col)

            f.write(struct.pack("<ii", cx, cz))
            f.write(hb)
            f.write(rgb)
            nrec += 1

    try:
        db.close()  # release the LevelDB lock so export_players.py (same container) can open it
    except Exception:
        pass
    print(f"exported {nrec} overworld chunks (stored height {lo}..{hi}) -> /out/heightmap.bin")
    if unknown:
        top = sorted(unknown.items(), key=lambda kv: -kv[1])[:12]
        print("uncoloured top blocks: " + ", ".join(f"{n}×{c}" for n, c in top))


if __name__ == "__main__":
    main()
