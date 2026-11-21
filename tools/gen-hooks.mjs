// Generates every agent's hook file from one mapping (pm/contracts/app-events.md §5).
// Run: node tools/gen-hooks.mjs   (tests fail if the committed files differ from its output)
//
// D-047: the HumanNeeded app is a local HTTP hub. Every event is
//   POST http://127.0.0.1:24816/v1/event/<agent>/<state>   body = the agent's hook JSON
// Every agent pipes the hook JSON into the OS's built-in curl.
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
    ["PreToolUse", "AskUserQuestion|mcp__computer-use__request_access|mcp__computer-use__request_teach_access", "needs"],
    ["Stop", null, "done"],
    ["SessionEnd", null, "end"],
  ],
  codex: [
    ["UserPromptSubmit", null, "working"],
    ["PostToolUse", "*", "working"],
    ["PermissionRequest", "*", "needs"],
    // Network/sandbox requests from the agent (code mode's tools.request_permissions) never fire
    // PermissionRequest; PostToolUse sets working again once answered (app-events 2.2, FAIL-3).
    ["PreToolUse", "request_permissions", "needs"],
    ["Stop", null, "done"],
    // The Stop button: Stop doesn't fire on an interrupt (app-events 2.2, FAIL-4).
    ["Interrupt", null, "idle"],
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

// Claude Code: exec-form command hooks (`command` + `args`: spawned directly, no shell) running the
// OS's built-in curl (macOS, Linux, Windows 10 1803+ System32\curl.exe). curl reads the hook JSON from
// stdin. Directory rule (app-events 2.3): no http:// hooks, no variables, no inline code. All async: never
// blocks Claude; ≤ 1 s (0.3 s connect, 1 s total); no proxy for 127.0.0.1; the app answers 204 (no body).
// The second entry does its work only in cloud VMs: cloud/hn-cloud.sh checks the environment itself
// (CLAUDE_CODE_REMOTE / CLAUDE_CODE_ENTRYPOINT) and exits at once anywhere else. Only documented fields.
export const claudeCurlArgs = (state) => ["-s", "--connect-timeout", "0.3", "-m", "1", "--noproxy", "127.0.0.1",
  "-H", "Content-Type: application/json", "--data-binary", "@-", eventUrl("claude", state)];
function claude() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.claude) {
    const group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [
      { type: "command", command: "curl", args: claudeCurlArgs(state), async: true, timeout: 1 },
      { type: "command", command: "sh", args: ["${CLAUDE_PLUGIN_ROOT}/cloud/hn-cloud.sh", state],
        async: true, timeout: 5 },
    ];
    (hooks[ev] ??= []).push(group);
  }
  return { description: "HumanNeeded: reports Claude's state to the HumanNeeded app (local, via curl) or, in cloud sessions, to the relay.", hooks };
}

// Codex: ~/.codex/hooks.json. `command` for macOS/Linux, `commandWindows` for Windows.
// SessionEnd is always synchronous in Codex (max 3 s), so no async there; Interrupt too (it runs
// as the turn is torn down, timeout max 3 s), so the post isn't dropped with the turn.
function codex() {
  const hooks = {};
  for (const [ev, matcher, state] of MAPPING.codex) {
    const h = { type: "command", command: curlPosix("codex", state), commandWindows: curlWindows("codex", state),
                timeout: 3 };
    if (ev !== "SessionEnd" && ev !== "Interrupt") h.async = true;
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
