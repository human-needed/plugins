// Synthetic probe (pm/contracts/testing.md §2): every 15 min, play the PC and the cloud hook on a
// test key through the public hostnames: WebSocket hello -> POST a state -> expect it back.
// Throws on failure, so the stack's alarm on this function's Errors (or missing runs) emails the user.
import { createHash, randomBytes } from 'node:crypto';

const { PROBE_WS_URL, PROBE_POST_URL, PROBE_SECRET, PROBE_SEED } = process.env;
const hex = (s) => createHash('sha256').update(s).digest('hex');
const K = hex(`humanneeded-probe:${PROBE_SEED}`).slice(0, 32);
const I = hex(`humanneeded-probe-install:${PROBE_SEED}`).slice(0, 32);

export const handler = async () => {
  const h = randomBytes(8).toString('hex');
  const t0 = Date.now();
  const sock = new WebSocket(PROBE_WS_URL);
  try {
    await new Promise((ok, fail) => {
      sock.onopen = ok;
      sock.onerror = () => fail(new Error('ws connect failed'));
      setTimeout(() => fail(new Error('ws connect timeout')), 5000);
    });
    const got = new Promise((ok, fail) => {
      sock.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        if (m.t === 'err') fail(new Error(`relay refused probe: ${m.e}`));
        if (m.t === 'state' && m.h === h) ok(m);
      };
      sock.onclose = () => fail(new Error('ws closed'));
      setTimeout(() => fail(new Error('no state within 10 s')), 10000);
    });
    sock.send(JSON.stringify({ t: 'hello', k: K, i: I, s: PROBE_SECRET }));
    await new Promise((r) => setTimeout(r, 1500)); // let the hello land before posting
    const res = await fetch(`${PROBE_POST_URL}/v1/h/${K}`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 1, s: 'idle', h, ts: Date.now(), hb: false }),
      signal: AbortSignal.timeout(5000),
    });
    if (res.status !== 202) throw new Error(`POST returned ${res.status}`);
    const m = await got;
    if (m.s !== 'idle' || m.hb !== false) throw new Error('state came back altered');
    console.log(JSON.stringify({ probe: 'ok', ms: Date.now() - t0 }));
  } finally {
    try { sock.close(); } catch { /* already closed */ }
  }
};
