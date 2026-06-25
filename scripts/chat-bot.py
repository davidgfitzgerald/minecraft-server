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
import subprocess
import sys
from pathlib import Path

import discord

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONTAINER = os.environ.get("CONTAINER", "bedrock")
MAX_LEN = 256  # cap an injected message so a wall of text can't flood the game


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

    intents = discord.Intents.default()
    intents.message_content = True  # privileged — must also be enabled in the dev portal

    client = discord.Client(intents=intents)

    @client.event
    async def on_ready():
        print(f"chat-bot: connected as {client.user} — relaying channel {channel_id} → Minecraft", flush=True)

    @client.event
    async def on_message(message: discord.Message):
        # --- loop / echo guards (see module docstring) ---
        if message.channel.id != channel_id:        # 1. only #in-game-chat
            return
        if message.author.bot or message.webhook_id is not None:  # 2. drop bots + webhook relays
            return
        if client.user and message.author.id == client.user.id:
            return

        content = (message.content or "").replace("\n", " ").replace("\r", " ").strip()
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
