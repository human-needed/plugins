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

**macOS (in testing):** the hooks call `scripts/hn.sh`, a bash version of `hn.ps1` that finds
the puck's `/dev/cu.usbmodem…` port by its `HN…` serial number. The Mac connector (`puck-mac`:
`scripts/hn-mcp.sh` starting `scripts/hn-mcp.py`) does what `hn-mcp.ps1` does on Windows. It
needs `python3` (Homebrew's, or Apple's after `xcode-select --install`). Each OS shows the other
OS's connector as failed to start; that's expected for now. Try the script by hand:
`bash scripts/hn.sh hello`. Each run adds a line to `~/.humanneeded/hn.log`.

**Cloud sessions (Cowork, claude.ai/code):** their hooks run in a Linux VM that can't reach your
computer. There `scripts/hn.sh` hands each state to `scripts/relay.sh`, which POSTs it to the
HumanNeeded relay (`relay/`) under a key derived from your Claude account:
sha256("humanneeded-account:" + accountUuid)[:32], read from `~/.claude.json`. The plugin's
connector on your computer (`hn-mcp.ps1` / `hn-mcp.py`, started by the Claude app) reads the same
accountUuid from its own `.claude.json`, holds a WebSocket to the relay under that key, and passes
the states that arrive to the puck. No setup. Messages carry only the state, the account key, a
short hash of the session id, the agent name and a timestamp; the relay stores no messages and
nothing is saved in the cloud session. Local sessions never use the relay.

Codex and Cursor plugins are coming.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin: hooks, connectors (.mcp.json), "humanneeded" skill
host/hn.ps1                       Windows script the hooks call; talks to the puck over USB serial
host/hn-mcp.ps1                   Windows connector (MCP over stdio): set_state + relay listener -> hn.ps1
host/hn.sh, host/hn-mcp.sh/.py    the same for macOS
host/relay.sh                     cloud VM side: posts states to the relay
relay/                            the relay (CloudFormation: Lambda function URL + WebSocket API)
```

`plugins/*/scripts/` holds copies of the `host/` scripts, because installed plugins can't reach outside
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
