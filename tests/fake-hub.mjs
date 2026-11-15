// Stand-in for the HumanNeeded app's local HTTP hub (D-047), for tests and manual checks.
//   node tests/fake-hub.mjs [port] [logfile]     (default 24816, stdout)
// Records each request as one JSON line {ts, method, path, headers, bytes, body(first 4 KB)}.
// Replies 204 with no body. Env HUB_DELAY_MS delays replies (slow-app test).
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

export function startHub({ port = 24816, log, delayMs = 0, onRequest } = {}) {
  const server = createServer((req, res) => {
    const chunks = [];
    let bytes = 0;
    req.on("data", (d) => { bytes += d.length; if (bytes <= 1 << 20) chunks.push(d); });
    req.on("end", () => {
      const rec = { ts: Date.now(), method: req.method, path: req.url, headers: req.headers, bytes,
                    body: Buffer.concat(chunks).toString("utf8").slice(0, 4096) };
      onRequest?.(rec);
      if (log) appendFileSync(log, JSON.stringify(rec) + "\n");
      setTimeout(() => { res.writeHead(204); res.end(); }, delayMs);
    });
  });
  return new Promise((r) => server.listen(port, "127.0.0.1", () => r(server)));
}

if (process.argv[1]?.endsWith("fake-hub.mjs")) {
  const port = Number(process.argv[2] || 24816);
  const log = process.argv[3];
  await startHub({ port, log, delayMs: Number(process.env.HUB_DELAY_MS || 0),
                   onRequest: log ? undefined : (r) => console.log(JSON.stringify(r)) });
  console.error(`fake hub on 127.0.0.1:${port}`);
}
