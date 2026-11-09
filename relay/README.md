# HumanNeeded cloud relay (test)

Forwards puck states from cloud Claude sessions to the PC. One CloudFormation stack:

- **Function URL** (what the hooks use; Cowork sessions connected to a PC can't reach
  execute-api hosts) and the same routes on the **HTTP API**, response `{"delivered": n}`:
  - `POST /h/{key}`: unsigned `{"s","h","u","t","a"}`, delivered to the PC that claimed the key.
    key = sha256("humanneeded-account:" + accountUuid)[:32] (the PC claims its own account's key on
    connect), or sha256(session_id)[:32] for a session linked through `set_state`.
  - `POST /s/{channel}`: the same body with `x-hn-sig: hex(HMAC-SHA256(secret, body))`.
- **WebSocket API** `wss://…/v1?ch={channel}`: the PC's connector listens here and sends
  `{"action":"claim","h":[hash,…]}` for the cloud sessions that called its `set_state` tool.
- **Lambda** (inline in `template.yaml`) forwards the body and signature unchanged to every
  connection on the channel. It never has the secret; the PC verifies signatures (or
  that it claimed the session), a 5 min timestamp window and replays.
- **DynamoDB** maps channel → connection ids (TTL 3 h) and `h<hash>` → connection ids
  (TTL 24 h). No message content is stored.

Channel = 128 random bits, secret = 256 random bits, created by `hn-mcp.ps1` on first start and
shared as the token `hn1.<channel-hex>.<secret-hex>`.

Deploy (sign in first with `aws login --profile humanneeded`; no keys are kept in this repo):

```bash
sh relay/deploy.sh humanneeded us-east-2
```

Deployed 2026-11-08 to us-east-2. After a redeploy that changes the URLs, put `PostUrl` into `RELAY_URL` in `host/relay.sh` and `WebSocketUrl` into `$relayWs` in
`host/hn-mcp.ps1`, and run `host/sync-plugins.ps1`. Remove it with `aws cloudformation delete-stack --stack-name humanneeded-relay --profile humanneeded --region us-east-2`.
