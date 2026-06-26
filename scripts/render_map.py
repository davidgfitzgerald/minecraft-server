#!/usr/bin/env python3
"""Render a top-down terrain map of the overworld from heightmap.bin (export_heightmap.py).

REAL data: each 520-byte record is <cx i32><cz i32><256 x i16> surface heights. We stitch
chunks into one elevation grid, shade it with a Minecraft-ish elevation ramp + hillshade,
and write a PNG. North (−Z) is up. Runs on the host (numpy + matplotlib).

    python3 scripts/render_map.py <heightmap.bin> [out.png]
"""
import struct
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LightSource, LinearSegmentedColormap

SRC = sys.argv[1] if len(sys.argv) > 1 else "bedrock-data/_maptmp/heightmap.bin"
OUT = sys.argv[2] if len(sys.argv) > 2 else "world-map.png"
PLAYERS = sys.argv[3] if len(sys.argv) > 3 else None  # optional players.json → overlay markers
REC = 8 + 512

raw = open(SRC, "rb").read()
n = len(raw) // REC
if n == 0:
    sys.exit(f"no chunks in {SRC}")

recs = []
minx = minz = 1 << 30
maxx = maxz = -(1 << 30)
for i in range(n):
    o = i * REC
    cx, cz = struct.unpack_from("<ii", raw, o)
    h = np.frombuffer(raw, dtype="<i2", count=256, offset=o + 8).reshape(16, 16).astype(float)
    recs.append((cx, cz, h))
    minx, maxx = min(minx, cx), max(maxx, cx)
    minz, maxz = min(minz, cz), max(maxz, cz)

W = (maxx - minx + 1) * 16
H = (maxz - minz + 1) * 16
grid = np.full((H, W), np.nan)
for cx, cz, h in recs:
    px = (cx - minx) * 16
    pz = (cz - minz) * 16
    grid[pz:pz + 16, px:px + 16] = h  # heightmap flat index z*16+x → row=z, col=x

valid = ~np.isnan(grid)
lo = float(np.nanpercentile(grid, 2))
hi = float(np.nanpercentile(grid, 98))

# elevation ramp: deep water → shallow → beach → grass → forest → dirt → rock → snow
cmap = LinearSegmentedColormap.from_list("mc", [
    "#15324f", "#1f5c8b", "#2f87b8", "#cdbd8e",
    "#5a9e4b", "#3c7a33", "#7d6b50", "#9a9a92", "#f3f5f8",
])
ls = LightSource(azdeg=315, altdeg=45)
gfill = np.where(valid, grid, lo)
rgb = ls.shade(gfill, cmap=cmap, blend_mode="soft", vert_exag=3.0, dx=1, dy=1, vmin=lo, vmax=hi)
rgb[~valid] = [0.07, 0.08, 0.10, 1.0]  # ungenerated area = dark background

aspect = H / W
fig, ax = plt.subplots(figsize=(12, max(4.0, 12 * aspect) + 0.6), dpi=130)
# origin upper + this extent puts smallest Z (north) at the top, world coords on the axes
ax.imshow(rgb, origin="upper",
          extent=[minx * 16, (maxx + 1) * 16, (maxz + 1) * 16, minz * 16],
          interpolation="nearest")
ax.scatter([0], [0], s=160, marker="*", c="white", ec="#111", lw=1.1, zorder=5)
ax.annotate("0,0", (0, 0), (10, 8), textcoords="offset points", color="white", fontsize=8, weight="bold")

# optional: overlay player positions (overworld only). Plots X vs Z, labels with a short id.
if PLAYERS:
    import json
    try:
        pdata = json.load(open(PLAYERS))
    except Exception as e:
        print(f"render_map: couldn't read players file: {e}")
        pdata = []
    for p in pdata:
        if int(p.get("dim", 0)) != 0:
            continue  # this map is the overworld
        px, _py, pz = p["pos"]
        ax.scatter([px], [pz], s=95, c="#ff4d4d", ec="white", lw=1.4, zorder=6)
        ax.annotate(f"{p.get('id', '?')} ({int(px)},{int(pz)})", (px, pz), (8, -12),
                    textcoords="offset points", color="white", fontsize=8, weight="bold",
                    zorder=6)
    print(f"render_map: overlaid {sum(1 for p in pdata if int(p.get('dim',0))==0)} overworld player(s)")
ax.set_title(f"Overworld surface · {n} chunks · X {minx*16}…{(maxx+1)*16}, "
             f"Z {minz*16}…{(maxz+1)*16} · height {int(lo)}–{int(hi)}",
             color="#eaeaea", fontsize=11, pad=10)
ax.set_xlabel("X (blocks)"); ax.set_ylabel("Z (blocks, north ↑)")
fig.patch.set_facecolor("#16181d"); ax.set_facecolor("#16181d")
ax.tick_params(colors="#888"); ax.xaxis.label.set_color("#aaa"); ax.yaxis.label.set_color("#aaa")
ax.title.set_color("#eaeaea")
for s in ax.spines.values():
    s.set_color("#333")
fig.tight_layout()
fig.savefig(OUT, facecolor=fig.get_facecolor())
print(f"wrote {OUT}  ({W}x{H} blocks)")
