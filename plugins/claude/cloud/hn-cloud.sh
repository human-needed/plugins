#!/bin/sh
# HumanNeeded cloud hook (hn-relay/1, pm/contracts/relay-api.md §4).
#
#   sh hn-cloud.sh <working|needs|done|idle|end>     (hook JSON on stdin)
#
# Runs only inside a cloud Claude VM: claude.ai/code web sessions (CLAUDE_CODE_REMOTE=true) and
# cloud Cowork tasks (CLAUDE_CODE_ENTRYPOINT=remote_cowork). Anywhere else it exits at once: on
# a PC the plugin's HTTP hooks report to the HumanNeeded app instead. POSTs
#   {"v":1,"s":state,"h":sha256(session_id)[:16],"ts":ms,"hb":false}
# to RELAY_POST<K>, K = sha256("humanneeded-account:" + accountUuid from $CLAUDE_CODE_ACCOUNT_UUID or ~/.claude.json)[:32].
# While the session is working/needs, one detached loop per session re-posts the current state
# with "hb":true every 45 s while the Claude process is alive.
# Prints nothing, always exits 0, within 4 s. Log: /tmp/hn-cloud/log (no key in it).

# The one place the relay address lives (relay-api §1).
RELAY_POST="https://relay.human-needed.com/v1/h/"

case "$CLAUDE_CODE_REMOTE:$CLAUDE_CODE_ENTRYPOINT" in
  true:*|*:remote|*:remote_*) ;;
  *) exit 0 ;;
esac
exec >/dev/null 2>&1
T_START="$(date +%s%3N 2>/dev/null)"

# Test-only overrides (tests/run.mjs, the canary), honoured only with HN_DEV=1 (D-045).
HB=45; DIR=/tmp/hn-cloud
if [ "$HN_DEV" = "1" ]; then
  [ -n "$HN_RELAY_URL" ] && RELAY_POST="$HN_RELAY_URL"
  [ -n "$HN_HB_INTERVAL" ] && HB="$HN_HB_INTERVAL"
  [ -n "$HN_CLOUD_DIR" ] && DIR="$HN_CLOUD_DIR"
fi
mkdir -p "$DIR" 2>/dev/null || exit 0

log() {
  echo "$(date -u +%FT%TZ) $*" >> "$DIR/log"
  [ "$(wc -c < "$DIR/log" 2>/dev/null || echo 0)" -gt 204800 ] && tail -c 102400 "$DIR/log" > "$DIR/log.tmp" && mv "$DIR/log.tmp" "$DIR/log"
}

sha256_hex() { # stdin -> 64 hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64
  else openssl dgst -sha256 -r | cut -c1-64; fi
}

now_ms() {
  ms="$(date +%s%3N 2>/dev/null)"
  case "$ms" in *N|"" ) echo "$(date +%s)000" ;; *) echo "$ms" ;; esac
}

# Account: $CLAUDE_CODE_ACCOUNT_UUID first (Cowork VMs set it; their ~/.claude.json has no
# accountUuid), else ~/.claude.json. Same K either way.
relay_key() {
  acct="$(printf '%s' "${CLAUDE_CODE_ACCOUNT_UUID:-}" | tr -cd '0-9a-fA-F-')"
  [ -n "$acct" ] || acct="$(grep -o '"accountUuid" *: *"[0-9a-fA-F-]*"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed 's/.*"\([0-9a-fA-F-]*\)"$/\1/')"
  [ -n "$acct" ] || return 1
  printf '%s' "humanneeded-account:$acct" | sha256_hex | cut -c1-32
}

# post <state> <h> <hb true|false> <ts>; retries twice on 429 with jitter (worst case ~3.7 s).
post() {
  key="$(relay_key)" || { log "no accountUuid"; return 0; }
  body="{\"v\":1,\"s\":\"$1\",\"h\":\"$2\",\"ts\":$4,\"hb\":$3}"
  t=1.5; n=0
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time "$t" \
      -X POST -H 'content-type: application/json' --data-binary "$body" "$RELAY_POST$key")"
    log "$1 $2 hb=$3 -> $code"
    [ "$code" = "429" ] && [ "$n" -lt 2 ] || return 0
    n=$((n + 1)); t=0.6
    sleep "0.$(( ($(od -An -N1 -tu1 /dev/urandom 2>/dev/null || echo 7) % 4) + 2 ))"
  done
}

# Heartbeat loop: sh hn-cloud.sh --hb <h> <agent pid>
if [ "$1" = "--hb" ]; then
  h="$2"; agent="$3"
  echo $$ > "$DIR/$h.pid"
  while sleep "$HB"; do
    [ "$(cat "$DIR/$h.pid" 2>/dev/null)" = "$$" ] || exit 0       # another loop took over
    kill -0 "$agent" 2>/dev/null || { log "hb $h agent gone"; break; }
    s="$(cut -d' ' -f2 "$DIR/$h.state" 2>/dev/null)"
    case "$s" in working|needs) post "$s" "$h" true "$(now_ms)" ;; *) break ;; esac
  done
  [ "$(cat "$DIR/$h.pid" 2>/dev/null)" = "$$" ] && rm -f "$DIR/$h.pid"
  exit 0
fi

state="$1"
case "$state" in working|needs|done|idle|end) ;; *) exit 0 ;; esac

# Hook JSON: only the first 16 KB is read (PostToolUse can carry megabytes).
sid="$(head -c 16384 | tr -d '\n' | grep -o '"session_id" *: *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
h="$(printf '%s' "${sid:-default}" | sha256_hex | cut -c1-16)"

# Hooks run in parallel and can finish out of order: the state file keeps the newest event
# (by hook start time), so a late "working" can't restart the heartbeat after "done".
case "$T_START" in *N|"") T_START="$(now_ms)" ;; esac
prev="$(cut -d' ' -f1 "$DIR/$h.state" 2>/dev/null)"
if [ -n "$prev" ] && [ "$prev" -gt "$T_START" ] 2>/dev/null; then
  post "$state" "$h" false "$T_START"     # the app drops it as older; nothing else to do
  exit 0
fi
echo "$T_START $state" > "$DIR/$h.state"
post "$state" "$h" false "$T_START"

case "$state" in
  working|needs)
    pid="$(cat "$DIR/$h.pid" 2>/dev/null)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      # $PPID is the Claude process (exec-form hook). Detached so it outlives this hook.
      if command -v setsid >/dev/null 2>&1; then
        setsid sh "$0" --hb "$h" "$PPID" </dev/null >/dev/null 2>&1 &
      else
        nohup sh "$0" --hb "$h" "$PPID" </dev/null >/dev/null 2>&1 &
      fi
    fi ;;
esac
exit 0
