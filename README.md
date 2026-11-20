# HumanNeeded plugins

[![tests](https://github.com/human-needed/plugins/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/human-needed/plugins/actions/workflows/test.yml)

Agent integrations for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that
glows and chimes when your AI coding agent is working, done, or needs you.

## Install

Setup steps live on the website only:

- Claude (Code tab, Cowork, CLI): https://human-needed.com/start/claude/
- Codex: https://human-needed.com/start/codex/
- Cursor: https://human-needed.com/start/cursor/

## How it works

The HumanNeeded app owns the puck. Each integration POSTs the agent's hook JSON to the app on the
same computer (`http://127.0.0.1:24816/v1/event/<agent>/<state>`). If the app isn't running,
nothing happens. In Claude cloud sessions (Cowork),
[`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) sends each state through the HumanNeeded
relay instead; on your own computer it does nothing.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin "humanneeded": HTTP hooks, cloud hook, skill
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
