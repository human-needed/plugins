// Integration tests (pm/contracts/testing.md §2 "Integrations"): hook files match app-events §5
// and D-047 (local HTTP hub on 127.0.0.1:24816), curl hooks reach a stand-in hub, cloud hook
// follows hn-relay/1 §4.
//
//   node tests/run.mjs        (node >= 18, sh, curl; PowerShell on Windows. No npm packages.)
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, delimiter } from "node:path";
import { fileURLToPath } from "node:url";
import { OUTPUTS, PORT, eventUrl } from "../tools/gen-hooks.mjs";
import { startHub } from "./fake-hub.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const isWin = process.platform === "win32";

let pass = 0, fail = 0;
const ok = (cond, name, extra = "") => {
  if (cond) { pass++; console.log("  ok   " + name); }
  else { fail++; console.log("  FAIL " + name + (extra ? "  -- " + extra : "")); }
};
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sha = (s) => createHash("sha256").update(s).digest("hex");
const readJson = (rel) => JSON.parse(readFileSync(join(root, rel), "utf8"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The contract, written out independently of tools/gen-hooks.mjs (app-events §5).
const CONTRACT = {
  claude: { UserPromptSubmit: ["working"], PostToolUse: ["working"], Notification: ["needs"],
            PermissionRequest: ["needs"], PreToolUse: ["needs"], Stop: ["done"], SessionEnd: ["end"] },
  codex:  { UserPromptSubmit: ["working"], PostToolUse: ["working"], PermissionRequest: ["needs"],
            Stop: ["done"], SessionEnd: ["end"] },
  cursor: { beforeSubmitPrompt: ["working"], stop: ["done"], sessionEnd: ["end"] },
};
const MATCHERS = { "claude:Notification": "permission_prompt|idle_prompt", "claude:PreToolUse": "AskUserQuestion" };
const expectArgs = (agent, state) => ["event", "--agent", agent, "--state", state, "--stdin-json"];

// ---------------------------------------------------------------------------------------------
console.log("1. hook files");
for (const [rel, obj] of Object.entries(OUTPUTS)) {
  ok(readFileSync(join(root, rel), "utf8") === JSON.stringify(obj, null, 2) + "\n",
     `${rel} matches tools/gen-hooks.mjs (run it after editing the mapping)`);
}

// Flatten each agent's file to [{event, matcher, hook}]
function entries(rel) {
  const f = readJson(rel);
  ok(!("modules" in f) && !("modules" in f.hooks), `${rel}: no "modules" key`);
  if (f.version === 1) return Object.entries(f.hooks).flatMap(([ev, list]) => list.map((h) => ({ ev, matcher: h.matcher, h })));
  return Object.entries(f.hooks).flatMap(([ev, groups]) =>
    groups.flatMap((g) => g.hooks.map((h) => ({ ev, matcher: g.matcher, h }))));
}
const URL_RE = /http:\/\/127\.0\.0\.1:24816\/v1\/event\/([a-z0-9-]+)\/(working|needs|done|idle|end)/;
// What an entry sends: {kind: "http"|"curl"|"cloud", agent, state}
function what(e) {
  if (e.h.type === "http") { const m = e.h.url.match(URL_RE); return m && e.h.url === m[0] ? { kind: "http", agent: m[1], state: m[2] } : { kind: "?" }; }
  if (e.h.command === "sh") return { kind: "cloud", state: e.h.args[1] };
  const m = (e.h.command ?? "").match(URL_RE);
  return m ? { kind: "curl", agent: m[1], state: m[2] } : { kind: "?" };
}

const FILES = { claude: ["plugins/claude/hooks/hooks.json"], codex: ["plugins/codex/hooks.json"],
                cursor: ["plugins/cursor/hooks.json", "plugins/cursor/hooks.windows.json"] };
const ALL = {};
for (const [agent, rels] of Object.entries(FILES)) {
  for (const rel of rels) {
    const es = entries(rel);
    ALL[rel] = es;
    const got = {};
    if (agent === "cursor") ok(readJson(rel).version === 1, `${rel}: version 1`);
    for (const e of es) {
      const w = what(e);
      ok(w.kind !== "?", `${rel} ${e.ev}: known hook`, JSON.stringify(e.h));
      if (w.kind === "cloud" || w.kind === "?") continue;
      ok(w.agent === agent, `${rel} ${e.ev}: agent ${agent}`);
      if (!(got[e.ev] ??= []).includes(w.state)) got[e.ev].push(w.state);
      const m = MATCHERS[`${agent}:${e.ev}`];
      if (m) ok(e.matcher === m, `${agent} ${e.ev}: matcher ${m}`, e.matcher);
      if (w.kind === "http") ok(e.h.timeout === 1 && !("headers" in e.h), `${rel} ${e.ev}: http hook, timeout 1 s`);
      if (w.kind === "curl") {
        const cmds = [e.h.command, e.h.commandWindows].filter(Boolean);
        for (const c of cmds) {
          const win = c.startsWith("curl.exe ");
          ok(win ? c.endsWith("; exit 0") : c.startsWith("curl ") && c.endsWith(" || true"), `${rel} ${e.ev}: curl ${win ? "windows" : "posix"} form, exit 0`);
          ok(c.includes("--noproxy '*'") && c.includes("-H 'Content-Type: application/json'") && c.includes(" -s ") &&
             c.includes(win ? "-o NUL" : "-o /dev/null") && c.includes(win ? "--data-binary '@-'" : "--data-binary @-") &&
             c.match(URL_RE)[0] === eventUrl(agent, w.state), `${rel} ${e.ev}: curl options`);
        }
        if (agent === "codex") {
          ok(e.h.command && e.h.commandWindows?.startsWith("curl.exe "), `codex ${e.ev}: command + commandWindows`);
          ok(e.ev === "SessionEnd" ? !e.h.async && e.h.timeout <= 3 : e.h.async === true, `codex ${e.ev}: async (SessionEnd sync, <= 3 s)`);
        }
        if (agent === "cursor") ok(rel.endsWith("windows.json") === e.h.command.startsWith("curl.exe "), `${rel} ${e.ev}: OS form`);
      }
    }
    ok(eq(got, CONTRACT[agent]), `${rel}: mapping equals app-events §5`, JSON.stringify(got));
  }
}
for (const e of ALL["plugins/claude/hooks/hooks.json"]) {
  const w = what(e);
  if (w.kind !== "cloud") continue;
  ok(e.h.args[0] === "${CLAUDE_PLUGIN_ROOT}/cloud/hn-cloud.sh" && CONTRACT.claude[e.ev]?.[0] === w.state &&
     e.h.async === true && e.h.cloud === "skip", `claude ${e.ev}: cloud hook -> ${w.state}`);
}
ok(ALL["plugins/claude/hooks/hooks.json"].filter((e) => what(e).kind === "cloud").length === Object.keys(CONTRACT.claude).length,
   "claude: one cloud hook per event");

ok(readFileSync(join(root, "plugins/claude/cloud/hn-cloud.sh"), "utf8").includes('RELAY_POST="https://relay.human-needed.com/v1/h/"'),
   "cloud hook posts to relay.human-needed.com/v1/h/ (relay-api §1)");
const plugin = readJson("plugins/claude/.claude-plugin/plugin.json");
ok(plugin.name === "humanneeded" && /^2\./.test(plugin.version), "claude plugin.json name/version 2.x");
const mkt = readJson(".claude-plugin/marketplace.json");
ok(mkt.plugins.length === 1 && mkt.plugins[0].source === "./plugins/claude", "marketplace lists one Claude plugin");
const manifest = readJson("integrations/manifest.json");
ok(eq(Object.keys(manifest.agents).sort(), ["claude", "codex", "cursor"]), "integrations/manifest.json has 3 agents");

// ---------------------------------------------------------------------------------------------
console.log("2. curl hooks against a stand-in hub (Codex, Cursor)");
{
  const recs = [];
  const hub = await startHub({ port: PORT, onRequest: (r) => recs.push(r) });
  // Run a hook command like the agent does: sh -c on macOS/Linux, PowerShell on Windows.
  const runHook = (cmd, input, env = process.env) => new Promise((res) => {
    const t = Date.now();
    const p = isWin && cmd.includes("curl.exe ")
      ? spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", cmd], { env })
      : spawn("sh", ["-c", cmd], { env });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    p.on("close", (code) => res({ code, out, ms: Date.now() - t }));
    p.stdin.on("error", () => {});
    p.stdin.end(input);
  });
  const deadProxy = { ...process.env, HTTP_PROXY: "http://127.0.0.1:9", HTTPS_PROXY: "http://127.0.0.1:9",
                      http_proxy: "http://127.0.0.1:9", ALL_PROXY: "http://127.0.0.1:9", NO_PROXY: "" };
  const forms = [];
  for (const rel of ["plugins/codex/hooks.json", "plugins/cursor/hooks.json", "plugins/cursor/hooks.windows.json"]) {
    for (const e of ALL[rel]) {
      for (const cmd of [e.h.command, e.h.commandWindows].filter(Boolean)) {
        const win = cmd.startsWith("curl.exe ");
        if (win && !isWin) continue;                    // PowerShell forms on Windows only; sh forms everywhere
        forms.push({ rel, e, cmd });
      }
    }
  }
  let i = 0;
  for (const { rel, e, cmd } of forms) {
    const w = what(e);
    const sid = `s-${++i}`;
    // Non-ASCII on purpose: the app must get the hook's bytes exactly (no BOM, no CRLF, no re-encoding).
    const input = JSON.stringify({ [w.agent === "cursor" ? "conversation_id" : "session_id"]: sid, hook_event_name: e.ev, prompt: "é 日本 ✓" });
    const n = recs.length;
    const r = await runHook(cmd, input, deadProxy);
    const rec = recs[n];
    ok(r.code === 0 && r.out === "", `${rel} ${e.ev}: exit 0, prints nothing (${r.ms} ms)`, JSON.stringify(r));
    ok(recs.length === n + 1 && rec.method === "POST" && rec.path === `/v1/event/${w.agent}/${w.state}` &&
       rec.headers["content-type"] === "application/json" && rec.headers.host === `127.0.0.1:${PORT}` &&
       !rec.headers.origin && rec.body === input && rec.bytes === Buffer.byteLength(input),
       `${rel} ${e.ev}: POST /v1/event/${w.agent}/${w.state} with the exact hook bytes, past a dead proxy`, JSON.stringify(rec));
  }
  // Windows: a PowerShell profile or host that sets $OutputEncoding to UTF-8 (with BOM) must not
  // change what is sent (it did with `$input | curl.exe`: CI run 43658194923).
  for (const { rel, e, cmd } of forms.filter((f) => isWin && f.cmd.startsWith("curl.exe ")).slice(0, 1)) {
    const input = JSON.stringify({ session_id: "bom", prompt: "é 日本" });
    const n = recs.length;
    const r = await runHook("$OutputEncoding = [Text.Encoding]::UTF8; " + cmd, input);
    ok(r.code === 0 && recs[n]?.body === input && recs[n]?.bytes === Buffer.byteLength(input),
       `${rel} ${e.ev}: UTF-8 $OutputEncoding profile -> exact bytes, no BOM`, JSON.stringify(recs[n]));
  }
  ok(forms.length > 0, `${forms.length} curl hook forms run on this OS`);
  {
    const { cmd } = forms[0];
    const big = JSON.stringify({ session_id: "big", tool_response: "x".repeat(8 << 20) });
    const n = recs.length;
    const r = await runHook(cmd, big);
    ok(r.code === 0 && r.out === "" && recs[n]?.bytes === big.length && r.ms < 3000,
       `8 MB hook input sent in ${r.ms} ms`, `${recs[n]?.bytes}`);
  }
  await new Promise((r) => hub.close(r));
  for (const { rel, e, cmd } of forms.slice(0, 3)) {
    const r = await runHook(cmd, '{"session_id":"down"}');
    ok(r.code === 0 && r.out === "" && r.ms < 2500, `${rel} ${e.ev}: app closed -> exit 0, silent, ${r.ms} ms`);
  }
  // A hung app: the hook gives up within curl's 1.5 s limit (+ shell start).
  const hung = createServer(() => {});
  await new Promise((r) => hung.listen(PORT, "127.0.0.1", r));
  const r = await runHook(forms[0].cmd, '{"session_id":"hung"}');
  ok(r.code === 0 && r.out === "" && r.ms < 3000, `app hung -> exit 0, silent, ${r.ms} ms`);
  hung.closeAllConnections?.();
  await new Promise((res) => hung.close(res));
}

// ---------------------------------------------------------------------------------------------
console.log("3. cloud hook (hn-relay/1 §4) against a local relay stand-in");
const script = join(root, "plugins", "claude", "cloud", "hn-cloud.sh");
const posts = [];
let replyCode = 202;
const reply429 = new Map();   // session hash -> 429s still to send (per session: other tests' heartbeats can't use them up)
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const p = { t: Date.now(), path: req.url, body: JSON.parse(body) };
    posts.push(p);
    const left = reply429.get(p.body.h) ?? 0;
    if (left > 0) { reply429.set(p.body.h, left - 1); res.writeHead(429); return res.end(); }
    res.writeHead(replyCode); res.end();
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const home = mkdtempSync(join(tmpdir(), "hn-cloud-home-"));
const acct = "11111111-2222-3333-4444-555555555555";
writeFileSync(join(home, ".claude.json"), JSON.stringify({ oauthAccount: { accountUuid: acct } }));
const K = sha("humanneeded-account:" + acct).slice(0, 32);
const cdir = join(home, "hn-cloud");
const cenv = { ...process.env, HOME: home, CLAUDE_CODE_REMOTE: "true", HN_RELAY_URL: `http://127.0.0.1:${port}/v1/h/`,
               HN_HB_INTERVAL: "1", HN_CLOUD_DIR: cdir, HN_DEV: "1" };

// Run the hook like Claude would: `sh hn-cloud.sh <state>` with hook JSON on stdin.
// Returns {code, stdout, ms}. `parentHold` keeps a parent alive (stands in for the Claude process).
function runCloud(state, sid, env = cenv, input) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const p = spawn("sh", [script, state], { env });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    p.on("close", (code) => resolve({ code, out, ms: Date.now() - t0 }));
    p.stdin.on("error", () => {});
    p.stdin.end(input ?? JSON.stringify({ session_id: sid, hook_event_name: "X" }));
  });
}
const h = (sid) => sha(sid).slice(0, 16);

{
  const r = await runCloud("working", "local-1", { ...cenv, CLAUDE_CODE_REMOTE: "" });
  await sleep(300);
  ok(r.code === 0 && r.out === "" && posts.length === 0, "not in a cloud VM: exits at once, posts nothing", JSON.stringify(r));
  // Local entrypoints never post; cloud ones (web: CLAUDE_CODE_REMOTE, Cowork: remote_cowork) do.
  for (const ep of ["cli", "claude-desktop", "sdk-ts", "claude-vscode", ""]) {
    const n = posts.length;
    await runCloud("done", "local-" + ep, { ...cenv, CLAUDE_CODE_REMOTE: "", CLAUDE_CODE_ENTRYPOINT: ep });
    ok(posts.length === n, `entrypoint "${ep}" (local): posts nothing`);
  }
  for (const ep of ["remote_cowork", "remote"]) {
    const n = posts.length;
    await runCloud("done", "cloud-" + ep, { ...cenv, CLAUDE_CODE_REMOTE: "", CLAUDE_CODE_ENTRYPOINT: ep });
    ok(posts.slice(n).some((p) => p.body.h === h("cloud-" + ep)), `entrypoint "${ep}" (cloud): posts`);
  }
  posts.length = 0;
}
{
  // Without HN_DEV=1 the test overrides are ignored. No account here, so nothing is sent to the
  // real relay; the override dir staying empty shows HN_CLOUD_DIR was ignored.
  const { HN_DEV, ...noDev } = cenv;
  const noAcct = mkdtempSync(join(tmpdir(), "hn-nodev-"));
  const odir = join(noAcct, "override");
  posts.length = 0;
  const r = await runCloud("done", "s-nodev", { ...noDev, HOME: noAcct, HN_CLOUD_DIR: odir });
  await sleep(300);
  ok(r.code === 0 && r.out === "" && posts.length === 0 && !existsSync(odir), "overrides ignored without HN_DEV=1");
  rmSync(noAcct, { recursive: true, force: true });
}
{
  posts.length = 0;
  const r = await runCloud("done", "s-done");
  ok(r.code === 0 && r.out === "" && r.ms < 4000, `done: exit 0, silent, ${r.ms} ms`);
  const p = posts[0];
  ok(posts.length === 1 && p.path === `/v1/h/${K}`, "done: POST to /h/<K>", JSON.stringify(posts));
  ok(p && eq(Object.keys(p.body), ["v", "s", "h", "ts", "hb"]) && p.body.v === 1 && p.body.s === "done" &&
     p.body.h === h("s-done") && p.body.hb === false && Math.abs(p.body.ts - Date.now()) < 10000 &&
     JSON.stringify(p.body).length <= 512, "done: body {v:1,s,h=sha256(sid)[:16],ts ms,hb:false}", JSON.stringify(p?.body));
  await sleep(1500);
  ok(posts.length === 1, "done: no heartbeat");
}
{
  // Behaviour, not timing: count this session's posts only (a heartbeat from another test may
  // land meanwhile); the time bound is only a hang guard (worst case is ~3.7 s of jitter).
  const mine = (sid) => posts.filter((p) => p.body.h === h(sid) && !p.body.hb);
  reply429.set(h("s-429"), 2);
  const r = await runCloud("done", "s-429");
  ok(r.code === 0 && mine("s-429").length === 3 && mine("s-429").every((p) => p.body.s === "done") && r.ms < 15000,
     `429 twice: retried twice, then delivered`, JSON.stringify(mine("s-429").map((p) => p.body)));
  reply429.set(h("s-429b"), 99);
  const r2 = await runCloud("end", "s-429b");
  await sleep(1000);                                  // any extra retry would show up here
  ok(r2.code === 0 && mine("s-429b").length === 3 && r2.ms < 15000,
     `429 always: gives up after 2 retries`, JSON.stringify(mine("s-429b").map((p) => p.body)));
  reply429.clear();
}
// The heartbeat loop watches the hook's parent ($PPID = the Claude process). Stand in for Claude
// with a shell that runs the hook and then stays alive (a native parent such as node would show
// up as PPID 1 under MSYS on Windows).
const claudes = [];
function runUnderClaude(state, sid) {
  const f = join(home, `in-${sid}-${claudes.length}.json`);
  writeFileSync(f, JSON.stringify({ session_id: sid, hook_event_name: "X" }));
  const q = (x) => x.replaceAll("\\", "/");
  const pidf = f + ".pid";
  const p = spawn("sh", ["-c", `echo $$ > "${q(pidf)}"; sh "${q(script)}" ${state} < "${q(f)}"; exec sleep 600`], { env: cenv });
  // kill through sh so MSYS (Windows) really ends the process the loop watches
  p.die = () => spawnSync("sh", ["-c", `kill -9 $(cat "${q(pidf)}") 2>/dev/null; true`]);
  claudes.push(p);
  return p;
}
const hbOf = (sid) => posts.filter((p) => p.body.hb === true && p.body.h === h(sid));
{
  posts.length = 0;
  runUnderClaude("working", "s-hb");
  await sleep(4500);
  const hbs = hbOf("s-hb");
  ok(hbs.length >= 2 && hbs.every((p) => p.body.s === "working"), `working: heartbeats (${hbs.length} in 4.5 s at 1 s)`);
  runUnderClaude("needs", "s-hb");
  await sleep(2500);
  ok(hbOf("s-hb").some((p) => p.body.s === "needs"), "needs: heartbeat carries the new state");
  runUnderClaude("done", "s-hb");
  await sleep(1500);
  const n1 = hbOf("s-hb").length;
  await sleep(2500);
  ok(hbOf("s-hb").length === n1, `done: heartbeat stops`);
  // A late "working" from a hook that started before "done" must not restart it.
  const line = readFileSync(join(cdir, h("s-hb") + ".state"), "utf8").trim().split(" ");
  writeFileSync(join(cdir, h("s-hb") + ".state"), `${Number(line[0]) + 60000} done
`);
  runUnderClaude("working", "s-hb");
  await sleep(2500);
  ok(hbOf("s-hb").length === n1, "late working after done: no heartbeat");
}
{
  // Heartbeat stops when the Claude process (the hook's parent) dies.
  const parent = runUnderClaude("working", "s-dead");
  await sleep(2500);
  const n1 = hbOf("s-dead").length;
  parent.die();
  await sleep(2500);
  const n2 = hbOf("s-dead").length;
  await sleep(3000);
  ok(n1 >= 1 && hbOf("s-dead").length === n2, `agent gone: heartbeat stops (${n1} before, ${n2 - n1} while dying, then 0)`);
}
{
  posts.length = 0;
  const big = JSON.stringify({ session_id: "s-big", hook_event_name: "PostToolUse", tool_response: "x".repeat(8 << 20) });
  const r = await runCloud("done", "s-big", cenv, big);
  // Find our post: a heartbeat from an earlier test may land first.
  ok(r.code === 0 && r.ms < 4000 && posts.some((p) => p.body.h === h("s-big")), `8 MB hook input: ${r.ms} ms`,
     JSON.stringify({ code: r.code, out: r.out, posts: posts.map((p) => p.body) }));
}
{
  posts.length = 0;
  const r = await runCloud("done", "x", cenv, "not json");
  ok(r.code === 0 && posts.find((p) => !p.body.hb)?.body.h === h("default"), "no session_id: session 'default'");
  const r2 = await runCloud("bogus", "x");
  ok(r2.code === 0 && posts.filter((p) => !p.body.hb).length === 1, "unknown state: ignored");
  const noAcct = mkdtempSync(join(tmpdir(), "hn-noacct-"));
  const r3 = await runCloud("done", "x", { ...cenv, HOME: noAcct });
  ok(r3.code === 0 && r3.out === "" && posts.filter((p) => !p.body.hb).length === 1, "no accountUuid: silent, no post");
  rmSync(noAcct, { recursive: true, force: true });
  server.close();
  const r4 = await runCloud("done", "x", { ...cenv, HN_RELAY_URL: "http://127.0.0.1:9/h/" });
  ok(r4.code === 0 && r4.out === "" && r4.ms < 4000, `relay down: silent, ${r4.ms} ms`);
  ok(!readFileSync(join(cdir, "log"), "utf8").includes(K), "log never contains the key");
}
server.close();
for (const p of claudes) p.die();
await sleep(1500);
rmSync(home, { recursive: true, force: true });

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
