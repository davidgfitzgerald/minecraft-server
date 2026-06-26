#!/usr/bin/env python3
"""
Chat bot — the Discord → Minecraft half of two-way chat.

It connects to the Discord Gateway (a realtime WebSocket, managed by discord.py:
IDENTIFY → heartbeat → DISPATCH, with automatic resume/reconnect) and listens for
human messages in #in-game-chat. Each one is injected into the running Bedrock
server with `docker exec bedrock send-command "tellraw @a ..."`, so what people type
in Discord appears in-game.

The OTHER direction (in-game chat → Discord) is NOT handled here — that's the
chat-bridge behavior pack posting to a webhook. This bot only carries Discord → game.

──────────────────────────────────────────────────────────────────────────────
Avoiding an infinite chat loop (the whole reason this is careful)

  The two directions form a potential cycle:
      in-game chat ──pack/webhook──▶ #in-game-chat ──this bot──▶ in-game (tellraw)
  If the bot re-injected the pack's own relayed lines, every in-game message would
  bounce straight back into the game (and look duplicated). Three guards stop that:

   1. Channel allowlist — only messages in IN_GAME_CHAT_CHANNEL_ID are considered.
   2. Ignore bots & webhooks — a message with `webhook_id` set is the chat-bridge
      pack's relay of an in-game line; `author.bot` covers this bot and any other.
      We drop both, so only GENUINE HUMAN Discord messages are ever injected.
   3. One-way injection — we inject with `tellraw`, which (unlike player chat) does
      NOT fire the Script API `chatSend` event, so an injected line is never relayed
      back out to Discord. Even if it somehow were, guard #2 would catch it.

  Net effect: human Discord message → game (once). Nothing it produces can feed back
  into Discord, and nothing the pack produces can feed back into the game. No loop.
──────────────────────────────────────────────────────────────────────────────

Reads from the gitignored .env: CHAT_BOT_TOKEN, IN_GAME_CHAT_CHANNEL_ID.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import discord

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONTAINER = os.environ.get("CONTAINER", "bedrock")
MAX_LEN = 256  # cap an injected message so a wall of text can't flood the game
PREFIX = "!"  # chat-command prefix (shared with the in-game chat-bridge pack)
JUST = shutil.which("just") or "/opt/homebrew/bin/just"
MAILDIR = PROJECT_ROOT / "bedrock-data" / "mailbox"


def load_env() -> dict:
    """Minimal .env reader (no extra dependency). Real environment wins over the file."""
    env: dict[str, str] = {}
    f = PROJECT_ROOT / ".env"
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            # strip a trailing inline comment ("value   # note") — tokens/ids/URLs
            # contain no whitespace, so only whitespace-then-# is treated as a comment.
            val = re.split(r"\s+#", val, maxsplit=1)[0].strip().strip('"').strip("'")
            env.setdefault(key, val)
    env.update(os.environ)
    return env


def inject_to_minecraft(author: str, content: str) -> bool:
    """Show one Discord line in-game via tellraw. json.dumps handles all escaping."""
    line = f"§9[Discord] §b{author}§r§7: §f{content}"
    payload = json.dumps({"rawtext": [{"text": line}]}, ensure_ascii=True)
    try:
        subprocess.run(
            ["docker", "exec", CONTAINER, "send-command", f"tellraw @a {payload}"],
            check=True, capture_output=True, timeout=10,
        )
        return True
    except Exception as e:  # container down / send-command failed / timeout
        print(f"chat-bot: inject failed: {e}", flush=True)
        return False


# ── chat commands (same set as the in-game chat-bridge pack) ────────────────────
# Player-specific commands take an explicit <player> from Discord because there's no
# clean Discord→gamertag mapping. These run blocking host work (docker / just / files),
# so on_message dispatches them via run_in_executor to keep the gateway responsive.

def _sanitize_key(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", name) or "_"


def _coords_of(player: str) -> str:
    """Look up an online player's coords. Bedrock has no 'get coords' command, so we run
    `querytarget` (it prints a JSON blob incl. position to the server log) and scrape it."""
    safe = re.sub(r"[^A-Za-z0-9 _.-]", "", player)[:32].strip()
    if not safe:
        return "Give a player name: `!coords <player>`."
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    try:
        subprocess.run(["docker", "exec", CONTAINER, "send-command", f'querytarget @a[name="{safe}"]'],
                       check=True, capture_output=True, timeout=10)
    except Exception:
        return "Couldn't reach the server."
    time.sleep(0.6)  # let the console response land in the log
    try:
        out = subprocess.run(["docker", "logs", "--since", f"{since}Z", CONTAINER],
                             capture_output=True, text=True, timeout=10)
        blob = (out.stdout or "") + (out.stderr or "")
    except Exception:
        return "Couldn't read the server output."
    m = re.search(
        r'"position"\s*:\s*\{\s*"x"\s*:\s*(-?\d+(?:\.\d+)?)\s*,\s*"y"\s*:\s*(-?\d+(?:\.\d+)?)\s*,\s*"z"\s*:\s*(-?\d+(?:\.\d+)?)',
        blob,
    )
    if not m:
        return f"No online player named **{safe}** (or no position returned)."
    x, y, z = (round(float(v)) for v in m.groups())
    return f"📍 **{safe}** is at `{x}, {y}, {z}`."


def _backup_request(who: str) -> str:
    """Rate-limited, lock-guarded backup via the shared `just _backup-request` recipe."""
    try:
        r = subprocess.run([JUST, "_backup-request", who], cwd=str(PROJECT_ROOT),
                           capture_output=True, text=True, timeout=180)
    except Exception as e:
        print(f"chat-bot: backup request failed: {e}", flush=True)
        return "⚠️ Couldn't run the backup."
    line = ""
    for ln in (r.stdout or "").splitlines():
        ln = ln.strip()
        if ln.split(" ", 1)[0] in ("OK", "RATELIMIT", "BUSY", "ERR"):
            line = ln
    parts = line.split()
    tag = parts[0] if parts else "ERR"
    if tag == "OK":
        name = parts[1] if len(parts) > 1 else "snapshot"
        size = parts[2] if len(parts) > 2 else "?"
        return f"🗄️ Backup saved — `{name}` ({size})."
    if tag == "RATELIMIT":
        rem = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        return f"⏳ You backed up recently — try again in {rem // 60}m {rem % 60}s."
    if tag == "BUSY":
        return "⏳ A backup is already running — try again in a moment."
    return "⚠️ Backup failed — ask an admin to check the server."


def _map_request(who: str) -> str:
    """Render the overworld map and post it to #map, via the shared `just _map-request`."""
    try:
        r = subprocess.run([JUST, "_map-request", who], cwd=str(PROJECT_ROOT),
                           capture_output=True, text=True, timeout=240)
    except Exception as e:
        print(f"chat-bot: map request failed: {e}", flush=True)
        return "⚠️ Couldn't render the map."
    line = ""
    for ln in (r.stdout or "").splitlines():
        ln = ln.strip()
        if ln.split(" ", 1)[0] in ("OK", "RATELIMIT", "BUSY", "ERR"):
            line = ln
    parts = line.split()
    tag = parts[0] if parts else "ERR"
    if tag == "OK":
        return "🗺️ Posted a fresh survey of the realm to **#map**."
    if tag == "RATELIMIT":
        rem = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        return f"⏳ A map was just rendered — try again in {rem // 60}m {rem % 60}s."
    if tag == "BUSY":
        return "⏳ A map is already rendering — hang tight."
    return "⚠️ Map render/post failed — ask an admin to check the server."


def _doctor() -> str:
    try:
        r = subprocess.run(["./scripts/doctor.sh", "--brief"], cwd=str(PROJECT_ROOT),
                           capture_output=True, text=True, timeout=30)
        out = (r.stdout or "").strip().splitlines()
        return "🩺 " + (out[-1] if out else "no output")
    except Exception as e:
        print(f"chat-bot: doctor failed: {e}", flush=True)
        return "⚠️ Couldn't run the health check."


def _mail_add(to: str, frm: str, msg: str) -> str:
    msg = msg.replace("\t", " ").replace("\n", " ").strip()
    if not to.strip() or not msg:
        return "Usage: `!mail <player> <message>`."
    try:
        MAILDIR.mkdir(parents=True, exist_ok=True)
        box = MAILDIR / f"{_sanitize_key(to.strip())}.txt"
        with box.open("a", encoding="utf-8") as f:
            f.write(f"{frm}\t{msg}\n")
    except Exception as e:
        print(f"chat-bot: mail store failed: {e}", flush=True)
        return "⚠️ Couldn't queue the mail."
    return f"✉️ Mail queued for **{to.strip()}** — delivered on their next join."


def handle_command(content: str, author: str, author_id: int) -> str:
    parts = content[len(PREFIX):].split()
    name = parts[0].lower() if parts else ""
    args = parts[1:]
    if name in ("commands", "help"):
        return ("**Commands:** `!commands`, `!coords <player>`, `!backup`, `!map`, "
                "`!doctor`, `!shrug`, `!mail <player> <msg>`")
    if name == "coords":
        if not args:
            return "From Discord, name the player: `!coords <player>` (in-game just type `!coords`)."
        return _coords_of(args[0])
    if name == "backup":
        return _backup_request(f"discord:{author_id}")
    if name == "map":
        return _map_request(f"discord:{author}")
    if name == "doctor":
        return _doctor()
    if name == "shrug":
        inject_to_minecraft(author, "¯\\_(ツ)_/¯")
        return "¯\\_(ツ)_/¯"
    if name == "mail":
        if len(args) < 2:
            return "Usage: `!mail <player> <message>`."
        return _mail_add(args[0], author, " ".join(args[1:]))
    return f"Unknown command `!{name}` — try `!commands`."


def main() -> None:
    env = load_env()
    token = env.get("CHAT_BOT_TOKEN", "").strip()
    try:
        channel_id = int(env.get("IN_GAME_CHAT_CHANNEL_ID", "0") or "0")
    except ValueError:
        channel_id = 0
    if not token or not channel_id:
        print("chat-bot: set CHAT_BOT_TOKEN and IN_GAME_CHAT_CHANNEL_ID in .env", flush=True)
        sys.exit(1)
    try:
        map_channel_id = int(env.get("MAP_CHANNEL_ID", "0") or "0")
    except ValueError:
        map_channel_id = 0
    # commands are accepted in #in-game-chat AND #map; free-text chat is relayed in-game
    # ONLY from #in-game-chat (so #map doesn't pipe channel chatter into the world).
    cmd_channels = {channel_id, map_channel_id} - {0}

    intents = discord.Intents.default()
    intents.message_content = True  # privileged — must also be enabled in the dev portal

    client = discord.Client(intents=intents)
    tree = discord.app_commands.CommandTree(client)  # native Discord `/` slash commands

    # ── slash commands (the `/` front-end) — thin wrappers over the SAME helpers the `!`
    # text commands use, so the two stay in sync and `!` keeps working everywhere. Host
    # work (map/backup/coords) can exceed Discord's 3s ack window, so we defer first and
    # follow up when it finishes.
    async def _slash_run(interaction, fn, *args):
        await interaction.response.defer(thinking=True)
        try:
            reply = await client.loop.run_in_executor(None, fn, *args)
        except Exception as e:
            print(f"chat-bot: slash handler error: {e}", flush=True)
            reply = "⚠️ Command failed."
        await interaction.followup.send(reply)

    @tree.command(name="map", description="Render the overworld and post it to #map")
    async def slash_map(interaction: discord.Interaction):
        await _slash_run(interaction, _map_request, f"discord:{interaction.user.display_name}")

    @tree.command(name="backup", description="Take a consistent world backup (rate-limited)")
    async def slash_backup(interaction: discord.Interaction):
        await _slash_run(interaction, _backup_request, f"discord:{interaction.user.id}")

    @tree.command(name="doctor", description="Server health: players, CPU, memory, tunnel")
    async def slash_doctor(interaction: discord.Interaction):
        await _slash_run(interaction, _doctor)

    @tree.command(name="coords", description="Show an online player's coordinates")
    @discord.app_commands.describe(player="Gamertag of an online player")
    async def slash_coords(interaction: discord.Interaction, player: str):
        await _slash_run(interaction, _coords_of, player)

    @tree.command(name="mail", description="Leave mail for a player (delivered on their next join)")
    @discord.app_commands.describe(player="Recipient gamertag", message="What to tell them")
    async def slash_mail(interaction: discord.Interaction, player: str, message: str):
        await _slash_run(interaction, _mail_add, player, interaction.user.display_name, message)

    @tree.command(name="shrug", description="¯\\_(ツ)_/¯ — posts in Discord and in-game")
    async def slash_shrug(interaction: discord.Interaction):
        def _do():
            inject_to_minecraft(interaction.user.display_name, "¯\\_(ツ)_/¯")
            return "¯\\_(ツ)_/¯"
        await _slash_run(interaction, _do)

    @client.event
    async def on_ready():
        print(f"chat-bot: connected as {client.user} — relay #{channel_id} → Minecraft; "
              f"commands in {sorted(cmd_channels)}", flush=True)
        # register the slash commands. A guild-scoped sync appears instantly; resolve the
        # guild from a known channel, else fall back to a (slow, ~1h) global sync.
        try:
            ch = client.get_channel(channel_id) or client.get_channel(map_channel_id)
            guild = ch.guild if ch is not None else None
            if guild is not None:
                tree.copy_global_to(guild=guild)
                synced = await tree.sync(guild=guild)
                print(f"chat-bot: synced {len(synced)} slash command(s) to '{guild.name}'", flush=True)
            else:
                synced = await tree.sync()
                print(f"chat-bot: globally synced {len(synced)} slash command(s) (~1h to appear)", flush=True)
        except Exception as e:
            print(f"chat-bot: slash sync failed: {e}", flush=True)

    @client.event
    async def on_message(message: discord.Message):
        # --- loop / echo guards (see module docstring) ---
        if message.channel.id not in cmd_channels:   # 1. only #in-game-chat / #map
            return
        if message.author.bot or message.webhook_id is not None:  # 2. drop bots + webhook relays
            return
        if client.user and message.author.id == client.user.id:
            return

        content = (message.content or "").replace("\n", " ").replace("\r", " ").strip()
        if content.startswith(PREFIX):  # a chat command — works in BOTH channels; never relayed
            reply = await client.loop.run_in_executor(
                None, handle_command, content, message.author.display_name, message.author.id)
            await message.channel.send(reply)
            print(f"chat-bot: cmd from {message.author.display_name} in #{message.channel}: {content}", flush=True)
            return
        if message.channel.id != channel_id:  # free-text only relays from #in-game-chat, not #map
            return
        if not content:
            if message.attachments:
                content = "[sent an attachment]"
            else:
                return  # nothing relayable (e.g. an embed-only message)
        if len(content) > MAX_LEN:
            content = content[: MAX_LEN - 1] + "…"

        author = message.author.display_name
        ok = inject_to_minecraft(author, content)
        print(f"chat-bot: {'→ injected' if ok else '✗ dropped'}: {author}: {content}", flush=True)

    # discord.py owns the Gateway WebSocket: connect, heartbeat, resume, reconnect.
    client.run(token, log_handler=None)


if __name__ == "__main__":
    main()
