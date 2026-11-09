#!/bin/sh
# HumanNeeded cloud relay sender. Runs inside a cloud Claude VM (Linux with
# CLAUDE_CODE_REMOTE=true); hn.sh calls it there and nowhere else, so local sessions never use
# the relay and states aren't sent twice.
#
#   relay.sh <working|needs|done|idle|end> <agent> <session_id> <event_name>
#
# POSTs {"s":state,"h":key,"u":session hash,"t":unix time,"a":agent} to the HumanNeeded relay at
# /h/<key>, where key = sha256("humanneeded-account:" + the accountUuid in ~/.claude.json)[:32].
# The user's computer computes the same key from its own .claude.json and listens for it, so the
# relay delivers only there. Nothing is saved in the VM except a line in /tmp/hn-relay.log.
# Silent, except one note per session on UserPromptSubmit when states aren't getting through.
# Always exits 0.

RELAY_URL="${HN_RELAY_URL:-https://tcxdfuid4msoglniqenx2qhnza0gwwyq.lambda-url.us-east-2.on.aws}"

state="$1"; agent="${2:-claude}"; session_id="${3:-default}"; event_name="$4"

sha256_hex() { # stdin -> hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r | cut -c1-64
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; fi
}

# Tells the model once per session and outcome, on the prompt hook only.
note() {
  [ "$event_name" = "UserPromptSubmit" ] || exit 0
  mark="/tmp/hn-note-$short-$1"
  [ -f "$mark" ] && exit 0
  : > "$mark" 2>/dev/null
  echo "HumanNeeded desk light: $2 No action needed."
  exit 0
}

agent="$(printf '%s' "$agent" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"
short="$(printf '%s' "$session_id" | sha256_hex | cut -c1-16)"
printf '%s' "$short" | grep -Eq '^[0-9a-f]{16}$' || exit 0

acct="$(grep -o '"accountUuid" *: *"[0-9a-fA-F-]*"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed 's/.*"\([0-9a-fA-F-]*\)"$/\1/')"
[ -n "$acct" ] || note noacct "this cloud session has no Claude account id, so its states can't reach the user's puck."
key="$(printf '%s' "humanneeded-account:$acct" | sha256_hex | cut -c1-32)"

body="{\"s\":\"$state\",\"h\":\"$key\",\"u\":\"$short\",\"t\":$(date +%s),\"a\":\"${agent:-claude}\"}"
resp="$(curl -sS --max-time 4 -X POST -H 'content-type: application/json' \
  --data-binary "$body" -w ' http=%{http_code}' "$RELAY_URL/h/$key" 2>&1)"
{ date -u +%FT%TZ; echo "$state $short -> $resp"; } >> /tmp/hn-relay.log 2>/dev/null

delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9]*\).*/\1/p')"
if [ -z "$delivered" ]; then
  note unreachable "the relay couldn't be reached ($(printf '%s' "$resp" | tr '\r\n' '  ' | cut -c1-200))."
elif [ "$delivered" -eq 0 ]; then
  note nopc "no computer of this Claude account is listening (the Claude app with the humanneeded plugin isn't running there)."
fi
exit 0
