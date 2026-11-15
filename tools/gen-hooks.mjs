// Generates every agent's hook file from one mapping (pm/contracts/app-events.md §5).
// Run: node tools/gen-hooks.mjs   (tests fail if the committed files differ from its output)
//
// D-047: the HumanNeeded app is a local HTTP hub. Every event is
//   POST http://127.0.0.1:24816/v1/event/<agent>/<state>   body = the agent's hook JSON
// Claude uses native HTTP hooks; Codex and Cursor pipe stdin into the OS's built-in curl.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export const PORT = 24816;
export const eventUrl = (agent, state) => `http://127.0.0.1:${PORT}/v1/event/${agent}/${state}`;

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

// curl: silent, no output, ≤ 1.5 s (0.3 s connect: Windows takes ~1-2 s to refuse a closed
// loopback port), never through a proxy, always exit 0.
const CURL_OPTS = "-s -o {NULL} --connect-timeout 0.3 -m 1.5 --noproxy '*' -H 'Content-Type: application/json' --data-binary {AT}";
// macOS/Linux: sh -c. curl reads the hook JSON from stdin itself.
export const curlPosix = (agent, state) =>
  `curl ${CURL_OPTS.replace("{NULL}", "/dev/null").replace("{AT}", "@-")} ${eventUrl(agent, state)} || true`;
// Windows: PowerShell (Cursor documented; Codex: "command hooks require PowerShell on Windows").
// curl.exe, not curl (an Invoke-WebRequest alias in Windows PowerShell). curl.exe inherits the
// hook's stdin and sends its bytes as they are. Never pipe `$input |`: PowerShell re-encodes it with
// $OutputEncoding (adds a BOM when a profile or host sets UTF-8, mangles non-ASCII, appends CRLF).
export const curlWindows = (agent, state) =>
  `curl.exe ${CURL_OPTS.replace("{NULL}", "NUL").replace("{AT}", "'@-'")} ${eventUrl(agent, state)}; exit 0`;

// Claude Code: native HTTP hooks (no process at all on the PC). HTTP hooks are always
// synchronous in Claude Code (async is ignored), so keep the timeout at 1 s; the app must
// answer at once. The second entry does its work only in cloud VMs: cloud/hn-cloud.sh checks the
// environment itself (CLAUDE_CODE_REMOTE / CLAUDE_CODE_ENTRYPOINT) and exits at once anywhere else.
// The HTTP hook in a VM hits nothing and fails in ms. Only documented hook fields (no "cloud").
function claude() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.claude) {
    const group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [
      { type: "http", url: eventUrl("claude", state), timeout: 1 },
      { type: "command", command: "sh", args: ["${CLAUDE_PLUGIN_ROOT}/cloud/hn-cloud.sh", state],
        async: true, timeout: 5 },
    ];
    (hooks[ev] ??= []).push(group);
  }
  return { description: "HumanNeeded: reports Claude's state to the HumanNeeded app (local HTTP) or, in cloud sessions, to the relay.", hooks };
}

// Codex: ~/.codex/hooks.json. `command` for macOS/Linux, `commandWindows` for Windows.
// SessionEnd is always synchronous in Codex (max 3 s), so no async there.
function codex() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.codex) {
    const h = { type: "command", command: curlPosix("codex", state), commandWindows: curlWindows("codex", state),
                timeout: 3 };
    if (ev !== "SessionEnd") h.async = true;
    const group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [h];
    (hooks[ev] ??= []).push(group);
  }
  return { description: "HumanNeeded: reports Codex's state to the HumanNeeded app (local HTTP).", hooks };
}

// Cursor: ~/.cursor/hooks.json (version 1). No per-OS field, so one file per OS family.
function cursor(os) {
  const hooks = {};
  for (const [ev, , state] of MAPPING.cursor) {
    const command = os === "windows" ? curlWindows("cursor", state) : curlPosix("cursor", state);
    (hooks[ev] ??= []).push({ command, timeout: 3 });
  }
  return { version: 1, hooks };
}

export const OUTPUTS = {
  "plugins/claude/hooks/hooks.json": claude(),
  "plugins/codex/hooks.json": codex(),
  "plugins/cursor/hooks.json": cursor("posix"),
  "plugins/cursor/hooks.windows.json": cursor("windows"),
};

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  for (const [rel, obj] of Object.entries(OUTPUTS)) {
    const p = join(root, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
    console.log("wrote", rel);
  }
}
