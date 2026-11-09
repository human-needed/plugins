#!/bin/sh
# HumanNeeded cloud relay sender (test, 0.1.21). Runs inside a cloud Claude VM (Linux with
# CLAUDE_CODE_REMOTE=true); hn.sh calls it there and nowhere else, so local sessions never use
# the relay and states aren't sent twice.
#
#   relay.sh <working|needs|done|idle|end> <agent> <session_id> <event_name>
#
# Sends {"s":state,"h":hash,"t":unix time,"a":agent} to the HumanNeeded relay, which forwards
# it to the user's PC. Two modes:
#  - No key (Cowork): POST /h/<sha256(session_id)[:32]>, unsigned. The relay delivers it only
#    to a PC that claimed that hash. The PC claims it when Claude calls the puck tool set_state
#    with this session_id, which this hook asks for on a prompt whose state wasn't delivered.
#    Nothing is saved in the VM.
#  - A key in HN_RELAY (or CLAUDE_PLUGIN_OPTION_RELAY, or ~/.humanneeded/relay):
#    hn1.<channel>.<secret>, or a 0.1.18 hn2.<channel>.<expiry>.<key>. POST /s/<channel>,
#    HMAC-signed; the PC checks the signature.
# Prints one line on UserPromptSubmit; silent otherwise. Always exits 0.

VERSION=0.1.21
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

# When the relay is blocked from this hook: which hosts can it reach? Runs once per session
# (marker in /tmp), all in parallel, 2 s each. Prints "host code" pairs; "blocked" = proxy refusal.
probe_hosts() {
  d="/tmp/hn-probe.$$"; mkdir -p "$d" 2>/dev/null || return 0
  i=10
  for h in api.github.com raw.githubusercontent.com registry.npmjs.org pypi.org ntfy.sh \
           s3.us-east-2.amazonaws.com dynamodb.us-east-2.amazonaws.com \
           x.lambda-url.us-east-2.on.aws iot.us-east-2.amazonaws.com \
           firestore.googleapis.com storage.googleapis.com api.anthropic.com; do
    i=$((i+1))
    ( c="$(curl -s --max-time 2 -o "$d/b$i" -w '%{http_code}' "https://$h/" 2>"$d/e$i")"
      grep -qiE 'blocked|no rule' "$d/b$i" "$d/e$i" 2>/dev/null && c=blocked
      echo "$h ${c:-000}" > "$d/r$i" ) &
  done
  wait
  cat "$d"/r* 2>/dev/null | tr '\n' ';' | sed 's/;$//'
  rm -rf "$d"
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
  # Session mode.
  body="{\"s\":\"$state\",\"h\":\"$hash\",\"t\":$(date +%s),\"a\":\"${agent:-claude}\"}"
  resp="$(post "/h/$hash" "$body" "")"
  { date -u +%FT%TZ; echo "$state ${hash%????????????????} (session) -> $resp"; } >> /tmp/hn-relay.log 2>/dev/null
  delivered="$(printf '%s' "$resp" | sed -n 's/.*"delivered": *\([0-9]*\).*/\1/p')"
  [ "$event_name" = "UserPromptSubmit" ] || exit 0
  if [ -n "$delivered" ] && [ "$delivered" -gt 0 ]; then
    echo "HumanNeeded $VERSION relay: $state delivered to the desk light."
    exit 0
  fi
  link="this session isn't linked to the user's HumanNeeded desk light yet (from the humanneeded plugin they installed). To link it, call the HumanNeeded puck tool set_state (it may be listed as plugin_humanneeded_puck__set_state) once with state \"working\" and session_id \"$session_id\". That only sets the light on the user's PC and lets this session's later states reach it; nothing is stored here. If you do, tell the user in one short line that you linked their desk light. If that tool isn't available, ignore this."
  if [ -z "$delivered" ]; then
    # Blocked or down: still link via set_state (that reaches the PC another way), and report
    # once per session which hosts this hook can reach.
    probe=""; mark="/tmp/hn-probe-${hash%????????????????}"
    if [ ! -f "$mark" ]; then
      : > "$mark" 2>/dev/null
      probe=" Hook network probe: $(probe_hosts)."
      echo "probe:$probe" >> /tmp/hn-relay.log 2>/dev/null
    fi
    echo "HumanNeeded $VERSION relay: $state not sent (relay unreachable: $(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-300)).$probe Also, $link"
    exit 0
  fi
  echo "HumanNeeded $VERSION relay: $link"
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
