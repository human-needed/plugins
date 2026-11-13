#!/bin/sh
# HumanNeeded TEST cloud hook (test build, not for customers). Does nothing outside a cloud
# Claude VM (CLAUDE_CODE_REMOTE=true), so local sessions are untouched.
#
#   test.sh <working|needs|done|idle|end> <agent>     hook JSON on stdin
#
# States are POSTed to the HumanNeeded relay under this Claude account's key,
# sha256("humanneeded-account:" + the accountUuid in ~/.claude.json)[:32]. The user's computer
# works out the same key from its own .claude.json and listens for it. Each state carries a
# timestamp so the computer can drop late ones. Prints nothing, so the model isn't involved.
# Log: /tmp/hn-test/test.log (never contains the key). Always exits 0, within about 4 s.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ -n "${HN_TEST_SIMULATE:-}" ] || exit 0
RELAY_URL="${HN_TEST_RELAY_URL:-https://tcxdfuid4msoglniqenx2qhnza0gwwyq.lambda-url.us-east-2.on.aws}"
dir="${HN_TEST_DIR:-/tmp/hn-test}"

state="${1:-}"
agent="$(printf '%s' "${2:-claude}" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"
[ -n "$agent" ] || agent=claude

umask 077
mkdir -p "$dir" 2>/dev/null
if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then cat >/dev/null 2>&1; exit 0; fi
log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$1" >> "$dir/test.log" 2>/dev/null; }

# Hook input can be megabytes (tool output), so it goes to a file; the fields come from its start.
in="$dir/in.$$"
trap 'rm -f "$in" "$in.tmp"' EXIT
cat > "$in" 2>/dev/null
top="$(head -c 16384 "$in" 2>/dev/null | tr -d '\000\r\n')"
field() {   # first occurrence: the hook's own fields come before tool input and output
  printf '%s' "$top" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
sid="$(field session_id)"; event="$(field hook_event_name)"
[ -n "$sid" ] || sid=default

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r | cut -c1-64
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  fi
}
h="$(printf '%s' "$sid" | sha256_hex 2>/dev/null | cut -c1-16)"
printf '%s' "$h" | grep -Eq '^[0-9a-f]{16}$' || h=0000000000000000
now="$(date +%s)"; case "$now" in ''|*[!0-9]*) now=0;; esac
t="$(date +%s%3N 2>/dev/null)"; case "$t" in ''|*[!0-9]*) t="${now}000";; esac
[ "${#t}" -eq 13 ] || t="${now}000"

if [ -f "$dir/test.log" ] && [ "$(wc -c < "$dir/test.log" 2>/dev/null || echo 0)" -gt 200000 ]; then
  tail -n 400 "$dir/test.log" > "$dir/test.log.tmp" 2>/dev/null && mv -f "$dir/test.log.tmp" "$dir/test.log" 2>/dev/null
fi

cfg="${HN_TEST_CLAUDE_JSON:-$HOME/.claude.json}"
acct="$(grep -a -o '"accountUuid"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]\{36\}"' "$cfg" 2>/dev/null | head -n1 | sed 's/"$//; s/.*"//')"
key=""; why="no Claude account id in .claude.json"
if [ -n "$acct" ]; then
  key="$(printf '%s' "humanneeded-account:$acct" | sha256_hex 2>/dev/null | cut -c1-32)"; why="no sha256 tool on this machine"
fi
printf '%s' "$key" | grep -Eq '^[0-9a-f]{32}$' || key=""

delivered=""
case "$state" in
  working|needs|done|idle|end)
    if [ -z "$key" ]; then
      log "chat $h: $event $state not sent ($why)"
    elif ! command -v curl >/dev/null 2>&1; then
      log "chat $h: $event $state not sent (no curl on this machine)"
    else
      body="{\"v\":2,\"s\":\"$state\",\"a\":\"$agent\",\"h\":\"$h\",\"t\":$t}"
      try=1; again=""
      while :; do
        resp="$(curl -sS --connect-timeout 2 --max-time 3 -X POST -H 'content-type: application/json' --data-binary "$body"           -w ' http=%{http_code}' "$RELAY_URL/h/$key" 2>&1 | sed "s/$key/<key>/g" | tr '
' '  ' | cut -c1-200)"
        # The relay is briefly over its limit: these fail fast, so two more tries fit the time budget.
        case "$resp" in
          *http=429|*http=502|*http=503) [ "$try" -lt 3 ] || break; try=$((try + 1)); sleep "0.$(( ($$ + try) % 6 + 2 ))" 2>/dev/null || sleep 1;;
          # Nothing listening: the relay may only have tried the computer's old, dead connections
          # so one more try often gets through.
          *'"delivered":0'*|*'"delivered": 0'*) [ -z "$again" ] || break; again=1; try=$((try + 1));;
          *) break;;
        esac
      done
      [ "$try" -gt 1 ] && resp="$resp (try $try)"
      delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9][0-9]*\).*/\1/p')"
      log "chat $h: $event $state -> ${resp}"
    fi
    ;;
esac

exit 0
