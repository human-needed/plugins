#!/bin/sh
# Starts the HumanNeeded puck connector on macOS (hn-mcp.py) with a usable python3. Apple's
# /usr/bin/python3 is only a stub until the command line tools are installed, so it's skipped
# then (running it would pop up an install dialog).
dir="$(cd "$(dirname "$0")" && pwd)"
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$p" ] || continue
  if [ "$p" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
  exec "$p" "$dir/hn-mcp.py"
done
mkdir -p "$HOME/.humanneeded"
echo "$(date '+%Y-%m-%d %H:%M:%S')  mcp: no python3 found (install Apple's command line tools: xcode-select --install); puck connector not started" >> "$HOME/.humanneeded/hn.log"
exit 1
