# HumanNeeded cloud relay `hn-relay/1`

Spec: `pm/contracts/relay-api.md` (in the AgentAlarm project). One CloudFormation stack, `hn-relay-v1`, us-east-2:

- `POST https://relay.human-needed.com/v1/h/<K>` (API Gateway HTTP API) — cloud hooks. Always `202`, empty
  body; `429` over 2/s burst 10 per K, or 10/s burst 50 per IP. Invalid bodies are dropped silently.
- `wss://relay-ws.human-needed.com/v1` (API Gateway WebSocket API) — PC app: `hello` within 5 s, `ping`
  (answered by API Gateway, no Lambda), `unbind`. Connects: 10/min burst 20 per IP. Messages ≤ 1 KB.
  Up to 3 installs own a K (30 days after last connect); the relay keeps only `sha256(S)`.
- One Lambda (`src/relay.mjs`, limits in `src/limits.mjs`) for both; rate limits are in-memory token buckets per
  warm instance. One DynamoDB table (bindings, live connection ids; TTL). Both APIs capped at 20/s, burst 40.
- Auto-brake (`src/brake.mjs`): POST > 18/s or WebSocket > 44/s for 5 min throttles both to 3/s;
  early-warning email at 70 % of the ceiling (~2,100 users). Ops and
  incidents: `RUNBOOK.md`, `ops/relay-ops.sh`. Cost model: `tests/cost_model.py`; load test: `tests/load_test.py`.
- Probe (`src/probe.mjs`) every 15 min: hello + POST + receive through the public names; alarm emails on failure
  or if it stops running. Budget alerts at $5 and $20. Logs 14 days, never contain keys.
- DNS (Cloudflare, DNS only): `relay` → `PostDomainTarget`, `relay-ws` → `WsDomainTarget` (stack outputs),
  plus the two ACM validation CNAMEs.

Deploy (sign in first with `aws login --profile humanneeded`):

```bash
sh relay/deploy.sh cert                      # once: ACM cert + its validation records
HN_CERT_ARN=<arn> HN_ALERT_EMAIL=<email> sh relay/deploy.sh deploy   # later runs keep previous values
python relay/tests/relay_client.py           # contract test, both sides (pip install websockets)
```

`deploy.sh` uploads the code zip to the private bucket `hn-relay-artifacts-<account>-us-east-2` (30-day expiry).
`tests/reach-test.sh` checks from a cloud Claude VM which relay hosts it can reach.
