# HumanNeeded plugins

[![tests](https://github.com/human-needed/plugins/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/human-needed/plugins/actions/workflows/test.yml)

Agent integrations for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that
glows and chimes when your AI coding agent is working, done, or needs you.

The **HumanNeeded app** runs on your computer and owns the puck. Install the app first, then
add the agents you use below. Each one sends its state to the app on your computer only
(`http://127.0.0.1:24816`). If the app isn't running, nothing happens.

## Claude Code

1. In a terminal, run:

   ```bash
   claude plugin marketplace add human-needed/plugins
   ```

   ```bash
   claude plugin install humanneeded@humanneeded
   ```

   Or inside Claude Code type `/plugin marketplace add human-needed/plugins`, then
   `/plugin install humanneeded@humanneeded`.
2. Turn on auto-update (it's off for non-official marketplaces): in Claude Code type `/plugin`,
   open **Marketplaces**, pick **humanneeded**, choose **Enable auto-update**.
3. Start a new session. The puck lights up.

This works in the terminal, the desktop app and VS Code on the same computer. Updates arrive
in the background and apply in your next session (or after `/reload-plugins`).

Ask Claude "test my puck", "mute for an hour" or "make needs purple".
If you use an HTTP proxy, add `127.0.0.1` to `NO_PROXY`.

## Codex

1. Download our hooks file (these commands never overwrite a file you already have):

   macOS / Linux:

   ```bash
   [ -e ~/.codex/hooks.json ] || { mkdir -p ~/.codex && curl -fsSL -o ~/.codex/hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/codex/hooks.json; }
   ```

   Windows (PowerShell):

   ```powershell
   if (!(Test-Path $HOME\.codex\hooks.json)) { mkdir -Force $HOME\.codex | Out-Null; curl.exe -fsSL -o $HOME\.codex\hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/codex/hooks.json }
   ```

   Already have one? Copy the entries of [`plugins/codex/hooks.json`](plugins/codex/hooks.json)
   into it instead.
2. Restart Codex and **approve the hooks**: `/hooks` in the CLI, or **Settings → Hooks** in the
   app. Codex won't run them until you do.

Codex has no auto-update for hooks. To update, delete the file (or our entries), repeat both
steps, and approve the changed hooks again.

## Cursor

1. Download our hooks file (these commands never overwrite a file you already have):

   macOS / Linux:

   ```bash
   [ -e ~/.cursor/hooks.json ] || { mkdir -p ~/.cursor && curl -fsSL -o ~/.cursor/hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/cursor/hooks.json; }
   ```

   Windows (PowerShell):

   ```powershell
   if (!(Test-Path $HOME\.cursor\hooks.json)) { mkdir -Force $HOME\.cursor | Out-Null; curl.exe -fsSL -o $HOME\.cursor\hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/cursor/hooks.windows.json }
   ```

   Already have one? Copy the entries of [`hooks.json`](plugins/cursor/hooks.json)
   (Windows: [`hooks.windows.json`](plugins/cursor/hooks.windows.json)) into it instead.
2. Done: Cursor picks it up at once. It shows working and done (Cursor has no "needs you" hook).

Cursor has no auto-update for hooks. To update, delete the file (or our entries) and repeat step 1.

## Cloud sessions (Claude)

Cloud Cowork tasks run your Claude plugins in a cloud machine. There the plugin's
[`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) sends each state through the
HumanNeeded relay to the app (turn on the cloud link in the app). On your own computer that
script does nothing.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin "humanneeded": HTTP hooks, cloud hook, skill
plugins/codex/hooks.json          Codex hooks (curl)
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
