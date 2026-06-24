#!/usr/bin/env python3
"""Render a 4-panel uptime report (London time) + a text summary for Discord.

AUTHORITATIVE up/down comes from the healthchecks.io flip history — the same source
behind #server-status, i.e. "could a player actually reach the server" (needs the
host online AND the tunnel up), NOT merely "is the bedrock container running locally".
The detail panels (players / CPU / RAM) come from the local monitor health.csv, with
lines broken across data gaps and the down periods shaded.

Prints the Discord message text to stdout; writes the PNG to --out. Outage lines and
diagnostics go to stderr.

Env:  HEALTHCHECK_URL  HEALTHCHECK_API_KEY   (without these, status falls back to
      local signals — gap / cpu=NA / tunnel-error — and is labelled approximate)
"""
import argparse, csv, glob, json, os, re, sys, urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

LON = ZoneInfo("Europe/London")
HC_API = "https://healthchecks.io/api/v3"
GAP = 90  # seconds; a larger inter-sample gap is a monitor-down hole (no data)

ap = argparse.ArgumentParser()
ap.add_argument("--health", default="bedrock-data/monitoring/health.csv")
ap.add_argument("--out", default="uptime.png")
ap.add_argument("--day", default=None, help="London calendar day: YYYY-MM-DD | yesterday | today")
ap.add_argument("--hours", type=float, default=None, help="rolling window of N hours ending now")
ap.add_argument("--crashes", type=int, default=None)
ap.add_argument("--now", default=None, help="override 'now' (ISO UTC) — for testing")
args = ap.parse_args()

now = (datetime.fromisoformat(args.now).replace(tzinfo=timezone.utc) if args.now
       else datetime.now(timezone.utc))

# ---- resolve the window [start,end] in UTC, from a London-local intent ----------
if args.day:
    if args.day == "today":
        d = now.astimezone(LON).date()
    elif args.day == "yesterday":
        d = (now.astimezone(LON) - timedelta(days=1)).date()
    else:
        d = datetime.strptime(args.day, "%Y-%m-%d").date()
    start = datetime(d.year, d.month, d.day, tzinfo=LON).astimezone(timezone.utc)
    end = start + timedelta(days=1)
    label = f"{d:%a %d %b %Y}"
else:
    hours = args.hours or 24
    end, start = now, now - timedelta(hours=hours)
    label = f"last {hours:g}h"
end = min(end, now)  # never draw a window edge into the future

def hm(s):
    s = int(max(0, s)); return f"{s // 3600}h{(s % 3600) // 60:02d}m"

# ---- AUTHORITATIVE up/down segments from healthchecks.io flips ------------------
def fetch_flips():
    url_env, key = os.environ.get("HEALTHCHECK_URL", ""), os.environ.get("HEALTHCHECK_API_KEY", "")
    m = re.search(r"([0-9a-fA-F-]{36})", url_env)
    if not (m and key):
        return None
    s = int((start - timedelta(days=14)).timestamp())  # wide enough to know state at `start`
    e = int((end + timedelta(minutes=5)).timestamp())
    req = urllib.request.Request(f"{HC_API}/checks/{m.group(1)}/flips/?start={s}&end={e}",
                                 headers={"X-Api-Key": key})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)
    except Exception as ex:
        print(f"# flips fetch failed: {ex}", file=sys.stderr)
        return None
    flips = data["flips"] if isinstance(data, dict) else data
    out = []
    for f in flips:
        t = f["timestamp"]
        t = (datetime.fromtimestamp(t, tz=timezone.utc) if isinstance(t, (int, float))
             else datetime.fromisoformat(t).astimezone(timezone.utc))
        out.append((t, bool(f["up"])))
    out.sort()
    return out

def status_from_flips(flips):
    state = True  # state entering the window = last flip at/<=start (default up)
    for t, up in flips:
        if t <= start: state = up
        else: break
    segs, cur, t0 = [], state, start
    for t, up in flips:
        if t <= start or t >= end: continue
        segs.append((t0, t, cur)); t0, cur = t, up
    segs.append((t0, end, cur))
    return segs

# ---- local detail from health.csv (+ rotated files) -----------------------------
def parse_ts(s): return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
def mib(s):
    s = s.strip()
    if s in ("NA", ""): return None
    v = float(re.sub(r"[A-Za-z]+$", "", s))
    if s.endswith(("GiB", "GB")): return v * 1024
    if s.endswith(("KiB", "KB")): return v / 1024
    return v

H = []  # (ts, players, cpu|None, mem_mib|None, err_d)
for path in [args.health] + sorted(glob.glob(args.health + ".[0-9]*")):
    try: f = open(path)
    except OSError: continue
    with f:
        rd = csv.reader(f); next(rd, None)
        for row in rd:
            if len(row) < 4 or not row[0].startswith("20"): continue
            try: t = parse_ts(row[0])
            except ValueError: continue
            if not (start <= t <= end): continue
            cpu = None if row[2] in ("NA", "") else float(row[2])
            err = int(row[5]) if len(row) > 5 and row[5].isdigit() else 0
            H.append((t, int(row[1] or 0), cpu, mib(row[3]), err))
H.sort(key=lambda r: r[0])

flips = fetch_flips()
authoritative = flips is not None
if authoritative:
    segs, src = status_from_flips(flips), "healthchecks.io"
else:
    src = "local signals (hc.io unavailable)"
    segs = []
    for i in range(len(H) - 1):
        t0, _, cpu0, _, err0 = H[i]; t1 = H[i + 1][0]
        up = (t1 - t0).total_seconds() <= GAP and cpu0 is not None and err0 == 0
        segs.append((t0, t1, up))

# ---- stats ----------------------------------------------------------------------
up_s = sum((b - a).total_seconds() for a, b, u in segs if u)
down_s = sum((b - a).total_seconds() for a, b, u in segs if not u)
total = up_s + down_s or 1
outs = []
for a, b, u in segs:
    if not u:
        if outs and abs((outs[-1][1] - a).total_seconds()) < 1: outs[-1] = (outs[-1][0], b)
        else: outs.append((a, b))
longest = max(((b - a).total_seconds() for a, b in outs), default=0)
peak = max((p for _, p, *_ in H), default=0)
cpus = [c for _, _, c, _, _ in H if c is not None]
mems = [m for _, _, _, m, _ in H if m is not None]

joins = leaves = 0  # per-window, from events.csv (UTC timestamps)
try:
    with open(os.path.join(os.path.dirname(args.health), "events.csv")) as f:
        for line in f:
            mt = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(connected|disconnected),", line)
            if not mt: continue
            t = datetime.strptime(mt.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
            if start <= t <= end:
                joins += mt.group(2) == "connected"; leaves += mt.group(2) == "disconnected"
except FileNotFoundError:
    pass

off = start.astimezone(LON).strftime("%z"); off = f"{off[:3]}:{off[3:]}"
tzname = start.astimezone(LON).strftime("%Z")
emoji = "🟢" if down_s == 0 else "🟠" if up_s >= down_s else "🔴"
summary = [
    f"📊 **Bedrock daily digest — {label}**  ·  times in {tzname} (UTC{off})",
    f"{emoji} reachable {up_s/total*100:.1f}%  ·  {hm(up_s)} up / {hm(down_s)} down  ·  {len(outs)} outage(s)  ·  longest {hm(longest)}",
    f"👥 players: peak {peak}  ·  {joins} joins / {leaves} leaves",
    (f"🔥 CPU: avg {sum(cpus)/len(cpus):.0f}% · max {max(cpus):.0f}%" if cpus else "🔥 CPU: no data"),
    (f"🧠 RAM: avg {sum(mems)/len(mems)/1024:.1f}G · max {max(mems)/1024:.1f}G" if mems else "🧠 RAM: no data"),
]
if args.crashes is not None:
    summary.append(f"💥 crashes (since boot): {args.crashes}")
if not authoritative:
    summary.append("⚠️ status from local signals (hc.io unreachable) — approximate")
print("\n".join(summary))
for a, b in outs:
    print(f"#   outage {a.astimezone(LON):%H:%M}–{b.astimezone(LON):%H:%M} {tzname}  ({hm((b-a).total_seconds())})", file=sys.stderr)

# ---- render ---------------------------------------------------------------------
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, matplotlib.dates as mdates

fig, axs = plt.subplots(4, 1, figsize=(11, 6.4), height_ratios=[0.5, 1, 1, 1],
                        gridspec_kw=dict(hspace=0.55))
fig.patch.set_facecolor("#2b2d31")
sx, ex = start.astimezone(LON), end.astimezone(LON)
for ax in axs:
    ax.set_facecolor("#1e1f22")
    for sp in ax.spines.values(): sp.set_color("#4a4d52")
    ax.tick_params(colors="#b5bac1", labelsize=8)
    ax.set_xlim(sx, ex)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=LON))
    ax.xaxis.set_major_locator(mdates.HourLocator(interval=2, tz=LON))
    ax.grid(True, color="#33353a", lw=0.5)

# (1) status strip
for a, b, u in segs:
    axs[0].axvspan(a.astimezone(LON), b.astimezone(LON), color="#43b581" if u else "#f04747")
axs[0].set_yticks([]); axs[0].grid(False)
axs[0].set_title(f"reachable (green) / down (red) — source: {src}", color="#dbdee1", fontsize=9, loc="left", pad=4)

def series(idx, scale=1.0):
    """x,y for column `idx`, with a NaN inserted across each data gap so the line
    breaks rather than bridging the dead zone with a fake straight segment."""
    xs, ys, prev = [], [], None
    for r in H:
        t = r[0]
        if prev is not None and (t - prev).total_seconds() > GAP:
            xs.append(prev.astimezone(LON)); ys.append(float("nan"))
        v = r[idx]
        xs.append(t.astimezone(LON)); ys.append(float("nan") if v is None else v * scale)
        prev = t
    return xs, ys

def shade_down(ax):
    for a, b, u in segs:
        if not u:
            ax.axvspan(a.astimezone(LON), b.astimezone(LON), color="#f04747", alpha=0.13, lw=0, zorder=0)

# (2) players  (3) CPU  (4) RAM — gap-broken + down-shaded
px, py = series(1)
axs[1].step(px, py, where="post", color="#5865f2", lw=1.5)
axs[1].fill_between(px, py, step="post", color="#5865f2", alpha=0.25)
axs[1].set_ylim(0, (peak or 1) + 1); axs[1].set_ylabel("players", color="#b5bac1", fontsize=8)
axs[1].set_title("players online", color="#dbdee1", fontsize=9, loc="left", pad=4)

def line(ax, idx, color, title, ylab, scale=1.0):
    xs, ys = series(idx, scale)
    ax.plot(xs, ys, color=color, lw=1.4); ax.fill_between(xs, ys, color=color, alpha=0.18)
    ax.set_title(title, color="#dbdee1", fontsize=9, loc="left", pad=4)
    ax.set_ylabel(ylab, color="#b5bac1", fontsize=8)

line(axs[2], 2, "#faa61a", "bedrock CPU %", "%")
line(axs[3], 3, "#3ba55d", "bedrock memory (GiB)", "GiB", scale=1 / 1024)
for ax in (axs[1], axs[2], axs[3]):
    shade_down(ax)

fig.suptitle(f"Bedrock uptime — {label}   ·   reachable {up_s/total*100:.1f}%  ({hm(up_s)} up / {hm(down_s)} down)",
             color="#fff", fontsize=12, x=0.012, ha="left", y=0.995)
fig.text(0.012, 0.005, "red shading = server unreachable (per healthchecks.io); blank = monitor had no data",
         color="#8a8d93", fontsize=7.5, ha="left")
fig.savefig(args.out, dpi=130, facecolor=fig.get_facecolor(), bbox_inches="tight")
print(f"# wrote {args.out}", file=sys.stderr)
