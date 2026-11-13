// Generates every agent's hook file from one mapping (pm/contracts/app-events.md §5).
// Run: node tools/gen-hooks.mjs   (tests fail if the committed files differ from its output)
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const hnArgs = (agent, state) => ["event", "--agent", agent, "--state", state, "--stdin-json"];
const hnLine = (agent, state) => ["hn", ...hnArgs(agent, state)].join(" ");

// [event, matcher or null, state]
export const MAPPING = {
  claude: [
    ["UserPromptSubmit", null, "working"],
    ["PostToolUse", "*", "working"],
    ["Notification", "permission_prompt|idle_prompt", "needs"],
    ["PermissionRequest", "*", "needs"],
    ["PreToolUse", "AskUserQuestion", "needs"],
    ["Stop", null, "done"],
    ["SessionEnd", null, "end"],
  ],
  codex: [
    ["UserPromptSubmit", null, "working"],
    ["PostToolUse", "*", "working"],
    ["PermissionRequest", "*", "needs"],
    ["Stop", null, "done"],
    ["SessionEnd", null, "end"],
  ],
  cursor: [
    ["beforeSubmitPrompt", null, "working"],
    ["stop", null, "done"],
    ["sessionEnd", null, "end"],
  ],
};

// Claude Code: exec form (no shell on the PC). Second entry runs only in cloud VMs
// (cloud/hn-cloud.sh exits at once unless CLAUDE_CODE_REMOTE=true).
function claude() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.claude) {
    const group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [
      { type: "command", command: "hn", args: hnArgs("claude", state), async: true, timeout: 5 },
      { type: "command", command: "sh", args: ["${CLAUDE_PLUGIN_ROOT}/cloud/hn-cloud.sh", state],
        async: true, timeout: 5, cloud: "skip" },
    ];
    (hooks[ev] ??= []).push(group);
  }
  return { description: "HumanNeeded: reports Claude's state to the HumanNeeded app (hn) or, in cloud sessions, to the relay.", hooks };
}

// Codex: shell string (Codex has no exec form). SessionEnd is always synchronous in Codex
// (max 3 s), so no async there.
function codex() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.codex) {
    const h = { type: "command", command: hnLine("codex", state), timeout: ev === "SessionEnd" ? 2 : 5 };
    if (ev !== "SessionEnd") h.async = true;
    const group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [h];
    (hooks[ev] ??= []).push(group);
  }
  return { description: "HumanNeeded: reports Codex's state to the HumanNeeded app (hn).", hooks };
}

// Cursor: ~/.cursor/hooks.json format (version 1, flat entries).
function cursor() {
  const hooks = {};
  for (const [ev, , state] of MAPPING.cursor) {
    (hooks[ev] ??= []).push({ command: hnLine("cursor", state), timeout: 5 });
  }
  return { version: 1, hooks };
}

export const OUTPUTS = {
  "plugins/claude/hooks/hooks.json": claude(),
  "plugins/codex/hooks/hooks.json": codex(),
  "plugins/cursor/hooks.json": cursor(),
};

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  for (const [rel, obj] of Object.entries(OUTPUTS)) {
    const p = join(root, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
    console.log("wrote", rel);
  }
}
