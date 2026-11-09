#!/bin/bash
# HumanNeeded host script for macOS (built-in bash 3.2, no installs).
#
#   hn.sh <working|needs|done|idle|end> [agent]   reads hook JSON on stdin for session_id
#   hn.sh set <key> <value> | get <key|all> | mute <minutes> | test <state> | hello | status | clear
#
# Same protocol as hn.ps1: one line to the puck over USB serial, one line back.
# Always exits 0 within ~2 s and is silent for agent events, except one check line on
# UserPromptSubmit that says where the hook ran (on this Mac, or in a cloud VM).
# Every run adds a line to ~/.humanneeded/hn.log.

VERSION=0.1.22
os="$(uname -s)"
dir="$HOME/.humanneeded"
log="$dir/hn.log"
cache="$dir/port"
start_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }
t0="$(start_ms)"

cmd="$(printf '%s' "${1:-hello}" | tr 'A-Z' 'a-z')"
shift 2>/dev/null
case "$cmd" in working|needs|done|idle|end) is_event=1 ;; *) is_event=0 ;; esac

# Hook JSON on stdin (events only).
input=""
if [ "$is_event" = 1 ] && [ ! -t 0 ]; then input="$(cat 2>/dev/null)"; fi
json_field() { printf '%s' "$input" | tr -d '\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
session_id="$(json_field session_id | tr -d '[:space:]')"
event_name="$(json_field hook_event_name)"
[ -n "$session_id" ] || session_id=default

where="$(hostname -s 2>/dev/null || hostname) ($os), entrypoint ${CLAUDE_CODE_ENTRYPOINT:-none}, remote ${CLAUDE_CODE_REMOTE:-none}"

# Not a Mac: a cloud VM (Linux) or Windows. Nothing to drive here; say so on the
# prompt hook so a cloud test shows where the hook ran, then stop.
if [ "$os" != "Darwin" ]; then
  # Cloud Claude VM: send the state through the HumanNeeded relay to the PC (test, 0.1.22).
  if [ "$is_event" = 1 ] && [ "$os" = "Linux" ] && [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    sh "$(dirname "$0")/relay.sh" "$cmd" "${1:-claude}" "$session_id" "$event_name"
    exit 0
  fi
  if [ "$is_event" = 1 ]; then
    { date -u +%FT%TZ; echo "$cmd $session_id event=$event_name on $where"; } >> /tmp/hn-hook-check.log 2>/dev/null
    [ "$event_name" = "UserPromptSubmit" ] && echo "HumanNeeded $VERSION hook check: ran on $where, not a Mac, puck skipped"
  fi
  exit 0
fi

# Serial ports of plugged-in pucks: USB devices whose serial number starts with "HN".
find_ports() {
  ls /dev/cu.usbmodemHN* 2>/dev/null
  ioreg -r -l -c IOUSBHostDevice 2>/dev/null | awk '
    /"USB Serial Number" = "/ { s = $0; sub(/.*"USB Serial Number" = "/, "", s); sub(/".*/, "", s); serial = s }
    /"IOCalloutDevice" = "/ { p = $0; sub(/.*"IOCalloutDevice" = "/, "", p); sub(/".*/, "", p); if (serial ~ /^HN/) print p }'
}

elapsed() { echo $(( $(start_ms) - t0 )); }

# Sends one line to a port and prints the reply line (empty if none).
send_line() {
  local port="$1" line="$2" left reply=""
  left=$(( (2000 - $(elapsed)) / 1000 )); [ "$left" -lt 1 ] && left=1
  exec 3<>"$port" 2>/dev/null || return 1
  stty 115200 raw -echo <&3 2>/dev/null
  printf '%s\n' "$line" >&3
  IFS= read -r -t "$left" reply <&3
  exec 3<&- 3>&-
  printf '%s' "$reply" | tr -d '\r'
  return 0
}

# Tries the cached port, then re-discovers; retries briefly if a port is busy.
send_to_puck() {
  local line="$1" cached="" port reply
  [ -f "$cache" ] && cached="$(tr -d '[:space:]' < "$cache")"
  while [ "$(elapsed)" -lt 2000 ]; do
    local ports
    ports="$( { [ -n "$cached" ] && [ -e "$cached" ] && echo "$cached"; find_ports; } | awk 'NF && !seen[$0]++')"
    [ -n "$ports" ] || return 1
    for port in $ports; do
      if reply="$(send_line "$port" "$line")"; then
        if [ "$port" != "$cached" ]; then mkdir -p "$dir"; echo "$port" > "$cache"; fi
        printf '%s' "$reply"
        return 0
      fi
      [ "$port" = "$cached" ] && cached=""
    done
    sleep 0.15
  done
  return 1
}

write_log() {
  mkdir -p "$dir" 2>/dev/null
  printf '%s  %s  -> %s  (%s ms, %s, %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${2:-no puck}" "$(elapsed)" \
    "$where" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)" >> "$log" 2>/dev/null
  if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt 65536 ]; then
    tail -n 200 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
  fi
}

if [ "$is_event" = 1 ]; then
  line="EV $cmd $session_id ${1:-claude}"
  reply="$(send_to_puck "$line")"
  write_log "$line" "$reply"
  if [ "$event_name" = "UserPromptSubmit" ]; then
    echo "HumanNeeded $VERSION hook check: ran on $where, puck: ${reply:-not found}"
  fi
  exit 0
fi

case "$cmd" in
  set)    line="SET $1 $2" ;;
  get)    line="GET ${1:-all}" ;;
  mute)   line="MUTE $1" ;;
  test)   line="TEST $1" ;;
  hello)  line="HELLO" ;;
  status) line="STATUS" ;;
  clear)  line="CLEAR" ;;
  *) echo 'usage: hn.sh <working|needs|done|idle|end> [agent] | set <k> <v> | get <k|all> | mute <min> | test <state> | hello | status | clear'; exit 0 ;;
esac
reply="$(send_to_puck "$line")"
write_log "$line" "$reply"
echo "${reply:-HumanNeeded puck not found (is it plugged in?)}"
exit 0
