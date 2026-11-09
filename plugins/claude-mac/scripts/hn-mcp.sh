#!/bin/sh
# Starts the HumanNeeded puck connector on macOS (hn-mcp.py) with a usable python3. Apple's
# /usr/bin/python3 is only a stub until the command line tools are installed, so it's skipped
# then (running it would pop up an install dialog).
#
# Without python3 it stays up as a connector with no tools, so the Claude app shows it as
# connected rather than failed: local sessions still drive the puck through hn.sh; only cloud
# sessions can't reach it. The reason goes to ~/.humanneeded/hn.log.
dir="$(cd "$(dirname "$0")" && pwd)"
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$p" ] || continue
  if [ "$p" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
  exec "$p" "$dir/hn-mcp.py"
done

mkdir -p "$HOME/.humanneeded" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S')  mcp: no python3 (install Apple's command line tools: xcode-select --install), so cloud sessions can't reach the puck" >> "$HOME/.humanneeded/hn.log"

# Minimal MCP server: answers initialize, tools/list (empty) and ping; ignores notifications.
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+).*/\1/p')"
  [ -n "$id" ] || continue
  method="$(printf '%s' "$line" | sed -nE 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
  case "$method" in
    initialize)
      pv="$(printf '%s' "$line" | sed -nE 's/.*"protocolVersion"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":{"tools":{}},"serverInfo":{"name":"humanneeded","version":"no-python3"}}}\n' "$id" "${pv:-2025-06-18}" ;;
    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\n' "$id" ;;
    ping) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"no method %s"}}\n' "$id" "$method" ;;
  esac
done
exit 0
