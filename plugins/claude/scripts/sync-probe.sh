#!/bin/sh
# Cloud test (0.1.14): does a file written inside the cloud Cowork VM sync back to the user's PC?
# Writes a marker file named HN-SYNC-PROBE-<event>-<time>.txt into every candidate folder it can
# write to, then prints one line saying where it wrote and what is mounted. Does nothing on Windows
# hosts (local sessions), so it is harmless outside the cloud.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|Windows*) exit 0 ;; esac

event="${1:-prompt}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="HN-SYNC-PROBE-${event}-${stamp}.txt"
body="HumanNeeded sync probe: written in the cloud VM $(hostname) at ${stamp}, event ${event}, cwd $(pwd)"

candidates="$(pwd) ${CLAUDE_PROJECT_DIR:-} ${HOME:-}"
for d in /mnt/* /mnt/*/* /sessions/* /sessions/*/* /workspace /workspace/* /home/*/* /root/outputs /outputs /data; do
  [ -d "$d" ] && candidates="$candidates $d"
done

written=""
seen=" "
for d in $candidates; do
  case "$seen" in *" $d "*) continue ;; esac
  seen="$seen$d "
  if [ -d "$d" ] && [ -w "$d" ] && printf '%s\n' "$body" > "$d/$name" 2>/dev/null; then
    written="$written $d"
  fi
done

mounts="$(awk '$3 ~ /fuse|9p|virtiofs|nfs|cifs|overlay|ext4|xfs|btrfs/ && $2 !~ /^\/(proc|sys|dev|run|etc)/ {printf "%s(%s) ", $2, $3}' /proc/mounts 2>/dev/null)"

{ echo "$stamp $event wrote:$written"; echo "mounts: $mounts"; echo ---; } >> /tmp/hn-sync-probe.log 2>/dev/null

if [ "$event" = "prompt" ]; then
  echo "HumanNeeded 0.1.14 sync probe: wrote $name to:${written:- nothing}. Mounts: ${mounts:-none}"
fi
exit 0
