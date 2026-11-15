#!/bin/sh
# Reachability test for cloud Claude VMs. Paste into a cloud session and run; prints one line per URL.
# "000" = blocked or no DNS; any 3-digit HTTP code = the VM reached that host.
env | grep -i -E '^(https?_proxy|no_proxy|CLAUDE_CODE_(REMOTE|ENTRYPOINT))=' | sed 's/=.*@/=***@/'
for u in \
  https://human-needed.com/ \
  https://relay.human-needed.com/v1/h/00000000000000000000000000000000 \
  https://tcxdfuid4msoglniqenx2qhnza0gwwyq.lambda-url.us-east-2.on.aws/ \
  https://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1 \
  https://example.com/ ; do
  c=$(curl -s -o /dev/null -m 8 -w '%{http_code}' -X POST -d '{}' "$u" 2>&1); echo "$c $u"
done
