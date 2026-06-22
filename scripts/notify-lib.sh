#!/bin/sh
# Shared event publisher for the Minecraft notify/alert system. POSIX-sh compatible
# (sourced by the alpine `monitor` container's /bin/sh as well as host bash).
#
# publish_bus() POSTs an event to the ntfy.sh "bus" topic, which fans out to every
# subscriber: the iPhone app, the Discord bridge, and any `curl .../json` listener.
#
# Config (env, or auto-loaded from .env on the host):
#   NTFY_TOPIC    required for any push to happen
#   NTFY_SERVER   default https://ntfy.sh
#   NOTIFY_TITLE  notification title (default "Minecraft")
#
#   publish_bus <message> [priority] [tags]
#     priority : min|low|default|high|urgent   (default "default")
#     tags     : comma-separated ntfy emoji shortcodes (default "bell")

# auto-load NTFY_TOPIC from .env if present and not already set (host convenience)
if [ -z "${NTFY_TOPIC:-}" ] && [ -f .env ]; then
  NTFY_TOPIC="$(grep -E '^NTFY_TOPIC=' .env 2>/dev/null | cut -d= -f2- || true)"
fi

publish_bus() {
  _msg="$1"; _prio="${2:-default}"; _tags="${3:-bell}"
  [ -n "${NTFY_TOPIC:-}" ] || { echo "→ (no NTFY_TOPIC; not published) $_msg"; return 0; }
  _url="${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC"
  _title="${NOTIFY_TITLE:-Minecraft}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -H "Title: $_title" -H "Priority: $_prio" -H "Tags: $_tags" \
      -d "$_msg" "$_url" >/dev/null 2>&1 || echo "   (publish_bus: ntfy POST failed)"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O- --header="Title: $_title" --header="Priority: $_prio" \
      --header="Tags: $_tags" --post-data="$_msg" "$_url" >/dev/null 2>&1 \
      || echo "   (publish_bus: ntfy POST failed)"
  else
    echo "   (publish_bus: neither curl nor wget available)"; return 1
  fi
  echo "→ bus[$_prio]: $_msg"
}
