// Which c#K connection rows a POST (and a link check) delivers to. No AWS deps; unit-tested.
// DynamoDB sweeps expired rows up to ~48 h late, and a failed $disconnect leaves rows behind, so the
// raw rows can hold many dead ids. Rows are written at hello with ttl = hello time + connTtlS, so a
// higher ttl is a newer connection: deliver to the newest live ones, never to expired ones.
export function pickConns(items, nowMs, cap) {
  const live = [], expired = [];
  for (const it of items || []) {
    const ttl = Number(it.ttl?.N);
    (Number.isFinite(ttl) && ttl * 1000 > nowMs ? live : expired).push(it);
  }
  live.sort((a, b) => Number(b.ttl.N) - Number(a.ttl.N));
  return { live: live.slice(0, cap), expired, extra: live.slice(cap) };
}
