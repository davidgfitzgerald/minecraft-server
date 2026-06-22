# World / player-data tools

Utilities for inspecting and editing the Bedrock world's player data
(`bedrock-data/worlds/<level>/db`, a Mojang LevelDB).

They run inside a throwaway `python:3.11` container with
[`amulet-leveldb`](https://pypi.org/project/amulet-leveldb/) (Mojang's LevelDB
fork) so nothing needs installing on the Mac. `--platform linux/amd64` is used
because the prebuilt wheels are most reliable there.

The NBT inside each player record is little-endian, uncompressed; these scripts
parse it directly (no external NBT lib needed).

## Scripts

| Script | Purpose |
|---|---|
| `profile_report.py` | Full human-readable report: every character's inventory, armor, XP, enchantments. |
| `account_map.py` | Dumps the account→profile mapping records (`MsaId` / `PlatformOnlineId` / `ServerId`). |
| `apply_profile.py` | Copies one character's full data onto another's profile key (`SRC_KEY`→`DST_KEY`). Server must be stopped. |
| `restore_profile.py` | Restores `DST_KEY` from the snapshot `apply_profile.py` saved. Server must be stopped. |

## Read-only: generate the profile report

Safe to run while the server is up (it reads a **copy** of the db):

```bash
cd /path/to/minecraft-server
LIVE="bedrock-data/worlds/${LEVEL_NAME}/db"
/bin/rm -rf bedrock-data/_live_db && cp -a "$LIVE" bedrock-data/_live_db   # note: /bin/rm — `rm` is aliased to `trash`
docker run --rm --platform linux/amd64 \
  -v "$PWD/bedrock-data/_live_db":/db \
  -v "$PWD/scripts/profile_report.py":/work/profile_report.py:ro \
  python:3.11 bash -c "pip install -q amulet-leveldb 2>/dev/null && python /work/profile_report.py" \
  > player-profiles-report.md
```

## Read-write: transfer a character onto another profile

The world LevelDB can't be open twice, so **stop the server first**. Mount the
**real** world db (not a copy) read-write, plus `bedrock-data` as `/out` for the
safety snapshot.

```bash
cd /path/to/minecraft-server
WORLD_DB="$PWD/bedrock-data/worlds/${LEVEL_NAME}/db"

docker compose stop bedrock
docker run --rm --platform linux/amd64 \
  -e SRC_KEY="player_server_<source-uuid>" \
  -e DST_KEY="player_server_<destination-uuid>" \
  -v "$WORLD_DB":/db \
  -v "$PWD/bedrock-data":/out \
  -v "$PWD/scripts/apply_profile.py":/work/apply_profile.py:ro \
  python:3.11 bash -c "pip install -q amulet-leveldb 2>/dev/null && python /work/apply_profile.py"
docker compose start bedrock
```

To undo, run the same pattern with `restore_profile.py` (only `DST_KEY` needed).

## Finding profile keys

Run `just accounts` (account → profile mapping) or `just audit` (every key in the world DB)
to list the `player_server_<uuid>` keys and see which belongs to which player — then use
those as `SRC_KEY` / `DST_KEY` above.

## Always back up first

```bash
TS=$(date +%Y%m%d-%H%M%S)
cp -a "bedrock-data/worlds/${LEVEL_NAME}" \
      "bedrock-data/backups/${LEVEL_NAME}_$TS"
```
