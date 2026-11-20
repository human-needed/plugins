// Unit test for the in-memory token buckets: node relay/tests/bucket_test.mjs
import assert from 'node:assert/strict';

const { take, LIMITS } = await import('../src/limits.mjs');
const m = new Map(); let t = 1_000_000;
const n = (k, lim, count) => Array.from({ length: count }, () => take(m, k, lim, t)).filter(Boolean).length;
assert.equal(n('k', LIMITS.postPerK, 15), 10, 'burst 10 per K');
t += 1000; assert.equal(n('k', LIMITS.postPerK, 5), 2, '2/s refill');
assert.equal(n('k2', LIMITS.postPerK, 3), 3, 'keys independent');
assert.equal(n('ip', LIMITS.postPerIp, 80), 50, 'per-IP burst 50');
assert.equal(n('c', LIMITS.connectPerIp, 30), 20, 'connect burst 20');
t += 60_000; assert.equal(n('c', LIMITS.connectPerIp, 30), 10, '10 connects/min');
assert.equal(take(m, undefined, LIMITS.postPerK, t), true, 'no key -> no limit');
console.log('bucket_test: all pass');
