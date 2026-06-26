#!/usr/bin/env python3
"""Build a players.json of ONLINE players (gamertag + live position) for the map overlay.

The world DB stores no gamertags or xuids — only opaque ids — so an *offline* player's
saved position can't be tied back to a name. The running server, however, knows both:
`list` gives the online gamertags, and `querytarget` reports each one's live position.
So this queries the live server and emits ONLY online players, labelled with their real
gamertags. Offline players are intentionally omitted (we can't name them).

    python3 scripts/online_players.py [out.json]      # default: print to stdout

Output: [{"id": "<gamertag>", "dim": <int>, "pos": [x, y, z]}, ...]   (overworld dim == 0)
Runs on the HOST (needs docker). Stdlib only — no deps, any python3.
Gamertags are runtime data; the output lands in gitignored scratch + a private Discord post.
"""
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

CONTAINER = "bedrock"
MAX_PLAYERS = 30  # safety cap


def _send(cmd: str) -> bool:
    try:
        subprocess.run(["docker", "exec", CONTAINER, "send-command", cmd],
                       check=True, capture_output=True, timeout=10)
        return True
    except Exception:
        return False


def _logs_since(since: str) -> str:
    try:
        out = subprocess.run(["docker", "logs", "--since", f"{since}Z", CONTAINER],
                             capture_output=True, text=True, timeout=10)
        return (out.stdout or "") + (out.stderr or "")
    except Exception:
        return ""


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def online_names() -> list:
    """Parse `list` output → the online gamertags (the names line follows 'players online:')."""
    since = _now()
    if not _send("list"):
        return []
    time.sleep(0.6)
    blob = _logs_since(since)
    # find "...players online:" then the names on the remainder/next line(s)
    m = re.search(r"players online:\s*(.*)", blob, re.DOTALL)
    if not m:
        return []
    tail = m.group(1)
    # the names are the first non-empty line after the header; strip any "[ts INFO]" prefix
    for line in tail.splitlines():
        line = re.sub(r"^\[[^\]]*\]\s*", "", line).strip()
        if not line:
            continue
        names = [n.strip() for n in line.split(",") if n.strip()]
        # guard against accidentally grabbing another log line (names have no log keywords)
        if names and not any(re.search(r"INFO|WARN|player", n) for n in names):
            return names[:MAX_PLAYERS]
        break
    return []


def position_of(name: str):
    """querytarget one player by name → (dim, [x,y,z]) or None."""
    safe = re.sub(r'[^A-Za-z0-9 _.-]', "", name)[:32].strip()
    if not safe:
        return None
    since = _now()
    if not _send(f'querytarget @a[name="{safe}"]'):
        return None
    time.sleep(0.6)
    blob = _logs_since(since)
    pm = re.search(
        r'"position"\s*:\s*\{\s*"x"\s*:\s*(-?\d+(?:\.\d+)?)\s*,'
        r'\s*"y"\s*:\s*(-?\d+(?:\.\d+)?)\s*,\s*"z"\s*:\s*(-?\d+(?:\.\d+)?)',
        blob,
    )
    if not pm:
        return None
    dm = re.search(r'"dimension"\s*:\s*(\d+)', blob)
    dim = int(dm.group(1)) if dm else 0
    pos = [float(pm.group(1)), float(pm.group(2)), float(pm.group(3))]
    return dim, pos


def main():
    players = []
    for name in online_names():
        r = position_of(name)
        if r is None:
            continue
        dim, pos = r
        players.append({"id": name, "dim": dim, "pos": pos})
    out = json.dumps(players)
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write(out)
        print(f"online_players: wrote {len(players)} online player(s) → {sys.argv[1]}",
              file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
