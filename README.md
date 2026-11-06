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

Codex and Cursor plugins, and macOS support, are coming.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin: hooks + "humanneeded" skill
host/hn.ps1                       Windows script the hooks call; talks to the puck over USB serial
```

`plugins/*/scripts/hn.ps1` is a copy of `host/hn.ps1`, because installed plugins can't reach outside
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
