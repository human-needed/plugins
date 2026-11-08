#!/bin/sh
# Cloud test (0.1.16): which outside hosts can a hook inside the cloud VM reach?
# Runs only in a cloud VM (Linux with CLAUDE_CODE_REMOTE=true); exits silently everywhere else,
# so local Windows and Mac sessions are unchanged. Prints one line on UserPromptSubmit:
#   HumanNeeded 0.1.16 egress: host=CODE ...
# CODE is the HTTP status (any number means the host was reached), or for a failure
# 000/x<curl exit> (6 DNS, 7 refused, 28 timeout, 35 TLS, 56 proxy/recv), plus
# /proxy<code> when an egress proxy answered the CONNECT itself.
[ "$(uname -s)" = "Linux" ] || exit 0
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

VERSION=0.1.16
# The relay's test endpoint, once one is deployed (stage B). Empty = not deployed yet.
EXECUTE_API_URL=""

out="$(mktemp -d 2>/dev/null || echo /tmp/hn-egress.$$)"
mkdir -p "$out" 2>/dev/null

probe() { # probe <label> <url>
  if command -v curl >/dev/null 2>&1; then
    r="$(curl -sS -o /dev/null --max-time 3 -w '%{http_code} %{http_connect}' "$2" 2>/dev/null)"
    rc=$?
    code="${r% *}"; connect="${r#* }"
    [ -n "$code" ] || code=000
    s="$code"
    [ "$rc" -ne 0 ] && s="$s/x$rc"
    [ -n "$connect" ] && [ "$connect" != "000" ] && [ "$connect" != "200" ] && s="$s/proxy$connect"
  elif command -v wget >/dev/null 2>&1; then
    if wget -q -T 3 -t 1 -O /dev/null "$2" 2>/dev/null; then s="wget-ok"; else s="wget-fail$?"; fi
  else
    s="no-curl"
  fi
  printf '%s=%s' "$1" "$s" > "$out/$1"
}

probe api.github.com https://api.github.com/ &
probe sts.amazonaws.com https://sts.amazonaws.com/ &
if [ -n "$EXECUTE_API_URL" ]; then probe execute-api "$EXECUTE_API_URL" & fi
probe firestore.googleapis.com https://firestore.googleapis.com/ &
probe ntfy.sh https://ntfy.sh/ &
wait

line=""
for h in api.github.com sts.amazonaws.com execute-api firestore.googleapis.com ntfy.sh; do
  if [ -f "$out/$h" ]; then line="$line $(cat "$out/$h")"; else line="$line $h=none-yet"; fi
done
rm -rf "$out" 2>/dev/null

proxy="none"
[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && proxy="set"
msg="HumanNeeded $VERSION egress:$line (https_proxy $proxy, entrypoint ${CLAUDE_CODE_ENTRYPOINT:-none})"
{ date -u +%FT%TZ; echo "$msg"; } >> /tmp/hn-egress.log 2>/dev/null
echo "$msg"
exit 0
