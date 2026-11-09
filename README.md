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

**Cloud sessions through the relay (0.1.20, test):** cloud Claude sessions (claude.ai/code,
cloud Cowork) run their hooks in a Linux VM that can't reach your PC, but can reach AWS. There
`scripts/hn.sh` hands each state to `scripts/relay.sh`, which POSTs it to the HumanNeeded relay
(`relay/`: API Gateway + Lambda) under a hash of the session id. The puck connector the Claude
app runs on your PC (`scripts/hn-mcp.ps1`) keeps a WebSocket open to the relay. The first time a
cloud session's state isn't delivered, the hook asks Claude to call the connector's `set_state`
tool with the session id (that call reaches the PC through the app's link to it); the PC then
claims that session at the relay for 24 h, and its later states arrive. Messages carry only the
state, the session hash, the agent name and a timestamp, and the relay stores no messages.
Nothing is saved in the cloud session. Local sessions never use the relay. For signed states in
claude.ai/code, set `HN_RELAY` to the token in `%USERPROFILE%\.humanneeded\relay.json`.

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
