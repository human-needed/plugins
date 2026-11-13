# HumanNeeded plugins

> **Status (2026-11): prototype, being rebuilt.** The plugins below (0.1.x) talk to the puck
> directly with PowerShell/sh scripts. They are being replaced by thin integrations that call the
> HumanNeeded app (`hn` command), with a new puck protocol. The 0.1.x plugins and their cloud relay
> format will not be supported after that. Branch `test` holds the hardened relay experiments
> (reference only).

Agent plugins for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that glows and
chimes when your AI coding agent is working, done, or needs you. Setup guide:
[human-needed.com/start](https://human-needed.com/start/).

## Claude Code

The prototype plugin is Windows only (the macOS plugin was removed 2026-11-13; Mac returns with the HumanNeeded app). In the Claude desktop app: **+** next to
the prompt box → **Add plugins**, add the marketplace `human-needed/plugins`, then install
**humanneeded** for your user account. Or in a terminal:

```bash
claude plugin install humanneeded --marketplace human-needed/plugins
```

New sessions then drive the puck: blue while working, amber when Claude needs a permission or an
answer, green when it finishes. Ask Claude "test my puck" or "make needs purple".

Remove it with `claude plugin uninstall humanneeded@humanneeded`.

**Cloud sessions (Cowork, claude.ai/code):** their hooks run in a Linux VM that can't reach your
computer. There `scripts/hn.sh` hands each state to `scripts/relay.sh`, which POSTs it to the
HumanNeeded relay (`relay/`) under a key derived from your Claude account:
sha256("humanneeded-account:" + accountUuid)[:32], read from `~/.claude.json`. The plugin's
connector on your computer (`hn-mcp.ps1`, started by the Claude app) reads the same
accountUuid from its own `.claude.json`, holds a WebSocket to the relay under that key, and passes
the states that arrive to the puck. No setup. Messages carry only the state, the account key, a
short hash of the session id, the agent name and a timestamp; the relay stores no messages and
nothing is saved in the cloud session. Local sessions never use the relay.

Codex and Cursor plugins are coming.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Windows plugin "humanneeded": hooks, connector (.mcp.json), skill
host/hn.ps1                       Windows script the hooks call; talks to the puck over USB serial
host/hn-mcp.ps1                   Windows connector (MCP over stdio): set_state tool + relay listener
host/hn.sh                        runs in cloud VMs (hands states to relay.sh)
host/relay.sh                     cloud VM side: posts states to the relay
host/SKILL.template.md            the "humanneeded" skill, built into each plugin
relay/                            the relay (CloudFormation: Lambda function URL + WebSocket API)
```

`plugins/*/scripts/` and `plugins/*/skills/` are built from `host/`, because installed plugins
can't reach outside their folder. After editing anything in `host/`, run `host/sync-plugins.ps1`.
Each plugin's `hooks/hooks.json` and `.mcp.json` are edited in place.

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

To release a change, bump `version` in both plugins' `.claude-plugin/plugin.json` and push.
Users get it with `claude plugin marketplace update humanneeded`, or automatically if they turn on
auto-update for the marketplace.
