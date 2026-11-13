# HumanNeeded cloud relay

Forwards puck states from cloud Claude sessions to the user's computer. One CloudFormation stack
(`template.yaml`) in the project's Region:

- **Function URL** (what cloud hooks POST to; Cowork sessions connected to a computer can't reach
  execute-api hosts): `POST /h/{key}` with `{"s","h","u","t","a"}`, response `{"delivered": n}`.
  key = sha256("humanneeded-account:" + accountUuid)[:32].
- **WebSocket API** `wss://…/v1?k={key}`: the plugin's connector on the user's computer connects
  here with its own account's key.
- **Lambda** (inline in `template.yaml`) forwards each POSTed body unchanged to up to 4
  connections for that key. The connector accepts only states for its own key that are under
  5 min old.
- **DynamoDB** maps key → connection ids (TTL 3 h). No message content is stored.

Anyone who knows an account's key could send that account's puck states or listen for them;
the key comes from the account id, which isn't published, and a state carries nothing sensitive.

Limits: the Lambda shares the AWS account's concurrency (10 on the free plan), and the WebSocket
stage is throttled to 10 requests/s (burst 20). Set a spend limit in AWS Settings → Billing.

Deploy (sign in first with `aws login --profile humanneeded`; no keys are kept in this repo):

```bash
sh relay/deploy.sh humanneeded us-east-2
```

If a redeploy changes the URLs, put `FunctionUrl` (without the trailing slash) into `RELAY_URL`
in `host/relay.sh`, and `WebSocketUrl` into `$relayWs` in `host/hn-mcp.ps1`, then run `host/sync-plugins.ps1`. Remove the relay with
`aws cloudformation delete-stack --stack-name humanneeded-relay --profile humanneeded --region us-east-2`.
