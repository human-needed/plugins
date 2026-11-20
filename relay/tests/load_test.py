"""hn-relay/1 load test: N simulated PCs, each holding a socket and POSTing its own self-check probe.

  python relay/tests/load_test.py --pcs 20 --minutes 5 --every 5

Runs from one machine, so it stays under the relay's per-IP limits (10 POSTs/s, 10 connects/min,
burst 20). Reports delivery rate and round-trip latency; the per-request cost figures come from
CloudWatch afterwards (see cost_model.py). Each PC unbinds itself at the end.
"""
import argparse, asyncio, json, secrets, statistics, time, urllib.request

import websockets

A = None


def post(k, h):
    body = json.dumps({"v": 1, "s": "idle", "h": h, "ts": int(time.time() * 1000), "hb": False}).encode()
    req = urllib.request.Request(f"{A.post}/v1/h/{k}", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


async def pc(n, stats, stop):
    k, i, s = secrets.token_hex(16), secrets.token_hex(16), secrets.token_hex(32)
    await asyncio.sleep(n * 0.2)
    async with websockets.connect(A.ws, open_timeout=15) as ws:
        await ws.send(json.dumps({"t": "hello", "k": k, "i": i, "s": s}))
        await asyncio.sleep(2)
        pending = {}

        async def reader():
            async for raw in ws:
                m = json.loads(raw)
                if m.get("t") == "state" and m.get("h") in pending:
                    stats["rtt"].append(time.time() - pending.pop(m["h"]))
                elif m.get("t") == "err":
                    stats["err"].append(m.get("e"))

        rd = asyncio.create_task(reader())
        last_ping = time.time()
        while time.time() < stop:
            h = secrets.token_hex(8)
            pending[h] = time.time()
            code = await asyncio.to_thread(post, k, h)
            stats["sent"] += 1
            stats["codes"][code] = stats["codes"].get(code, 0) + 1
            if time.time() - last_ping > 60:
                await ws.send('{"t":"ping"}')
                last_ping = time.time()
            await asyncio.sleep(A.every)
        await asyncio.sleep(5)
        stats["lost"] += len(pending)
        await ws.send(json.dumps({"t": "unbind", "i": i}))
        await asyncio.sleep(1)
        rd.cancel()


async def main():
    stats = {"sent": 0, "lost": 0, "rtt": [], "err": [], "codes": {}}
    stop = time.time() + A.minutes * 60
    t0 = time.time()
    res = await asyncio.gather(*(pc(n, stats, stop) for n in range(A.pcs)), return_exceptions=True)
    fails = [r for r in res if isinstance(r, Exception)]
    rtt = sorted(stats["rtt"])
    print(json.dumps({
        "pcs": A.pcs, "seconds": round(time.time() - t0), "posts": stats["sent"], "codes": stats["codes"],
        "delivered": len(rtt), "lost": stats["lost"], "relay_errors": stats["err"], "pc_failures": [str(f) for f in fails],
        "rtt_ms_p50": round(statistics.median(rtt) * 1000) if rtt else None,
        "rtt_ms_p95": round(rtt[int(len(rtt) * 0.95)] * 1000) if rtt else None,
        "start_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)),
    }, indent=1))
    return 0 if not fails and stats["lost"] == 0 and not stats["err"] else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--post", default="https://relay.human-needed.com")
    p.add_argument("--ws", default="wss://relay-ws.human-needed.com/v1")
    p.add_argument("--pcs", type=int, default=20)
    p.add_argument("--minutes", type=float, default=5)
    p.add_argument("--every", type=float, default=5, help="seconds between each PC's POSTs")
    A = p.parse_args()
    raise SystemExit(asyncio.run(main()))
