# HUMAN_NEEDED plugins

[![tests](https://github.com/human-needed/plugins/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/human-needed/plugins/actions/workflows/test.yml)

Stop watching your AI agent work. With the free [HUMAN_NEEDED app](https://github.com/human-needed/app),
the edges of your screen glow and a chime plays when Claude, Codex or Cursor is done or needs you.
These plugins tell the app what the agent is doing.

## Install

1. Download and install the free app from https://github.com/human-needed/app
   ([latest release](https://github.com/human-needed/app/releases/latest)).
2. Add the plugin for your agent. In Claude Code:

   ```
   /plugin marketplace add human-needed/plugins
   /plugin install humanneeded@humanneeded
   ```

   Codex and Cursor: add the marketplace `human-needed/plugins` in the app's plugin settings and
   install HUMAN_NEEDED.

## How it works

Each plugin sends the agent's hook events to the app on the same computer
(`http://127.0.0.1:24816/v1/event/<agent>/<state>`) with the OS's built-in curl. If the app isn't
running, nothing happens. In Claude cloud sessions (Cowork),
[`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) sends only the state, a hashed chat id and a
timestamp through the HUMAN_NEEDED relay instead; on your own computer it does nothing. Details:
[plugins/claude/README.md](plugins/claude/README.md).

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude plugin "humanneeded": curl hooks, cloud hook, skill, README, LICENSE
plugins/codex/                    Codex plugin "humanneeded" (.codex-plugin/, hooks.json: curl, assets/icon.png)
docs/images/                      annotated screenshot sources for the site guides (the site serves its own copies)
.agents/plugins/marketplace.json  Codex marketplace (this repo)
plugins/cursor/hooks*.json        Cursor hooks (curl; macOS/Linux and Windows)
integrations/manifest.json        how the app detects each installed integration
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
