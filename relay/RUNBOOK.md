# Relay runbook (hn-relay-v1, us-east-2)

Sign in first: `aws login --profile humanneeded`. All commands from the plugins repo root.

## Alerts you can get (email)
| Alert | Meaning | Do |
|---|---|---|
| **ProbeAlarm** | The 15-min POST→WebSocket round trip failed or didn't run | `status`; check DNS (Cloudflare `relay`, `relay-ws` CNAMEs, DNS only) and the cert; run `python relay/tests/relay_client.py` |
| **Post/WsTrafficAlarm** (early warning) | 1-h average at 70 % of the POST ceiling (14/s ≈ 2,100 users) or WS ≈ same user level | Organic growth: tell the PM (D-066: revisit §3.4 timings / raise ceiling + brake together). Abuse: `brake` |
| **Post/WsBrakeAlarm** | POST > 18/s or WS > 44/s (in+out) for 5 min. **Auto-brake already engaged**: both APIs throttled to 3/s | Look at the cause. When calm: `normal` |
| **RelayErrorAlarm** | > 20 function errors/throttles in 15 min | Lambda logs (errors only) in the relay log group |
| **Budget** ($5 / $20) | Month-to-date spend crossed it | If unexpected: `brake 1` or `kill`, then find out why |

## Controls (`sh relay/ops/relay-ops.sh <cmd>`)
| Command | Effect | Undo |
|---|---|---|
| `status` | Throttles, function concurrency, alarm states | — |
| `brake [n]` | Both APIs to n/s (default 3). Lights still work for a few users | `normal` |
| `normal` | 20/s, burst 40 (template values) | — |
| `kill` | Everything 429; function disabled. **Costs stop except idle sockets** | `revive` then `normal` |
| `revive` | Re-enables the function | — |

A stack deploy (`sh relay/deploy.sh deploy`) also resets throttles to the template values.

## Hard stop
Delete the stack: `aws cloudformation delete-stack --stack-name hn-relay-v1 --profile humanneeded --region us-east-2`
(bindings are lost; PCs must re-hello, which they do automatically). Last resort: the project spend limit in AWS Settings.

## Cost ceiling
- Throttles cap each API at 20 req/s → worst case ≈ $150/month if flooded right under the brake for a whole month.
- Auto-brake (POST 18/s for 5 min) cuts a flood to 3/s per API → ≈ $25/month.
- Early-warning alarms (14/s for an hour) and the $5 budget email come first.
- Per active user at relay-api §3.4: 0.0067 POST/s, 0.011 WS messages/s. Scale ceiling, brake and warnings together.
