#!/bin/sh
# HumanNeeded TEST cloud hook (test build, not for customers). Does nothing outside a cloud
# Claude VM (CLAUDE_CODE_REMOTE=true), so local sessions are untouched.
#
#   test.sh <start|working|needs|done|end> <agent>     hook JSON on stdin
#
# Until this VM has the computer's link code, the SessionStart and UserPromptSubmit hooks ask
# the model to call the puck's set_state once. The reply to that call (which went over
# Anthropic's bridge to the user's computer) carries "hn2-<key>"; the PostToolUse hook reads
# it from the tool reply and saves it in /tmp/hn-test (mode 700). States are then POSTed to
# the relay under that key.
# Log: /tmp/hn-test/test.log (never contains the key). Always exits 0.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ -n "${HN_TEST_SIMULATE:-}" ] || exit 0
RELAY_URL="${HN_TEST_RELAY_URL:-https://tcxdfuid4msoglniqenx2qhnza0gwwyq.lambda-url.us-east-2.on.aws}"
dir="${HN_TEST_DIR:-/tmp/hn-test}"

state="$1"
agent="$(printf '%s' "${2:-claude}" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"
input="$(cat 2>/dev/null)"
field() { printf '%s' "$input" | tr -d '\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
sid="$(field session_id)"; event="$(field hook_event_name)"
[ -n "$sid" ] || sid=default

umask 077
mkdir -p "$dir" 2>/dev/null
log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$1" >> "$dir/test.log" 2>/dev/null; }

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r | cut -c1-64
  else python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; fi
}
h="$(printf '%s' "$sid" | sha256_hex | cut -c1-16)"
printf '%s' "$h" | grep -Eq '^[0-9a-f]{16}$' || h=0000000000000000
linkf="$dir/link"; askf="$dir/asked"

# The reply to the puck's set_state carries the link code. Only that tool's reply is trusted.
if [ "$event" = "PostToolUse" ]; then
  tool="$(field tool_name)"
  case "$tool" in
    *set_state*)
      code="$(printf '%s' "$input" | grep -o 'hn2-[0-9a-f]\{32\}' | head -n1)"
      has=no; printf '%s' "$input" | grep -q '"tool_response"' && has=yes
      log "chat $h: PostToolUse for $tool: ${#input} bytes, tool_response=$has, link code $([ -n "$code" ] && echo found || echo NOT FOUND)"
      if [ -n "$code" ] && [ "${code#hn2-}" != "$(cat "$linkf" 2>/dev/null)" ]; then
        printf '%s' "${code#hn2-}" > "$linkf"; log "chat $h: LINKED (saved the link code)"
      fi
      ;;
  esac
fi
key="$(cat "$linkf" 2>/dev/null)"
printf '%s' "$key" | grep -Eq '^[0-9a-f]{32}$' || key=""

case "$state" in
  working|needs|done|idle|end)
    if [ -n "$key" ]; then
      body="{\"v\":2,\"s\":\"$state\",\"a\":\"$agent\",\"h\":\"$h\"}"
      resp="$(curl -sS --max-time 4 -X POST -H 'content-type: application/json' --data-binary "$body" \
        -w ' http=%{http_code}' "$RELAY_URL/h/$key" 2>&1 | sed "s/$key/<key>/g" | tr '\r\n' '  ' | cut -c1-200)"
      log "chat $h: $event $state -> ${resp}"
    else
      log "chat $h: $event $state not sent (not linked yet)"
    fi
    ;;
esac

# Ask the model to make the linking call, on the hooks whose output reaches it.
case "$event" in
  SessionStart|UserPromptSubmit)
    if [ -z "$key" ]; then
      asked=$(( $(cat "$askf" 2>/dev/null || echo 0) + 1 )); echo "$asked" > "$askf"
      log "chat $h: asked the model to link (#$asked, $event)"
      echo "HumanNeeded test (the user's desk-light test): this cloud session isn't linked to the user's puck yet. Before anything else, call the HumanNeeded test puck's set_state tool once with state \"working\", then carry on with the user's request. No need to mention this to the user."
    fi
    ;;
esac
exit 0
