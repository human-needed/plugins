// HumanNeeded relay hn-relay/1 (pm/contracts/relay-api.md).
// One function serves both APIs:
//   HTTP API       POST /v1/h/{K}   cloud hook -> always 202 empty (429 when over the per-K rate)
//   WebSocket API  $connect / $default / $disconnect   PC app: hello, unbind, ping
// Table items (pk, sk):
//   b#K, i#<install>   binding: h=sha256(S) hex, last=ms, ttl=s (30 d after last connect)
//   c#K, <connId>      live connection of an authenticated install: i, ttl (3 h)
//   x#<connId>, -      reverse map for $disconnect / unbind: k, i, ttl (3 h)
// Rate limits are token buckets in each warm Lambda instance's memory (free, no table writes):
// exact while one instance serves the traffic, up to N x looser across N instances. The API stages'
// global throttles bound the total.
// Nothing else is stored; logs never contain K, install ids, IPs or bodies.
import { createHash, timingSafeEqual } from 'node:crypto';
import {
  DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand, QueryCommand, 
} from '@aws-sdk/client-dynamodb';
import {
  ApiGatewayManagementApiClient, PostToConnectionCommand, DeleteConnectionCommand,
} from '@aws-sdk/client-apigatewaymanagementapi';
import { LIMITS, take } from './limits.mjs';

const db = new DynamoDBClient({});
const T = process.env.TABLE;
const WS_ENDPOINT = process.env.WS_ENDPOINT; // https://<api>.execute-api.<region>.amazonaws.com/<stage>
const ws = new ApiGatewayManagementApiClient({ endpoint: WS_ENDPOINT });

const STATES = new Set(['working', 'needs', 'done', 'idle', 'end']); // app-events §2
const HEX = (n) => new RegExp(`^[0-9a-f]{${n}}$`);
const K_RE = HEX(32), I_RE = HEX(32), S_RE = HEX(64), H_RE = HEX(16);

const now = () => Date.now();
const sec = (ms) => Math.floor(ms / 1000);
const S = (v) => ({ S: String(v) });
const N = (v) => ({ N: String(v) });
const sha256hex = (s) => createHash('sha256').update(s).digest('hex');

const buckets = { k: new Map(), ip: new Map(), conn: new Map() };

export const handler = async (event) => {
  const rc = event.requestContext || {};
  try {
    if (rc.connectionId) return await onWs(event, rc);
    return await onPost(event, rc);
  } catch (e) {
    console.error('relay error', e?.name || 'Error', rc.routeKey || rc.http?.method || '');
    return rc.connectionId ? { statusCode: 200 } : accepted();
  }
};

// ---------- cloud side: POST /v1/h/{K} ----------

const accepted = () => ({ statusCode: 202, headers: { 'content-length': '0' }, body: '' });

export function parseState(raw) {
  if (typeof raw !== 'string' || raw.length < 2 || Buffer.byteLength(raw) > LIMITS.maxBody) return null;
  let b;
  try { b = JSON.parse(raw); } catch { return null; }
  if (!b || typeof b !== 'object' || b.v !== 1) return null;
  if (!STATES.has(b.s) || typeof b.h !== 'string' || !H_RE.test(b.h)) return null;
  if (!Number.isSafeInteger(b.ts) || b.ts <= 0) return null;
  if (typeof b.hb !== 'boolean') return null;
  return { t: 'state', s: b.s, h: b.h, ts: b.ts, hb: b.hb };
}

async function onPost(event, rc) {
  const k = (event.pathParameters || {}).k || '';
  const tooMany = { statusCode: 429, headers: { 'content-length': '0' }, body: '' };
  if (!take(buckets.ip, rc.http?.sourceIp, LIMITS.postPerIp)) return tooMany;
  if (!K_RE.test(k)) return accepted();
  if (!take(buckets.k, k, LIMITS.postPerK)) return tooMany;
  let body = event.body || '';
  if (event.isBase64Encoded) body = Buffer.from(body, 'base64').toString('utf8');
  const msg = parseState(body);
  if (!msg) return accepted();
  const conns = await db.send(new QueryCommand({
    TableName: T, KeyConditionExpression: 'pk = :p', ExpressionAttributeValues: { ':p': S(`c#${k}`) },
    Limit: LIMITS.maxConnsPerKey,
  }));
  const data = Buffer.from(JSON.stringify(msg));
  await Promise.all((conns.Items || []).map((it) => send(it.sk.S, data, k)));
  return accepted();
}

async function send(connId, data, k) {
  try {
    await ws.send(new PostToConnectionCommand({ ConnectionId: connId, Data: data }));
  } catch (e) {
    if (e.name === 'GoneException' || e.$metadata?.httpStatusCode === 410) {
      await dropConn(connId, k).catch(() => {});
    }
  }
}

async function dropConn(connId, k) {
  await Promise.all([
    db.send(new DeleteItemCommand({ TableName: T, Key: { pk: S(`c#${k}`), sk: S(connId) } })),
    db.send(new DeleteItemCommand({ TableName: T, Key: { pk: S(`x#${connId}`), sk: S('-') } })),
  ]);
}

// ---------- PC side: WebSocket ----------

async function onWs(event, rc) {
  const id = rc.connectionId;
  if (rc.routeKey === '$connect') {
    return { statusCode: take(buckets.conn, rc.identity?.sourceIp, LIMITS.connectPerIp) ? 200 : 429 };
  }
  if (rc.routeKey === '$disconnect') {
    const x = await getX(id);
    if (x) await dropConn(id, x.k);
    return { statusCode: 200 };
  }
  if ((event.body || '').length > LIMITS.maxWsBody) return refuse(id, 'bad_hello');
  let m = null;
  try { m = JSON.parse(event.body || ''); } catch { /* not JSON */ }
  const t = m && typeof m === 'object' ? m.t : undefined;
  const x = await getX(id);
  if (t === 'hello') {
    if (x) return { statusCode: 200 }; // already authenticated: ignore repeats
    return await hello(id, rc, m);
  }
  if (!x) return await refuse(id, 'bad_hello'); // anything before hello closes the socket
  if (t === 'ping') return { statusCode: 200 };
  if (t === 'unbind') return await unbind(x, m);
  return { statusCode: 200 }; // unknown message from an authenticated PC: ignore
}

async function getX(id) {
  const r = await db.send(new GetItemCommand({ TableName: T, Key: { pk: S(`x#${id}`), sk: S('-') } }));
  return r.Item ? { k: r.Item.k.S, i: r.Item.i.S } : null;
}

async function refuse(id, e) {
  await postJson(id, { t: 'err', e });
  await ws.send(new DeleteConnectionCommand({ ConnectionId: id })).catch(() => {});
  return { statusCode: 200 };
}

async function postJson(id, o) {
  await ws.send(new PostToConnectionCommand({ ConnectionId: id, Data: Buffer.from(JSON.stringify(o)) })).catch(() => {});
}

function sameHash(a, b) {
  const x = Buffer.from(a, 'hex'), y = Buffer.from(b, 'hex');
  return x.length === y.length && timingSafeEqual(x, y);
}

async function hello(id, rc, m) {
  const t = now();
  if (rc.connectedAt && t - rc.connectedAt > LIMITS.helloWithinMs) return refuse(id, 'bad_hello');
  const { k, i, s } = m;
  if (![k, i, s].every((v) => typeof v === 'string') || !K_RE.test(k) || !I_RE.test(i) || !S_RE.test(s)) {
    return refuse(id, 'bad_hello');
  }
  const h = sha256hex(Buffer.from(s, 'hex'));
  const r = await db.send(new QueryCommand({
    TableName: T, KeyConditionExpression: 'pk = :p', ExpressionAttributeValues: { ':p': S(`b#${k}`) },
  }));
  const live = [];
  for (const it of r.Items || []) {
    if (Number(it.ttl.N) * 1000 < t) { // expired but not yet swept by DynamoDB TTL
      await db.send(new DeleteItemCommand({ TableName: T, Key: { pk: it.pk, sk: it.sk } })).catch(() => {});
    } else live.push(it);
  }
  const mine = live.find((it) => it.sk.S === `i#${i}`);
  if (mine && !sameHash(mine.h.S, h)) return refuse(id, 'bad_secret');
  if (!mine && live.length >= LIMITS.maxInstalls) return refuse(id, 'key_full');
  await db.send(new PutItemCommand({
    TableName: T,
    Item: { pk: S(`b#${k}`), sk: S(`i#${i}`), h: S(h), last: N(t), ttl: N(sec(t) + LIMITS.bindingTtlS) },
  }));
  const ttl = N(sec(t) + LIMITS.connTtlS);
  await Promise.all([
    db.send(new PutItemCommand({ TableName: T, Item: { pk: S(`c#${k}`), sk: S(id), i: S(i), ttl } })),
    db.send(new PutItemCommand({ TableName: T, Item: { pk: S(`x#${id}`), sk: S('-'), k: S(k), i: S(i), ttl } })),
  ]);
  return { statusCode: 200 };
}

async function unbind(x, m) {
  const target = m.i;
  if (typeof target !== 'string' || !I_RE.test(target)) return { statusCode: 200 };
  await db.send(new DeleteItemCommand({ TableName: T, Key: { pk: S(`b#${x.k}`), sk: S(`i#${target}`) } }));
  // Close the freed install's live connections (it must hello again, and may then be refused).
  const r = await db.send(new QueryCommand({
    TableName: T, KeyConditionExpression: 'pk = :p', ExpressionAttributeValues: { ':p': S(`c#${x.k}`) },
  }));
  await Promise.all((r.Items || []).filter((it) => it.i.S === target).map(async (it) => {
    await ws.send(new DeleteConnectionCommand({ ConnectionId: it.sk.S })).catch(() => {});
    await dropConn(it.sk.S, x.k).catch(() => {});
  }));
  return { statusCode: 200 };
}
