#!/usr/bin/env python3
"""On player join, record gamertag → account uniqueId in the gitignored map
(bedrock-data/player-map.json) so offline `/coords` can resolve their saved position later.

Called by scripts/notify.sh from its "Player Spawned" hook with the gamertag as argv[1].
Cheap and host-only: it runs `querytarget` (whose reply carries the player's `uniqueId` —
the account UUID that bridges to their `player_server_` save record) and updates the JSON.
It does NO world-DB read here (that needs a heavy db copy); the uniqueId → ServerId → Pos
hop is done lazily by saved_pos.py at lookup time, when the db is already being read.

Stdlib only. Defensive: it must never raise — a hiccup here must not disturb the watcher.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONTAINER = os.environ.get("CONTAINER", "bedrock")
MAP_FILE = PROJECT_ROOT / "bedrock-data" / "player-map.json"


def _query_unique_id(gamertag: str):
    """Ask the running server for the player's uniqueId via querytarget; None on miss."""
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    try:
        subprocess.run(["docker", "exec", CONTAINER, "send-command",
                        f'querytarget @a[name="{gamertag}"]'],
                       check=True, capture_output=True, timeout=10)
    except Exception:
        return None
    time.sleep(0.8)  # let the console response land in the log
    try:
        out = subprocess.run(["docker", "logs", "--since", f"{since}Z", CONTAINER],
                             capture_output=True, text=True, timeout=10)
        blob = (out.stdout or "") + (out.stderr or "")
    except Exception:
        return None
    m = re.search(r'"uniqueId"\s*:\s*"([0-9a-fA-F-]{36})"', blob)
    return m.group(1).lower() if m else None


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        return
    gamertag = sys.argv[1].strip()
    uid = _query_unique_id(gamertag)
    if not uid:
        print(f"capture-map: no uniqueId for {gamertag} (left already?) — skipped", flush=True)
        return
    try:
        mapping = json.loads(MAP_FILE.read_text()) if MAP_FILE.exists() else {}
        if not isinstance(mapping, dict):
            mapping = {}
    except Exception:
        mapping = {}
    if mapping.get(gamertag) == uid:
        return  # already current — no rewrite, no churn
    mapping[gamertag] = uid
    try:
        MAP_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = MAP_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
        tmp.replace(MAP_FILE)  # atomic swap
        print(f"capture-map: {gamertag} -> {uid}", flush=True)
    except Exception as e:
        print(f"capture-map: write failed for {gamertag}: {e}", flush=True)


if __name__ == "__main__":
    main()
