// Relay limits and in-memory token buckets (no AWS deps, unit-tested by tests/bucket_test.mjs).
export const LIMITS = {
  maxBody: 512,
  maxWsBody: 1024,
  postPerK: { rate: 2, burst: 10 },      // contract §4: 2/s, burst 10
  postPerIp: { rate: 10, burst: 50 },    // cloud VMs may share egress IPs: keep generous
  connectPerIp: { rate: 1 / 6, burst: 20 }, // 10 WebSocket connects/min per IP, burst 20
  maxInstalls: 3,
  bindingTtlS: 30 * 86400,
  connTtlS: 3 * 3600,
  helloWithinMs: 5000,
  maxConnsPerKey: 10,
};

// ---------- in-memory token buckets ----------
export function take(map, key, { rate, burst }, t = Date.now()) {
  if (!key) return true;
  if (map.size > 20000) map.clear(); // bound memory under a flood of distinct keys
  const b = map.get(key) || { tok: burst, t };
  b.tok = Math.min(burst, b.tok + ((t - b.t) / 1000) * rate);
  b.t = t;
  const ok = b.tok >= 1;
  if (ok) b.tok -= 1;
  map.set(key, b);
  return ok;
}
