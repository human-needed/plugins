#!/bin/sh
# HumanNeeded cloud relay sender (test, 0.1.17). Runs inside a cloud Claude VM (Linux with
# CLAUDE_CODE_REMOTE=true); hn.sh calls it there and nowhere else, so local sessions never use
# the relay and states aren't sent twice.
#
#   relay.sh <working|needs|done|idle|end> <agent> <session_id> <event_name>
#
# Signs {"s":state,"h":sha256(session_id)[:16],"t":unix time,"a":agent} with the channel's
# HMAC secret and POSTs it to the relay, which forwards it to the PC's local connector.
# The token "hn1.<channel>.<secret>" comes from, in order: the plugin option "relay"
# (CLAUDE_PLUGIN_OPTION_RELAY), the env var HN_RELAY, or the file ~/.humanneeded/relay.
# Prints one status line on UserPromptSubmit; silent otherwise. Always exits 0.

VERSION=0.1.17
RELAY_URL="${HN_RELAY_URL:-https://kc83ahbdf2.execute-api.us-east-2.amazonaws.com}"

state="$1"; agent="${2:-claude}"; session_id="${3:-default}"; event_name="$4"
say() { [ "$event_name" = "UserPromptSubmit" ] && echo "HumanNeeded $VERSION relay: $*"; exit 0; }

token=""; src=""
if [ -n "${CLAUDE_PLUGIN_OPTION_RELAY:-}" ]; then token="$CLAUDE_PLUGIN_OPTION_RELAY"; src="plugin option"
elif [ -n "${HN_RELAY:-}" ]; then token="$HN_RELAY"; src="env HN_RELAY"
elif [ -f "$HOME/.humanneeded/relay" ]; then token="$(tr -d '[:space:]' < "$HOME/.humanneeded/relay")"; src="~/.humanneeded/relay"
fi
opts="$(env | sed -n 's/^\(CLAUDE_PLUGIN_OPTION_[A-Z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
[ -n "$token" ] || say "no token (plugin options seen: ${opts:-none}; HN_RELAY unset; no ~/.humanneeded/relay), state $state not sent"

channel="$(printf '%s' "$token" | cut -d. -f2)"
secret="$(printf '%s' "$token" | cut -d. -f3)"
case "$token" in hn1.*) ;; *) say "token from $src is not hn1.<channel>.<secret>" ;; esac
printf '%s' "$channel" | grep -Eq '^[0-9a-f]{32}$' || say "bad channel in token from $src"
printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' || say "bad secret in token from $src"

sha256_hex() { # stdin -> hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r | cut -c1-64
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; fi
}
hmac_hex() { # stdin, $1 = hex key -> hex
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -r | cut -c1-64
  else
    python3 -c 'import hmac,hashlib,sys;print(hmac.new(bytes.fromhex(sys.argv[1]),sys.stdin.buffer.read(),hashlib.sha256).hexdigest())' "$1"
  fi
}

hash="$(printf '%s' "$session_id" | sha256_hex | cut -c1-16)"
agent="$(printf '%s' "$agent" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"
body="{\"s\":\"$state\",\"h\":\"$hash\",\"t\":$(date +%s),\"a\":\"${agent:-claude}\"}"
sig="$(printf '%s' "$body" | hmac_hex "$secret")"
printf '%s' "$sig" | grep -Eq '^[0-9a-f]{64}$' || say "could not sign (no openssl or python3)"

resp="$(curl -sS --max-time 4 -X POST -H 'content-type: application/json' -H "x-hn-sig: $sig" \
  --data-binary "$body" -w ' http=%{http_code}' "$RELAY_URL/s/$channel" 2>&1)"
{ date -u +%FT%TZ; echo "$state $hash ($src) -> $resp"; } >> /tmp/hn-relay.log 2>/dev/null
delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9]*\).*/\1/p')"
if [ -n "$delivered" ]; then
  say "$state sent via $src, delivered to $delivered PC connection(s)"
else
  say "$state not delivered via $src: $(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-160)"
fi
