# HumanNeeded plugins

[![tests](https://github.com/human-needed/plugins/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/human-needed/plugins/actions/workflows/test.yml)

Agent integrations for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that
glows and chimes when your AI coding agent is working, done, or needs you.

The **HumanNeeded app** runs on your computer and owns the puck. It listens on
`http://127.0.0.1:24816` (your computer only). Every integration just posts the agent's hook
data to `/v1/event/<agent>/<state>`. If the app isn't running, nothing happens.
The app can install and remove each integration for you
([`integrations/manifest.json`](integrations/manifest.json)); manual steps are below.

## Claude Code (Windows, macOS, Linux; desktop app, CLI, IDE)

In the Claude desktop app: **+** next to the prompt box → **Plugins** → add the marketplace
`human-needed/plugins`, then install **humanneeded**. Or in a terminal:

```bash
claude plugin marketplace add human-needed/plugins
```

```bash
claude plugin install humanneeded@humanneeded
```

New sessions light the puck. Ask Claude "test my puck", "mute for an hour" or "make needs purple".
The hooks are Claude's own HTTP hooks: nothing else runs on your computer.

If you use an HTTP proxy (`HTTP_PROXY`/`HTTPS_PROXY`), add `127.0.0.1` to `NO_PROXY`, or Claude
sends the hook calls to the proxy.

**Cloud sessions** (Cowork, claude.ai/code) run their hooks in a Linux VM that can't reach your
computer. There [`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) posts each state to the
HumanNeeded relay under a key derived from your Claude account and keeps a heartbeat while the
session is working or waiting on you. On your own computer that script exits at once.

## Codex (CLI and app)

Add the entries of [`plugins/codex/hooks.json`](plugins/codex/hooks.json) to
`~/.codex/hooks.json` (create it if missing; keep your own hooks), restart Codex, then **approve
the hooks** (`/hooks` in the CLI, Settings → Hooks in the app). They use the `curl` built into
Windows, macOS and Linux.

## Cursor

Add the entries of [`plugins/cursor/hooks.json`](plugins/cursor/hooks.json) (Windows:
[`hooks.windows.json`](plugins/cursor/hooks.windows.json)) to `~/.cursor/hooks.json` (create it
with `{"version": 1, "hooks": {}}` if missing). Cursor has no "needs you" hook yet, so the puck
shows working and done only.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin "humanneeded": HTTP hooks, cloud hook, skill
plugins/codex/hooks.json          Codex hooks (curl)
plugins/cursor/hooks*.json        Cursor hooks (curl; macOS/Linux and Windows)
integrations/manifest.json        how the app detects / installs / removes each integration
tools/gen-hooks.mjs               generates every hook file from one mapping table
tests/run.mjs                     tests; tests/fake-hub.mjs is a stand-in for the app
relay/                            the old cloud relay (being replaced)
```

Edit the mapping in `tools/gen-hooks.mjs`, never the hook files, then:

```bash
node tools/gen-hooks.mjs
```

```bash
node tests/run.mjs
```

To release a change, bump `version` in `plugins/claude/.claude-plugin/plugin.json` and push.
