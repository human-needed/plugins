# HumanNeeded plugins

Agent plugins for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that glows and
chimes when your AI coding agent is working, done, or needs you. Setup guide:
[human-needed.com/start](https://human-needed.com/start/).

## Claude Code (Windows)

In the Claude desktop app: **+** next to the prompt box → **Add plugins**, add the marketplace
`human-needed/plugins`, then install **humanneeded** for your user account. Or in a terminal:

```bash
claude plugin install humanneeded --marketplace human-needed/plugins
```

New sessions then drive the puck: blue while working, amber when Claude needs a permission or an
answer, green when it finishes. Ask Claude "test my puck" or "make needs purple".

Remove it with `claude plugin uninstall humanneeded@humanneeded`.

**Cloud sessions (Cowork, claude.ai/code): being tested.** Their hooks run in Anthropic's cloud,
not on your PC. The plugin's hooks module (`hooks/register.ts`) sends each state to the plugin's
local connector (`scripts/hn-mcp.ps1`), which the Claude desktop app runs on the PC the session is
linked to. The first state of each cloud session adds a "HumanNeeded check" note to the
conversation saying whether it got through (the model doesn't read it).

**macOS (being tested, 0.1.15):** the hooks also call `scripts/hn.sh`, a bash version of `hn.ps1`
that finds the puck's `/dev/cu.usbmodem…` port by its `HN…` serial number. Those hooks are marked
`"cloud": "device"`, so when the Claude app on a Mac offers to run this machine's hooks for cloud
sessions, cloud Cowork/Code sessions can drive the puck too. Try it by hand:
`bash scripts/hn.sh hello`. Each run adds a line to `~/.humanneeded/hn.log`.

**Cloud sessions through the relay (0.1.23, test):** cloud Claude sessions (claude.ai/code,
cloud Cowork) run their hooks in a Linux VM that can't reach your PC. There `scripts/hn.sh` hands
each state to `scripts/relay.sh`, which POSTs it to the HumanNeeded relay (`relay/`: a Lambda
function URL plus an API Gateway WebSocket) under a key derived from your Claude account:
sha256("humanneeded-account:" + accountUuid)[:32], read from `~/.claude.json`. The puck connector
the Claude app runs on your PC (`scripts/hn-mcp.ps1`) reads the same accountUuid from its own
`.claude.json`, keeps a WebSocket open to the relay and claims that key, so every cloud session of
your account reaches your puck with no setup. Messages carry only the state, the account key, a
short hash of the session id, the agent name and a timestamp; the relay stores no messages, and
nothing is saved in the cloud session. Local sessions never use the relay. Without an accountUuid
in the VM, a session can still be linked by asking Claude to "link my desk light". For signed
states, set `HN_RELAY` to the token in `%USERPROFILE%\.humanneeded\relay.json`.

Codex and Cursor plugins are coming.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin: hooks + "humanneeded" skill
host/hn.ps1                       Windows script the hooks call; talks to the puck over USB serial
host/hn-mcp.ps1                   local connector (MCP over stdio): set_state -> hn.ps1
plugins/claude/hooks/register.ts  hooks module: cloud sessions -> the local connector
```

`plugins/*/scripts/` holds copies of `host/hn.ps1` and `host/hn-mcp.ps1`, because installed plugins can't reach outside
their folder. After editing anything in `host/`, run `host/sync-plugins.ps1`.

Try the script by hand:

```powershell
powershell -ExecutionPolicy Bypass -File host\hn.ps1 hello
powershell -ExecutionPolicy Bypass -File host\hn.ps1 test needs
'{"session_id":"s1"}' | powershell -ExecutionPolicy Bypass -File host\hn.ps1 done
```

It finds the puck by its `HN…` USB serial number, caches the COM port in
`%USERPROFILE%\.humanneeded\port`, always exits 0, and gives up silently after ~2 s.
Each run adds a line to `%USERPROFILE%\.humanneeded\hn.log` (time, command, the puck's reply or
"no puck", and the plugin folder it ran from), so you can see whether an app's hooks are firing.

To release a plugin change, bump `version` in `plugins/claude/.claude-plugin/plugin.json` and push.
Users get it with `claude plugin marketplace update humanneeded`, or automatically if they turn on
auto-update for the marketplace.
