// Integration tests (pm/contracts/testing.md §2 "Integrations"): hook files valid, each hook
// calls `hn` with the right args (fake hn), cloud hook follows hn-relay/1 §4.
//
//   cargo build --release --manifest-path tests/fake-hn/Cargo.toml
//   node tests/run.mjs
//
// Needs node >= 18, sh, curl (cloud tests). No npm packages.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, delimiter } from "node:path";
import { fileURLToPath } from "node:url";
import { OUTPUTS } from "../tools/gen-hooks.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const isWin = process.platform === "win32";
const fakeDir = join(root, "tests", "fake-hn", "target", "release");
const fakeExe = join(fakeDir, isWin ? "hn.exe" : "hn");

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
function entries(agent) {
  if (agent === "cursor") {
    const f = readJson("plugins/cursor/hooks.json");
    ok(f.version === 1, "cursor: version 1");
    return Object.entries(f.hooks).flatMap(([ev, list]) => list.map((h) => ({ ev, matcher: h.matcher, h })));
  }
  const f = readJson(`plugins/${agent}/hooks/hooks.json`);
  ok(!("modules" in f) && !("modules" in f.hooks), `${agent}: no "modules" key`);
  return Object.entries(f.hooks).flatMap(([ev, groups]) =>
    groups.flatMap((g) => g.hooks.map((h) => ({ ev, matcher: g.matcher, h }))));
}
// Which state an entry sends, and the argv it would run
function call(agent, e) {
  if (agent === "claude") {
    if (e.h.command === "hn") return { kind: "hn", argv: e.h.args };
    if (e.h.command === "sh") return { kind: "cloud", argv: e.h.args };
    return { kind: "?" };
  }
  const argv = e.h.command.split(" ");
  return argv[0] === "hn" ? { kind: "hn", argv: argv.slice(1), line: e.h.command } : { kind: "?" };
}

const ALL = {};
for (const agent of Object.keys(CONTRACT)) {
  const es = entries(agent);
  ALL[agent] = es;
  const got = {};
  for (const e of es) {
    const c = call(agent, e);
    ok(c.kind !== "?", `${agent} ${e.ev}: known command`, JSON.stringify(e.h));
    if (c.kind !== "hn") continue;
    const state = c.argv[4];
    (got[e.ev] ??= []).push(state);
    ok(eq(c.argv, expectArgs(agent, state)), `${agent} ${e.ev}: hn args`, JSON.stringify(c.argv));
    const m = MATCHERS[`${agent}:${e.ev}`];
    if (m) ok(e.matcher === m, `${agent} ${e.ev}: matcher ${m}`, e.matcher);
    if (agent === "claude") {
      ok(e.h.async === true && e.h.type === "command" && !("shell" in e.h), `claude ${e.ev}: async exec-form command`);
    }
    if (agent === "codex") {
      ok(e.ev === "SessionEnd" ? !e.h.async && e.h.timeout <= 3 : e.h.async === true,
         `codex ${e.ev}: async (SessionEnd sync, timeout <= 3 s)`);
    }
  }
  ok(eq(got, CONTRACT[agent]), `${agent}: mapping equals app-events §5`, JSON.stringify(got));
}
// Claude: every event also has the cloud hook, same state, never offered to device hooks
for (const e of ALL.claude) {
  const c = call("claude", e);
  if (c.kind !== "cloud") continue;
  ok(c.argv[0] === "${CLAUDE_PLUGIN_ROOT}/cloud/hn-cloud.sh" && CONTRACT.claude[e.ev]?.[0] === c.argv[1] &&
     e.h.async === true && e.h.cloud === "skip", `claude ${e.ev}: cloud hook -> ${c.argv[1]}`);
}
ok(ALL.claude.filter((e) => call("claude", e).kind === "cloud").length === Object.keys(CONTRACT.claude).length,
   "claude: one cloud hook per event");

const plugin = readJson("plugins/claude/.claude-plugin/plugin.json");
ok(plugin.name === "humanneeded" && /^2\./.test(plugin.version), "claude plugin.json name/version 2.x");
const mkt = readJson(".claude-plugin/marketplace.json");
ok(mkt.plugins.length === 1 && mkt.plugins[0].source === "./plugins/claude", "marketplace lists one Claude plugin");
const codexPlugin = readJson("plugins/codex/.codex-plugin/plugin.json");
ok(codexPlugin.name === "humanneeded", "codex plugin.json");
const manifest = readJson("integrations/manifest.json");
ok(eq(Object.keys(manifest.agents).sort(), ["claude", "codex", "cursor"]), "integrations/manifest.json has 3 agents");

// ---------------------------------------------------------------------------------------------
console.log("2. hooks run the fake hn");
if (!existsSync(fakeExe)) {
  ok(false, "fake hn built", `missing ${fakeExe}; run cargo build --release --manifest-path tests/fake-hn/Cargo.toml`);
} else {
  const work = mkdtempSync(join(tmpdir(), "hn-test-"));
  const log = join(work, "calls.jsonl");
  const env = { ...process.env, PATH: fakeDir + delimiter + process.env.PATH, HN_FAKE_LOG: log,
                CLAUDE_PLUGIN_ROOT: join(root, "plugins", "claude") };
  delete env.CLAUDE_CODE_REMOTE;
  const payload = (agent, ev, i) => agent === "cursor"
    ? { conversation_id: `conv-${i}`, generation_id: "g1", hook_event_name: ev, cursor_version: "test" }
    : { session_id: `sess-${agent}-${i}`, hook_event_name: ev, cwd: work, transcript_path: null };
  let i = 0;
  for (const agent of Object.keys(CONTRACT)) {
    for (const e of ALL[agent]) {
      const c = call(agent, e);
      i++;
      const input = JSON.stringify(payload(agent, e.ev, i));
      let r;
      if (agent === "claude") {
        // Claude Code exec form: command resolved on PATH, no shell; ${CLAUDE_PLUGIN_ROOT} substituted.
        const argv = c.argv.map((a) => a.replaceAll("${CLAUDE_PLUGIN_ROOT}", env.CLAUDE_PLUGIN_ROOT));
        r = spawnSync(e.h.command, argv, { input, env, timeout: 10000 });
      } else {
        // Codex and Cursor run a shell string (PowerShell for Cursor on Windows).
        const sh = isWin && agent === "cursor" ? "powershell.exe" : true;
        r = spawnSync(c.line, { input, env, shell: sh, timeout: 10000 });
      }
      const what = `${agent} ${e.ev} ${c.kind}`;
      ok(r.status === 0, `${what}: exit 0`, String(r.error || r.stderr));
      ok((r.stdout?.length ?? 0) === 0, `${what}: prints nothing`, String(r.stdout));
      if (c.kind !== "hn") continue;
      const calls = existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [];
      const last = calls[calls.length - 1];
      ok(last && eq(last.args, c.argv) && JSON.parse(last.stdin).hook_event_name === e.ev &&
         (JSON.parse(last.stdin).session_id ?? JSON.parse(last.stdin).conversation_id) ===
           (payload(agent, e.ev, i).session_id ?? `conv-${i}`),
         `${what}: fake hn got args + stdin JSON`, JSON.stringify(last));
    }
  }
  const calls = readFileSync(log, "utf8").trim().split("\n");
  const hnHooks = Object.values(ALL).flat().filter((e) => (e.h.command === "hn" || e.h.command.startsWith("hn ")));
  ok(calls.length === hnHooks.length, `cloud hooks made no hn calls (${calls.length} calls / ${hnHooks.length} hn hooks)`);
  rmSync(work, { recursive: true, force: true });
}

// ---------------------------------------------------------------------------------------------
console.log("3. cloud hook (hn-relay/1 §4) against a local relay stand-in");
const script = join(root, "plugins", "claude", "cloud", "hn-cloud.sh");
const posts = [];
let replyCode = 202, reply429 = 0;
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    posts.push({ t: Date.now(), path: req.url, body: JSON.parse(body) });
    if (reply429 > 0) { reply429--; res.writeHead(429); return res.end(); }
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
  posts.length = 0; reply429 = 2;
  const r = await runCloud("needs", "s-429");
  ok(posts.length === 3 && posts.every((p) => p.body.s === "needs") && r.ms < 4000,
     `429 twice: retried twice, ${r.ms} ms`, String(posts.length));
  reply429 = 3; posts.length = 0;
  const r2 = await runCloud("end", "s-429b");
  ok(posts.length === 3 && r2.ms < 4000, `429 always: gives up after 2 retries, ${r2.ms} ms`);
  reply429 = 0;
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
  ok(r.code === 0 && r.ms < 4000 && posts[0]?.body.h === h("s-big"), `8 MB hook input: ${r.ms} ms`);
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
