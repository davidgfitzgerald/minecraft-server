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
import matplotlib.patheffects as pe
from matplotlib.colors import LightSource, LinearSegmentedColormap


def _place_labels(fig, ax, items, dots):
    """Place player labels as a HALO around their dots, with leader lines.

    Each label radiates OUTWARD from the centre of its local crowd of dots, so it never sits
    on top of a dot and clustered dots fan their labels around the outside: two stacked dots →
    one label above, one below; an N/E/S/W ring → a label beyond each. A refinement pass then
    guarantees no label box overlaps another label OR any dot. All geometry is in display px.

    items: list of (x, z, text) to label.  dots: list of (x, z) for EVERY overlay dot (obstacles).
    Call AFTER the final layout (tight_layout) so display coords are settled.
    """
    if not items:
        return
    import math
    txtfx = [pe.withStroke(linewidth=2.6, foreground="#0b0d10")]  # dark outline → text pops anywhere
    anns = [
        ax.annotate(text, xy=(x, z), xytext=(0, 0), textcoords="offset points",
                    color="white", fontsize=9, weight="bold", ha="center", va="center",
                    path_effects=txtfx, zorder=10,
                    arrowprops=dict(arrowstyle="-", color="white", lw=0.9, shrinkA=2, shrinkB=5))
        for x, z, text in items
    ]
    fig.canvas.draw()  # realise text extents
    r = fig.canvas.get_renderer()
    dpi = fig.dpi
    anchors = [tuple(ax.transData.transform((x, z))) for x, z, _t in items]
    dotpx = [tuple(ax.transData.transform((x, z))) for x, z in dots]
    boxes = [a.get_window_extent(r) for a in anns]
    hw = [b.width / 2.0 for b in boxes]
    hh = [b.height / 2.0 for b in boxes]
    marker_r = (120.0 / math.pi) ** 0.5 * dpi / 72.0 + 2.0   # scatter s=120 → dot radius (px)
    GAP, CLUSTER_D, n = 8.0, 120.0, len(anns)

    def support(hw_, hh_, ux, uy):
        """center-to-edge distance of an axis-aligned box along unit direction (ux, uy)."""
        tx = hw_ / abs(ux) if abs(ux) > 1e-6 else 1e9
        ty = hh_ / abs(uy) if abs(uy) > 1e-6 else 1e9
        return min(tx, ty)

    cx, cy = [], []
    for i, (axd, ayd) in enumerate(anchors):
        # direction = away from the centroid of OTHER nearby dots (the local crowd)
        nx = ny = 0.0; cnt = 0
        for dx, dy in dotpx:
            if abs(dx - axd) < 1.0 and abs(dy - ayd) < 1.0:
                continue  # this label's own dot
            if math.hypot(dx - axd, dy - ayd) < CLUSTER_D:
                nx += dx; ny += dy; cnt += 1
        if cnt:
            vx, vy = axd - nx / cnt, ayd - ny / cnt
            norm = math.hypot(vx, vy)
        else:
            vx, vy, norm = 0.0, 1.0, 1.0          # isolated dot → label straight up
        if norm < 1e-3:                            # coincident dots → fan by golden angle
            ang = math.pi / 2 + i * 2.39996
            vx, vy, norm = math.cos(ang), math.sin(ang), 1.0
        ux, uy = vx / norm, vy / norm
        dist = marker_r + GAP + support(hw[i], hh[i], ux, uy)
        cx.append(axd + ux * dist); cy.append(ayd + uy * dist)

    # axes bounds (display px), inset so labels never touch the frame → for clamping
    ab = ax.get_window_extent(r)
    MARGIN = 4.0
    bx0, by0, bx1, by1 = ab.x0 + MARGIN, ab.y0 + MARGIN, ab.x1 - MARGIN, ab.y1 - MARGIN
    DOT_CLEAR = marker_r + 12.0   # generous clearance between a label box and any dot
    LBL_PAD = 6.0

    def clamp(i):
        if bx0 + hw[i] <= bx1 - hw[i]:
            cx[i] = min(max(cx[i], bx0 + hw[i]), bx1 - hw[i])
        if by0 + hh[i] <= by1 - hh[i]:
            cy[i] = min(max(cy[i], by0 + hh[i]), by1 - hh[i])

    # refine: separate labels from each other AND from every dot, then clamp inside the axes;
    # re-iterate so a clamp can't leave a label sitting on a dot or another label.
    for _ in range(600):
        moved = False
        for i in range(n):
            for j in range(i + 1, n):
                ox = (hw[i] + hw[j] + LBL_PAD) - abs(cx[i] - cx[j])
                oy = (hh[i] + hh[j] + LBL_PAD) - abs(cy[i] - cy[j])
                if ox > 0 and oy > 0:
                    moved = True
                    if oy <= ox:
                        d = oy / 2 + 0.5
                        cy[i], cy[j] = (cy[i] - d, cy[j] + d) if cy[i] <= cy[j] else (cy[i] + d, cy[j] - d)
                    else:
                        d = ox / 2 + 0.5
                        cx[i], cx[j] = (cx[i] - d, cx[j] + d) if cx[i] <= cx[j] else (cx[i] + d, cx[j] - d)
        for i in range(n):
            for dx, dy in dotpx:
                ox = (hw[i] + DOT_CLEAR) - abs(cx[i] - dx)
                oy = (hh[i] + DOT_CLEAR) - abs(cy[i] - dy)
                if ox > 0 and oy > 0:           # a dot is too close to label i → shove it off
                    moved = True
                    if oy <= ox:
                        cy[i] += (oy + 0.5) if cy[i] >= dy else -(oy + 0.5)
                    else:
                        cx[i] += (ox + 0.5) if cx[i] >= dx else -(ox + 0.5)
        for i in range(n):                       # keep every label fully inside the frame
            ox_, oy_ = cx[i], cy[i]
            clamp(i)
            if cx[i] != ox_ or cy[i] != oy_:
                moved = True
        if not moved:
            break

    for i, a in enumerate(anns):  # box is centre-anchored, so offset = label-centre − dot
        axd, ayd = anchors[i]
        a.set_position(((cx[i] - axd) * 72.0 / dpi, (cy[i] - ayd) * 72.0 / dpi))

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

# optional: overlay player positions (overworld only). ONLINE players get a bright GREEN dot,
# OFFLINE players a RED dot — the dot colour is the only online/offline cue. Labels are equally
# bold/visible for both and get leader lines + auto-spacing (below) so they never overlap.
to_label = []   # (x, z, text) — placed after the final layout
dot_obst = []   # (x, z) for EVERY dot — obstacles the labels must avoid
if PLAYERS:
    import json
    try:
        pdata = json.load(open(PLAYERS))
    except Exception as e:
        print(f"render_map: couldn't read players file: {e}")
        pdata = []
    n_on = n_off = 0
    # draw offline first so live green dots sit on top if anyone overlaps
    for p in sorted(pdata, key=lambda q: bool(q.get("online"))):
        if int(p.get("dim", 0)) != 0:
            continue  # this map is the overworld
        px, _py, pz = p["pos"]
        online = bool(p.get("online"))
        dot = "#3ddc6b" if online else "#ec4040"   # green = online, red = offline
        if online:
            n_on += 1
        else:
            n_off += 1
        ax.scatter([px], [pz], s=120, c=dot, ec="white", lw=1.4, zorder=7 if online else 6)
        dot_obst.append((px, pz))
        # label everyone we can name (anonymous DB records: dot only)
        if online or p.get("named"):
            to_label.append((px, pz, f"{p.get('id', '?')} ({int(px)},{int(pz)})"))
    # legend: dot colour is the whole story
    if n_on or n_off:
        ax.scatter([], [], s=110, c="#3ddc6b", ec="white", lw=1.3, label=f"online ({n_on})")
        ax.scatter([], [], s=110, c="#ec4040", ec="white", lw=1.3, label=f"offline ({n_off})")
        ax.legend(loc="upper right", fontsize=9, framealpha=0.75, facecolor="#1c1f25",
                  edgecolor="#333", labelcolor="#dcdcdc")
    print(f"render_map: overlaid {n_on} online + {n_off} offline overworld player(s)")
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
_place_labels(fig, ax, to_label, dot_obst)   # after layout: display coords are final
fig.savefig(OUT, facecolor=fig.get_facecolor())
print(f"wrote {OUT}  ({W}x{H} blocks)")
