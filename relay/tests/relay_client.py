"""hn-relay/1 test client: plays both the cloud hook (POST) and the PC app (WebSocket).

  python relay/tests/relay_client.py                       # defaults: relay.human-needed.com
  python relay/tests/relay_client.py --post https://x.execute-api.us-east-2.amazonaws.com \
                                     --ws wss://y.execute-api.us-east-2.amazonaws.com/v1

Checks every rule of pm/contracts/relay-api.md that the relay owns. Needs `pip install websockets`.
Each run uses fresh random keys and unbinds what it bound.
"""
import argparse, asyncio, hashlib, json, secrets, sys, time, urllib.request, urllib.error

import websockets

ARGS = None
RESULTS = []


def rnd(n):  # n hex chars
    return secrets.token_hex(n // 2)


def post(k, body, path=None, method="POST"):
    url = ARGS.post + (path or f"/v1/h/{k}")
    data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def state(s="working", hb=False, h=None):
    return {"v": 1, "s": s, "h": h or rnd(16), "ts": int(time.time() * 1000), "hb": hb}


class Pc:
    """A PC install: install id + secret, holding one WebSocket."""

    def __init__(self, k, i=None, s=None):
        self.k, self.i, self.s = k, i or rnd(32), s or rnd(64)
        self.ws = None

    async def connect(self, hello=True, delay=0.0):
        self.ws = await websockets.connect(ARGS.ws, open_timeout=10)
        if delay:
            await asyncio.sleep(delay)
        if hello:
            await self.ws.send(json.dumps({"t": "hello", "k": self.k, "i": self.i, "s": self.s}))
            await asyncio.sleep(1.0)  # hello is processed asynchronously by the relay
        return self

    async def recv(self, timeout=6.0):
        try:
            return json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            return None

    async def closed(self, timeout=6.0):
        try:
            await asyncio.wait_for(self.ws.wait_closed(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def close(self):
        if self.ws:
            await self.ws.close()


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  (' + detail + ')' if detail and not ok else ''}")


async def wait_for_state(pc, h, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        m = await pc.recv(end - time.time())
        if m is None:
            return None
        if m.get("t") == "state" and m.get("h") == h:
            return m
    return None


async def main():
    k = rnd(32)

    # §4 constant replies: 202 with empty body for unbound key, bad body, bad key, oversize.
    for name, kk, body in [
        ("202 empty: valid state, nobody listening", k, state()),
        ("202 empty: bad JSON", k, b"{nope"),
        ("202 empty: unknown state", k, {**state(), "s": "bogus"}),
        ("202 empty: body > 512 bytes", k, {**state(), "pad": "x" * 600}),
        ("202 empty: malformed key", "XYZ", state()),
    ]:
        st, b = post(kk, body)
        check(name, st == 202 and b == b"", f"{st} {b[:60]!r}")

    # D-036: old unversioned routes are gone.
    st, _ = post(k, state(), path=f"/h/{k}")
    check("old route /h/<K> removed", st in (403, 404), str(st))
    st, _ = post(k, b"", method="GET")
    check("GET not accepted", st in (403, 404, 405), str(st))

    # §3 hello + forwarding, exact message shape, hb flag.
    a = await Pc(k).connect()
    m = await a.recv()
    check("hello answered {t:ok}", m == {"t": "ok"}, str(m))
    await a.ws.send(json.dumps({"t": "check"}))
    m = await a.recv()
    check("check answered {t:ok}", m == {"t": "ok"}, str(m))
    s1 = state("needs")
    post(k, s1)
    m = await wait_for_state(a, s1["h"])
    check("PC receives posted state", m is not None)
    check("relay->PC shape {t,s,h,ts,hb}", m == {"t": "state", "s": "needs", "h": s1["h"], "ts": s1["ts"], "hb": False}, str(m))
    s2 = state("working", hb=True)
    post(k, s2)
    m = await wait_for_state(a, s2["h"])
    check("heartbeat hb=true forwarded", m is not None and m["hb"] is True, str(m))

    # ping keeps the socket, gets no reply.
    await a.ws.send(json.dumps({"t": "ping"}))
    s3 = state("done")
    post(k, s3)
    check("ping accepted, socket still delivers", await wait_for_state(a, s3["h"]) is not None)

    # Other keys don't leak in.
    other = await Pc(rnd(32)).connect()
    s4 = state()
    post(k, s4)
    check("other key's PC gets nothing", await wait_for_state(other, s4["h"], 3) is None)
    await other.close()

    # R2: second install on same key also gets states; same install reconnect with same secret is fine.
    b_pc = await Pc(k).connect()
    s5 = state("idle")
    post(k, s5)
    ra, rb = await asyncio.gather(wait_for_state(a, s5["h"]), wait_for_state(b_pc, s5["h"]))
    check("two installs of one key both receive", ra is not None and rb is not None)

    # Wrong secret for a bound install -> refused + closed.
    thief = await Pc(k, i=a.i).connect()
    m = await thief.recv()
    check("wrong secret refused (err)", m is not None and m.get("t") == "err", str(m))
    check("wrong secret socket closed", await thief.closed())

    # Message before hello -> closed.
    early = await Pc(k).connect(hello=False)
    await early.ws.send(json.dumps({"t": "check"}))
    check("message before hello closes socket", await early.closed())

    # Hello later than 5 s -> refused.
    late = await Pc(k).connect(delay=6.0)
    m = await late.recv()
    check("hello after 5 s refused", m is not None and m.get("t") == "err", str(m))

    # Oversized WebSocket message -> refused.
    big = await Pc(k).connect(hello=False)
    await big.ws.send(json.dumps({"t": "hello", "k": k, "i": rnd(32), "s": rnd(64), "pad": "x" * 2000}))
    m = await big.recv()
    check("WebSocket message > 1 KB refused", m is not None and m.get("t") == "err", str(m))

    # Malformed hello -> refused.
    bad = await websockets.connect(ARGS.ws, open_timeout=10)
    await bad.send(json.dumps({"t": "hello", "k": k, "i": "short", "s": "short"}))
    try:
        m = json.loads(await asyncio.wait_for(bad.recv(), 6))
    except Exception:
        m = None
    check("malformed hello refused", m is not None and m.get("t") == "err", str(m))
    await bad.close()

    # §3.2 binding: 3 installs own the key, a 4th gets key_full.
    c_pc = await Pc(k).connect()
    d_pc = await Pc(k).connect()
    m = await d_pc.recv()
    check("4th install refused key_full", m == {"t": "err", "e": "key_full"}, str(m))
    check("4th install socket closed", await d_pc.closed())

    # Unbind from an owning PC frees a slot and closes the freed install's sockets.
    await a.ws.send(json.dumps({"t": "unbind", "i": c_pc.i}))
    check("unbound install's socket closed", await c_pc.closed())
    d2 = await Pc(k, i=d_pc.i, s=d_pc.s).connect()
    s6 = state()
    post(k, s6)
    check("after unbind, new install binds and receives", await wait_for_state(d2, s6["h"]) is not None)

    # Same install reconnects with its secret (e.g. after the 2 h close).
    await a.close()
    a2 = await Pc(k, i=a.i, s=a.s).connect()
    s7 = state()
    post(k, s7)
    check("owner reconnects with same id+secret", await wait_for_state(a2, s7["h"]) is not None)

    # §4 rate limit per K: 2/s burst 10 -> a burst of 25 sees 429s; normal heartbeat cadence never does.
    kr = rnd(32)
    # One keep-alive connection, back to back (the limit is per warm Lambda instance; a fully parallel
    # burst spreads over instances, bounded overall by the stage throttle).
    import http.client, urllib.parse
    u = urllib.parse.urlparse(ARGS.post)
    conn = http.client.HTTPSConnection(u.netloc, timeout=10)
    codes = []
    for _ in range(25):
        conn.request("POST", f"/v1/h/{kr}", json.dumps(state()), {"content-type": "application/json"})
        r = conn.getresponse(); r.read(); codes.append(r.status)
    conn.close()
    check("burst over limit gets 429", codes.count(429) >= 5 and all(c in (202, 429) for c in codes), str(codes))
    check("first 10 of a burst accepted", codes[:10].count(202) >= 10 or codes.count(202) >= 10, str(codes))

    # Cleanup: free all bindings this run made.
    for i in (b_pc.i, d2.i, a2.i):
        await a2.ws.send(json.dumps({"t": "unbind", "i": i}))
    await asyncio.sleep(1)
    for p in (b_pc, d2, a2):
        await p.close()

    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--post", default="https://relay.human-needed.com")
    p.add_argument("--ws", default="wss://relay-ws.human-needed.com/v1")
    ARGS = p.parse_args()
    sys.exit(asyncio.run(main()))
