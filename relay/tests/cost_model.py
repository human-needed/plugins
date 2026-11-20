"""Relay cost per 1,000 active users per month (us-east-2 list prices, Nov 2026).

  python relay/tests/cost_model.py [--post-ms 12] [--ws-ms 25]

"Active user" = a PC with the cloud link on, connected 24/7, plus 1 h/day of cloud Claude work.
Lambda durations: pass the averages measured by the load test (CloudWatch AWS/Lambda Duration).
"""
import argparse

P = {  # USD
    "http_req": 1.00e-6, "ws_msg": 1.00e-6, "ws_min": 0.25e-6,
    "lambda_req": 0.20e-6, "lambda_gbs": 0.0000133334, "mem_gb": 0.25,
    "rru": 0.125e-6, "wru": 0.625e-6,
}
MONTH_MIN = 30 * 24 * 60


def per_user_check(ping_min, check_min, cloud_posts, post_ms, ws_ms):
    """No self-check POST: the PC sends {"t":"check"} (Lambda + 1 read + reply) every check_min."""
    reconnects = MONTH_MIN / 120
    c = per_user(ping_min, 10 ** 12, cloud_posts, post_ms, ws_ms)
    checks = MONTH_MIN / check_min
    lam = checks * (P["lambda_req"] + ws_ms / 1000 * P["mem_gb"] * P["lambda_gbs"])
    c["ws messages (check + ok, hello ok)"] = (2 * checks + reconnects) * P["ws_msg"]
    c["lambda (check)"] = lam
    c["dynamodb (check: 1 read)"] = checks * 0.5 * P["rru"]
    return c


def per_user(ping_min, probe_min, cloud_posts, post_ms, ws_ms, online=1.0):
    """probe_min=None: one self-check per connect. online: share of the month the socket is open."""
    mins = MONTH_MIN * online
    pings = mins / ping_min
    reconnects = mins / 120               # API Gateway closes sockets at 2 h
    probes = reconnects if probe_min is None else mins / probe_min
    posts = probes + cloud_posts
    lam = lambda n, ms: n * (P["lambda_req"] + ms / 1000 * P["mem_gb"] * P["lambda_gbs"])
    c = {
        "ws connection minutes": mins * P["ws_min"],
        "ws messages (pings, MOCK)": pings * P["ws_msg"],
        "ws messages (states out + hello)": (posts + reconnects) * P["ws_msg"],
        "http requests (POST)": posts * P["http_req"],
        "lambda (POST)": lam(posts, post_ms),
        "lambda (connect+hello+disconnect)": lam(reconnects * 3, ws_ms),
        "dynamodb (POST: 1 query)": posts * 0.5 * P["rru"],
        "dynamodb (hello+disconnect)": reconnects * (1.5 * P["rru"] + 5 * P["wru"]),
    }
    return c


def show(name, c):
    tot = sum(c.values())
    print(f"\n{name}: ${tot * 1000:.2f} per 1,000 users/month")
    for k, v in sorted(c.items(), key=lambda kv: -kv[1]):
        print(f"  {k:36s} ${v * 1000:7.2f}")


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--post-ms", type=float, default=15)
    a.add_argument("--ws-ms", type=float, default=30)
    a.add_argument("--cloud-posts", type=float, default=3000, help="per user/month (1 h/day, 45 s heartbeat + state changes)")
    o = a.parse_args()
    show("Contract today (ping 4 min, self-check 3 min)", per_user(4, 3, o.cloud_posts, o.post_ms, o.ws_ms))
    show("Chosen 11-20: ping 9 min, no self-check POST, check/ok every 30 min",
         per_user_check(9, 30, o.cloud_posts, o.post_ms, o.ws_ms))
    show("Proposed (ping 9 min, self-check 30 min)", per_user(9, 30, o.cloud_posts, o.post_ms, o.ws_ms))
    show("Proposed + socket only while the Claude desktop app runs (8 h/day), self-check once per connect",
         per_user(9, None, o.cloud_posts, o.post_ms, o.ws_ms, online=8 / 24))
    print("\nFixed: probe + alarms + budget + S3 ~ $0.05/month (within free amounts). Logs: errors only.")
