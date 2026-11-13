# HumanNeeded plugins

Agent integrations for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that
glows and chimes when your AI coding agent is working, done, or needs you.

Every integration is thin: its hooks run one command,

```
hn event --agent <claude|codex|cursor> --state <working|needs|done|end> --stdin-json
```

`hn` comes with the **HumanNeeded app** (it puts `hn` on your PATH). The app owns the puck. Hook
mapping and the `hn` contract: `hn-events/1` (published in `human-needed/app`).
The HumanNeeded app can install and remove each integration for you (manifest:
[`integrations/manifest.json`](integrations/manifest.json)); manual steps are below.

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
Remove with `claude plugin uninstall humanneeded@humanneeded`.

The hooks run `hn` directly (no shell, PowerShell or Python on your computer).

**Cloud sessions** (Cowork, claude.ai/code) run their hooks in a Linux VM that can't reach your
computer. There [`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) posts each state to the
HumanNeeded relay (`hn-relay/1`) under a key derived from your Claude account, and keeps a
heartbeat while the session is working or waiting on you. The app receives it when you have
turned the cloud link on. On your own computer that script exits at once.

## Codex (CLI and app)

Codex runs hooks from `~/.codex/hooks.json`. Add the entries of
[`plugins/codex/hooks/hooks.json`](plugins/codex/hooks/hooks.json) to it (create the file if it
doesn't exist; keep any hooks you already have), restart Codex, then **approve the hooks**: Codex
skips new hooks until you trust them (`/hooks` in the CLI, Settings → Hooks in the app).

The same hooks ship as a Codex plugin in `plugins/codex/` (`.codex-plugin/plugin.json`).

## Cursor (desktop agent)

Add the entries of [`plugins/cursor/hooks.json`](plugins/cursor/hooks.json) to
`~/.cursor/hooks.json` (create it with `{"version": 1, "hooks": {}}` if missing). Cursor picks
it up at once. Cursor has no "needs you" hook yet, so the puck shows working and done only.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin "humanneeded": hooks, cloud hook, skill
plugins/codex/                    Codex hooks (+ plugin manifest)
plugins/cursor/hooks.json         Cursor user hooks
integrations/manifest.json        how the app detects / installs / removes each integration
tools/gen-hooks.mjs               generates all three hook files from one mapping table
tests/run.mjs                     tests (hook files, fake hn, cloud hook vs a local relay)
tests/fake-hn/                    fake `hn` (Rust): records every call, prints nothing
relay/                            the old cloud relay (being replaced, see human-needed/app)
```

Edit the mapping in `tools/gen-hooks.mjs`, never the hook files, then:

```bash
node tools/gen-hooks.mjs
```

```bash
cargo build --release --manifest-path tests/fake-hn/Cargo.toml
```

```bash
node tests/run.mjs
```

To release a change, bump `version` in `plugins/claude/.claude-plugin/plugin.json` and push.
