# HumanNeeded plugins

[![tests](https://github.com/human-needed/plugins/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/human-needed/plugins/actions/workflows/test.yml)

Agent integrations for the [HumanNeeded](https://human-needed.com) puck: a USB desk light that
glows and chimes when your AI coding agent is working, done, or needs you.

The **HumanNeeded app** runs on your computer and owns the puck. Install the app first, then
add the agents you use below. Each one sends its state to the app on your computer only
(`http://127.0.0.1:24816`). If the app isn't running, nothing happens.

## Claude Code

Choose one way. They all do the same thing.

### Way 1: the Claude app

1. Open the Claude app and go to **Customize → Plugins**.
2. Click **Add marketplace** and enter `human-needed/plugins`.
3. Find **humanneeded** and click **Install**.
4. Start a new Claude Code session.
5. Check: send any message. The puck glows "working", then "done" when Claude stops.

### Way 2: inside Claude Code (terminal, desktop or VS Code)

1. Type `/plugin marketplace add human-needed/plugins` and press Enter.
2. Type `/plugin install humanneeded@humanneeded` and press Enter.
3. Turn on updates: type `/plugin`, open **Marketplaces**, pick **humanneeded**, choose
   **Enable auto-update**.
4. Start a new session.
5. Check: send any message. The puck glows "working", then "done" when Claude stops.

### Way 3: a terminal

1. Run `claude plugin marketplace add human-needed/plugins`
2. Run `claude plugin install humanneeded@humanneeded`
3. Start a new Claude Code session.
4. Check: send any message. The puck glows "working", then "done" when Claude stops.

Ask Claude "test my puck", "mute for an hour" or "make needs purple".
If you use an HTTP proxy, add `127.0.0.1` to `NO_PROXY`.

## Cowork (Claude cloud tasks)

1. In the HumanNeeded app, turn on the **cloud link**.
2. In Claude, go to **Customize → Plugins → Add → Add marketplace**.
3. Enter `human-needed/plugins`, then **Install** humanneeded. (Optional: turn on **Sync automatically**.)
4. Start a Cowork task.
5. Check: the puck glows "working" while the task runs, then "done".

In the cloud the plugin's [`cloud/hn-cloud.sh`](plugins/claude/cloud/hn-cloud.sh) sends each state
through the HumanNeeded relay to the app. On your own computer that script does nothing.

## Codex

Choose one way. They all do the same thing.

### Way 1: a terminal

1. Run `codex plugin marketplace add human-needed/plugins`
2. Run `codex plugin add humanneeded@humanneeded`
3. Restart Codex.
4. Trust the hooks (Codex needs this once): type `/hooks` in Codex, or open **Settings → Hooks** in
   the Codex app, and trust the HumanNeeded hooks.
5. Check: send any message. The puck glows "working", then "done".

### Way 2: inside Codex

1. Run `codex plugin marketplace add human-needed/plugins` once in a terminal.
2. In Codex, type `/plugins`, find **HumanNeeded** and install it.
3. Trust the hooks: type `/hooks` (or **Settings → Hooks** in the app) and trust the HumanNeeded hooks.
4. Check: send any message. The puck glows "working", then "done".

To update: run `codex plugin marketplace upgrade humanneeded`, then trust the changed hooks again.
Set up the old way (our entries in `~/.codex/hooks.json`)? Delete those entries, or the puck
gets every event twice.

## Cursor

Choose one way. They all do the same thing.

### Way 1: one command

1. Run the command for your computer. It never overwrites a file you already have.

   macOS / Linux:

   ```bash
   [ -e ~/.cursor/hooks.json ] || { mkdir -p ~/.cursor && curl -fsSL -o ~/.cursor/hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/cursor/hooks.json; }
   ```

   Windows (PowerShell):

   ```powershell
   if (!(Test-Path $HOME\.cursor\hooks.json)) { mkdir -Force $HOME\.cursor | Out-Null; curl.exe -fsSL -o $HOME\.cursor\hooks.json https://raw.githubusercontent.com/human-needed/plugins/main/plugins/cursor/hooks.windows.json }
   ```

2. Check: send a message in Cursor's agent. The puck glows "working", then "done".

### Way 2: you already have `~/.cursor/hooks.json`

1. Open [`hooks.json`](plugins/cursor/hooks.json) (Windows:
   [`hooks.windows.json`](plugins/cursor/hooks.windows.json)).
2. Copy each entry under `"hooks"` into the same place in your `~/.cursor/hooks.json`. Save.
3. Check: send a message in Cursor's agent. The puck glows "working", then "done".

Cursor shows working and done only (it has no "needs you" hook). It has no auto-update for hooks:
to update, delete our entries and repeat.

## Layout

```
.claude-plugin/marketplace.json   Claude Code marketplace (this repo)
plugins/claude/                   Claude Code plugin "humanneeded": HTTP hooks, cloud hook, skill
plugins/codex/                    Codex plugin "humanneeded" (.codex-plugin/, hooks.json: curl)
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
