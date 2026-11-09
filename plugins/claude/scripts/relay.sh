#!/bin/sh
# HumanNeeded cloud relay sender (test, 0.1.24). Runs inside a cloud Claude VM (Linux with
# CLAUDE_CODE_REMOTE=true); hn.sh calls it there and nowhere else, so local sessions never use
# the relay and states aren't sent twice.
#
#   relay.sh <working|needs|done|idle|end> <agent> <session_id> <event_name>
#
# Sends {"s":state,"h":key,"u":session hash,"t":unix time,"a":agent} to the HumanNeeded relay, which forwards
# it to the user's PC. Two modes:
#  - No key (Cowork, claude.ai/code): POST /h/<key>, unsigned, key = sha256("humanneeded-account:"
#    + the accountUuid in ~/.claude.json)[:32]. The user's PC computes the same key from its own
#    .claude.json and claims it at the relay, so the relay delivers only to that PC. Without an
#    accountUuid, key = sha256(session_id)[:32], claimed when set_state is called with it.
#    Nothing is saved in the VM.
#  - A key in HN_RELAY (or CLAUDE_PLUGIN_OPTION_RELAY, or ~/.humanneeded/relay):
#    hn1.<channel>.<secret>, or a 0.1.18 hn2.<channel>.<expiry>.<key>. POST /s/<channel>,
#    HMAC-signed; the PC checks the signature.
# Prints one line on UserPromptSubmit; silent otherwise. Always exits 0.

VERSION=0.1.24
# The relay Lambda's function URL: Cowork sessions connected to a PC can't reach execute-api hosts.
RELAY_URL="${HN_RELAY_URL:-https://tcxdfuid4msoglniqenx2qhnza0gwwyq.lambda-url.us-east-2.on.aws}"

state="$1"; agent="${2:-claude}"; session_id="${3:-default}"; event_name="$4"
say() { [ "$event_name" = "UserPromptSubmit" ] && echo "HumanNeeded $VERSION relay: $*"; exit 0; }

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
post() { # $1 = path, $2 = body, $3 = signature or empty -> prints response + http code
  if [ -n "$3" ]; then
    curl -sS --max-time 4 -X POST -H 'content-type: application/json' -H "x-hn-sig: $3" \
      --data-binary "$2" -w ' http=%{http_code}' "$RELAY_URL$1" 2>&1
  else
    curl -sS --max-time 4 -X POST -H 'content-type: application/json' \
      --data-binary "$2" -w ' http=%{http_code}' "$RELAY_URL$1" 2>&1
  fi
}

agent="$(printf '%s' "$agent" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"
hash="$(printf '%s' "$session_id" | sha256_hex | cut -c1-32)"
printf '%s' "$hash" | grep -Eq '^[0-9a-f]{32}$' || say "could not hash the session id (no sha256sum, openssl or python3)"

token=""; src=""
if [ -n "${CLAUDE_PLUGIN_OPTION_RELAY:-}" ]; then token="$CLAUDE_PLUGIN_OPTION_RELAY"; src="plugin option"
elif [ -n "${HN_RELAY:-}" ]; then token="$HN_RELAY"; src="env HN_RELAY"
elif [ -f "$HOME/.humanneeded/relay" ]; then token="$(tr -d '[:space:]' < "$HOME/.humanneeded/relay")"; src="~/.humanneeded/relay"
fi

if [ -z "$token" ]; then
  # Account mode: route by this Claude account, which the user's PC knows too (its own
  # .claude.json), so no linking step is needed. Falls back to the session hash (linked through
  # set_state) when the VM has no account id.
  acct="$(grep -o '"accountUuid" *: *"[0-9a-fA-F-]*"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed 's/.*"\([0-9a-fA-F-]*\)"$/\1/')"
  short="$(printf '%s' "$hash" | cut -c1-16)"
  if [ -n "$acct" ]; then
    key="$(printf '%s' "humanneeded-account:$acct" | sha256_hex | cut -c1-32)"; mode=account
  else
    key="$hash"; mode=session
  fi
  body="{\"s\":\"$state\",\"h\":\"$key\",\"u\":\"$short\",\"t\":$(date +%s),\"a\":\"${agent:-claude}\"}"
  resp="$(post "/h/$key" "$body" "")"
  { date -u +%FT%TZ; echo "$state $short ($mode) -> $resp"; } >> /tmp/hn-relay.log 2>/dev/null
  delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9]*\).*/\1/p')"
  [ "$event_name" = "UserPromptSubmit" ] || exit 0
  # One note per session and outcome, so the model's context isn't filled with them.
  if [ -n "$delivered" ] && [ "$delivered" -gt 0 ]; then outcome=ok
  elif [ -n "$delivered" ]; then outcome=nopc
  else outcome=unreachable; fi
  mark="/tmp/hn-note-$short-$outcome"
  [ -f "$mark" ] && exit 0
  : > "$mark" 2>/dev/null
  case "$outcome" in
    ok) echo "HumanNeeded $VERSION relay ($mode): this session's states reach the user's desk light. No action needed." ;;
    nopc)
      if [ "$mode" = account ]; then
        echo "HumanNeeded $VERSION relay: no PC is listening for this Claude account (the Claude app with the humanneeded plugin 0.1.23+ isn't running there). No action needed."
      else
        echo "HumanNeeded $VERSION relay: this session isn't linked to the user's desk light. If the user asks to link it, call the HumanNeeded puck tool set_state with state \"working\" and session_id \"$session_id\"."
      fi ;;
    unreachable)
      echo "HumanNeeded $VERSION relay: $state not sent (relay unreachable: $(printf '%s' "$resp" | tr '
' ' ' | cut -c1-300)). No action needed." ;;
  esac
  exit 0
fi

# Signed channel mode.
channel="$(printf '%s' "$token" | cut -d. -f2)"
expiry=""
case "$token" in
  hn1.*) secret="$(printf '%s' "$token" | cut -d. -f3)" ;;
  hn2.*) expiry="$(printf '%s' "$token" | cut -d. -f3)"; secret="$(printf '%s' "$token" | cut -d. -f4)"
         printf '%s' "$expiry" | grep -Eq '^[0-9]{10}$' || say "bad expiry in key from $src"
         [ "$expiry" -gt "$(date +%s)" ] || say "the relay key in $src has expired" ;;
  *) say "key from $src is neither hn1.<channel>.<secret> nor hn2.<channel>.<expiry>.<key>" ;;
esac
printf '%s' "$channel" | grep -Eq '^[0-9a-f]{32}$' || say "bad channel in key from $src"
printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' || say "bad secret in key from $src"

xfield=""; [ -n "$expiry" ] && xfield=",\"x\":$expiry"
body="{\"s\":\"$state\",\"h\":\"$(printf '%s' "$hash" | cut -c1-16)\",\"t\":$(date +%s),\"a\":\"${agent:-claude}\"$xfield}"
sig="$(printf '%s' "$body" | hmac_hex "$secret")"
printf '%s' "$sig" | grep -Eq '^[0-9a-f]{64}$' || say "could not sign (no openssl or python3)"

resp="$(post "/s/$channel" "$body" "$sig")"
{ date -u +%FT%TZ; echo "$state ($src) -> $resp"; } >> /tmp/hn-relay.log 2>/dev/null
delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9]*\).*/\1/p')"
if [ -n "$delivered" ]; then
  say "$state sent via $src, delivered to $delivered PC connection(s)"
else
  say "$state not delivered via $src: $(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-160)"
fi
