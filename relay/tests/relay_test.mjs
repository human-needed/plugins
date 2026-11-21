// Handler tests against an in-memory table and socket set: cd relay && npm install && npm test
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

process.env.AWS_REGION ||= 'us-east-2';
const { handler, setClientsForTest } = await import('../src/relay.mjs');
const { pickConns } = await import('../src/conns.mjs');
const { LIMITS } = await import('../src/limits.mjs');

// ---------- fakes ----------
const rows = new Map(); // "pk|sk" -> item
const key = (pk, sk) => `${pk}|${sk}`;
const db = {
  async send(c) {
    const n = c.constructor.name, x = c.input;
    if (n === 'PutItemCommand') { rows.set(key(x.Item.pk.S, x.Item.sk.S), x.Item); return {}; }
    if (n === 'GetItemCommand') return { Item: rows.get(key(x.Key.pk.S, x.Key.sk.S)) };
    if (n === 'DeleteItemCommand') { rows.delete(key(x.Key.pk.S, x.Key.sk.S)); return {}; }
    if (n === 'QueryCommand') {
      if (x.Limit) throw new Error('Limit must not be used: it cuts off live rows');
      const pk = x.ExpressionAttributeValues[':p'].S;
      const all = [...rows.values()].filter((it) => it.pk.S === pk).sort((a, b) => (a.sk.S < b.sk.S ? -1 : 1));
      const from = x.ExclusiveStartKey ? all.findIndex((it) => it.sk.S === x.ExclusiveStartKey.sk.S) + 1 : 0;
      const page = all.slice(from, from + 3); // tiny pages: paging must be followed
      return { Items: page, LastEvaluatedKey: from + 3 < all.length ? { pk: page.at(-1).pk, sk: page.at(-1).sk } : undefined };
    }
    throw new Error(`unexpected ${n}`);
  },
};
const sockets = new Map(); // connId -> received messages; absent = gone
const ws = {
  async send(c) {
    const n = c.constructor.name, id = c.input.ConnectionId;
    if (!sockets.has(id)) throw Object.assign(new Error('gone'), { name: 'GoneException' });
    if (n === 'PostToConnectionCommand') sockets.get(id).push(JSON.parse(Buffer.from(c.input.Data).toString()));
    if (n === 'DeleteConnectionCommand') sockets.delete(id);
    return {};
  },
};
setClientsForTest(db, ws);

const hex = (s, n) => createHash('sha256').update(s).digest('hex').slice(0, n);
const K = hex('k', 32), I = hex('i', 32), SEC = hex('s', 64);
const wsEv = (id, body, routeKey = '$default') => ({ requestContext: { connectionId: id, routeKey, connectedAt: Date.now() }, body });
const connect = async (id, k = K, i = I) => {
  sockets.set(id, []);
  await handler(wsEv(id, '', '$connect'));
  await handler(wsEv(id, JSON.stringify({ t: 'hello', k, i, s: SEC })));
};
const post = (h, k = K) => handler({
  requestContext: { http: { method: 'POST', sourceIp: '1.2.3.4' } }, pathParameters: { k },
  body: JSON.stringify({ v: 1, s: 'needs', h, ts: Date.now(), hb: false }),
});
const states = (id) => sockets.get(id).filter((m) => m.t === 'state').map((m) => m.h);
const oks = (id) => sockets.get(id).filter((m) => m.t === 'ok').length;
const cRows = () => [...rows.values()].filter((it) => it.pk.S === `c#${K}`);
const nowS = () => Math.floor(Date.now() / 1000);

// ---------- pickConns ----------
{
  const it = (sk, ttl) => ({ sk: { S: sk }, ttl: { N: String(ttl) } });
  const t = 1_000_000;
  const r = pickConns([it('a', 999_999), it('b', 1_000_010), it('c', 1_000_020), it('d', 1_000_005)], t * 1000, 2);
  assert.deepEqual(r.live.map((x) => x.sk.S), ['c', 'b'], 'newest live first, capped');
  assert.deepEqual(r.expired.map((x) => x.sk.S), ['a'], 'expired split out');
  assert.deepEqual(r.extra.map((x) => x.sk.S), ['d']);
}

// ---------- the live bug: dead rows ahead of the live connection ----------
// 12 rows that sort before the live one: 8 expired-but-unswept, 4 left by a failed $disconnect.
for (let n = 0; n < 12; n++) {
  const id = `A${String(n).padStart(2, '0')}`; // 'A..' < 'Z..'
  const ttl = n < 8 ? nowS() - 3600 : nowS() + 600; // stale ones are older than any new hello
  rows.set(key(`c#${K}`, id), { pk: { S: `c#${K}` }, sk: { S: id }, i: { S: I }, ttl: { N: String(ttl) } });
  rows.set(key(`x#${id}`, '-'), { pk: { S: `x#${id}` }, sk: { S: '-' }, k: { S: K }, i: { S: I }, ttl: { N: String(ttl) } });
}
await connect('Zlive');
assert.equal(oks('Zlive'), 1, 'hello answered ok through the POST path');
assert.deepEqual(cRows().map((r) => r.sk.S), ['Zlive'], 'hello pruned expired and gone rows');

// Put the dead rows back (as if hello had not pruned) and check POST still reaches the live socket.
for (let n = 0; n < 12; n++) {
  const id = `A${String(n).padStart(2, '0')}`;
  const ttl = n < 8 ? nowS() - 3600 : nowS() + 600;
  rows.set(key(`c#${K}`, id), { pk: { S: `c#${K}` }, sk: { S: id }, i: { S: I }, ttl: { N: String(ttl) } });
}
await post('00000000000000aa');
assert.deepEqual(states('Zlive'), ['00000000000000aa'], 'POST reaches the live socket past dead rows');
assert.ok(cRows().length < 13, 'POST pruned dead rows');
await post('00000000000000bb');
assert.deepEqual(cRows().map((r) => r.sk.S), ['Zlive'], 'all dead rows gone after a second POST');

// ---------- check proves delivery ----------
sockets.get('Zlive').length = 0;
await handler(wsEv('Zlive', '{"t":"check"}'));
assert.equal(oks('Zlive'), 1, 'check -> ok when a POST would arrive');
rows.delete(key(`c#${K}`, 'Zlive')); // delivery row lost: POSTs would not arrive
await handler(wsEv('Zlive', '{"t":"check"}'));
assert.equal(oks('Zlive'), 1, 'check -> no ok when a POST would not arrive (PC reconnects)');
await post('00000000000000cc');
assert.deepEqual(states('Zlive'), [], 'and indeed the POST did not arrive');

// Reconnect fixes it.
await connect('Znew');
await post('00000000000000dd');
assert.deepEqual(states('Znew'), ['00000000000000dd']);

// ---------- cap: at most maxConnsPerKey sockets, newest first ----------
for (let n = 0; n < LIMITS.maxConnsPerKey + 2; n++) await connect(`M${n}`);
await post('00000000000000ee');
const got = [...sockets.keys()].filter((id) => states(id).includes('00000000000000ee'));
assert.equal(got.length, LIMITS.maxConnsPerKey, 'POST fan-out capped');
assert.ok(got.includes(`M${LIMITS.maxConnsPerKey + 1}`), 'newest connection always included');

// ---------- check before hello still refused ----------
sockets.set('Q', []);
await handler(wsEv('Q', '{"t":"check"}'));
assert.equal(sockets.has('Q'), false, 'check before hello closes');

console.log('relay_test: all pass');
