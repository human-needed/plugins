#!/usr/bin/env python3
# HumanNeeded puck connector for macOS (MCP over stdio), the counterpart of hn-mcp.ps1.
# Standard library only. hn-mcp.sh starts it when python3 is usable.
#
#  - Tool set_state: shows a state on the puck through hn.sh (and links a cloud session id).
#  - Cloud relay listener (test): holds a WebSocket to the HumanNeeded relay, claims this Mac's
#    Claude account key (sha256("humanneeded-account:" + accountUuid)[:32], accountUuid from
#    ~/.claude.json, the same as the cloud VM's) and any linked session hashes, and passes the
#    states that arrive to hn.sh. Unsigned states are accepted only for claimed keys, signed ones
#    only with this Mac's channel secret; every state must be under 5 min old and not a replay.
import base64, hashlib, hmac, json, os, re, secrets, socket, ssl, struct, subprocess, sys, threading, time
from urllib.parse import urlsplit

VERSION = '0.1.24'
RELAY_WS = 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1'
HERE = os.path.dirname(os.path.abspath(__file__))
HN = os.environ.get('HN_SCRIPT') or os.path.join(HERE, 'hn.sh')
BASH = os.environ.get('HN_BASH') or '/bin/bash'   # overridable for tests
HOME = os.path.expanduser('~')
DIR = os.path.join(HOME, '.humanneeded')
LOG = os.path.join(DIR, 'hn.log')
CLAIMS = os.path.join(DIR, 'claims.json')
RELAY_JSON = os.path.join(DIR, 'relay.json')
STATES = ('working', 'needs', 'done', 'idle', 'end')
HEX32 = re.compile(r'^[0-9a-f]{32}$')
_out = threading.Lock()


def log(text):
    try:
        os.makedirs(DIR, exist_ok=True)
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(time.strftime('%Y-%m-%d %H:%M:%S') + '  ' + text + '\n')
    except OSError:
        pass


def short_hash(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:32]


def run_hn(state, agent, session):
    try:
        subprocess.run([BASH, HN, state, agent], input=json.dumps({'session_id': session}).encode(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception as e:
        log('mcp: hn.sh failed: %s' % e)


def read_claims():
    now = time.time()
    try:
        with open(CLAIMS, encoding='utf-8') as f:
            return {k: v for k, v in json.load(f).items() if HEX32.match(k) and float(v) > now}
    except Exception:
        return {}


def add_claim(h):
    for _ in range(5):
        try:
            claims = read_claims()
            claims[h] = int(time.time()) + 86400
            os.makedirs(DIR, exist_ok=True)
            tmp = CLAIMS + '.%d' % os.getpid()
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(claims, f)
            os.replace(tmp, CLAIMS)
            log('mcp: relay: claimed cloud session %s...' % h[:6])
            return
        except OSError:
            time.sleep(0.1)


def account_key():
    for d in (os.environ.get('CLAUDE_CONFIG_DIR'), HOME):
        if not d:
            continue
        try:
            with open(os.path.join(d, '.claude.json'), encoding='utf-8', errors='replace') as f:
                m = re.search(r'"accountUuid"\s*:\s*"([0-9a-fA-F-]{36})"', f.read())
            if m:
                return short_hash('humanneeded-account:' + m.group(1))
        except OSError:
            pass
    return ''


def relay_config():
    try:
        with open(RELAY_JSON, encoding='utf-8-sig') as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    if not re.match(r'^hn1\.[0-9a-f]{32}\.[0-9a-f]{64}$', str(cfg.get('token', ''))):
        cfg = {'token': 'hn1.%s.%s' % (secrets.token_hex(16), secrets.token_hex(32)), 'ws': RELAY_WS, 'enabled': True}
        os.makedirs(DIR, exist_ok=True)
        with open(RELAY_JSON, 'w', encoding='utf-8') as f:
            json.dump(cfg, f)
        os.chmod(RELAY_JSON, 0o600)
        log('mcp: relay: created a new channel token in relay.json')
    cfg.setdefault('ws', RELAY_WS)
    return cfg


def set_state(args):
    args = args or {}
    log('mcp: set_state args: %s' % json.dumps(args)[:300])
    state = str(args.get('state', '')).lower()
    if state not in STATES:
        return "unknown state '%s'" % state, True
    sid = args.get('session_id') or args.get('sessionId') or args.get('session')
    agent = re.sub(r'\s', '', str(args.get('agent') or 'claude'))
    session = 'default'
    if sid:
        h = short_hash(str(sid).strip())
        add_claim(h)
        session = 'c-' + h[:16]
    log('mcp: set_state %s %s %s' % (state, session, agent))
    run_hn(state, agent, session)
    host = socket.gethostname()
    if session == 'default':
        return ('HumanNeeded check: the puck connector on %s set the light to %s. No session_id arrived, so no '
                'cloud session was linked.' % (host, state)), False
    return 'HumanNeeded check: the puck connector on %s got set_state %s and linked session %s' % (host, state, session), False


# --- Minimal WebSocket client (RFC 6455, client side) ---
class WebSocket:
    def __init__(self, url):
        u = urlsplit(url)
        port = u.port or 443
        raw = socket.create_connection((u.hostname, port), timeout=15)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        path = (u.path or '/') + ('?' + u.query if u.query else '')
        self.sock.sendall(('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                           'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' % (path, u.hostname, key)).encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError('closed during handshake')
            head += chunk
        head, self.buf = head.split(b'\r\n\r\n', 1)
        status = head.split(b'\r\n', 1)[0]
        if b' 101 ' not in status + b' ':
            raise IOError('handshake refused: %s' % status.decode(errors='replace'))

    def send(self, text, opcode=1):
        data = text.encode() if isinstance(text, str) else text
        mask = secrets.token_bytes(4)
        n = len(data)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack('>H', n)
        else:
            head += bytes([0x80 | 127]) + struct.pack('>Q', n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError('connection closed')
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self, timeout):
        """One text message, or None after `timeout` seconds without a frame start."""
        if not self.buf:
            self.sock.settimeout(timeout)
            try:
                chunk = self.sock.recv(4096)
            except (socket.timeout, ssl.SSLWantReadError):
                return None
            if not chunk:
                raise IOError('connection closed')
            self.buf += chunk
        self.sock.settimeout(30)
        message = b''
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7f
            if n == 126:
                n = struct.unpack('>H', self._read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            op = b0 & 0x0f
            if op == 8:
                raise IOError('closed by the relay')
            if op == 9:
                self.send(data, 10)
                continue
            if op == 10:
                continue
            message += data
            if b0 & 0x80:
                return message.decode('utf-8', errors='replace')

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def relay_listener(cfg, acct):
    parts = cfg['token'].split('.')
    channel, secret = parts[1], bytes.fromhex(parts[2])
    url = '%s?ch=%s' % (cfg['ws'], channel)
    seen = {}
    backoff = 5
    while True:
        ws = None
        try:
            ws = WebSocket(url)
            log('relay: connected, channel %s...' % channel[:6])
            backoff = 5
            stamp, last_ping, claims = None, time.time(), {}
            while True:
                try:
                    st = os.stat(CLAIMS).st_mtime_ns
                except OSError:
                    st = 0
                if st != stamp:
                    stamp = st
                    claims = read_claims()
                    if acct:
                        claims[acct] = float('inf')
                    keys = list(claims)[:16]
                    if keys:
                        ws.send(json.dumps({'action': 'claim', 'h': keys}))
                        log('relay: claimed %d cloud session(s) at the relay' % len(keys))
                if time.time() - last_ping > 300:
                    ws.send('{"action":"ping"}')
                    last_ping = time.time()
                text = ws.recv(1.0)
                if text is None:
                    continue
                try:
                    env = json.loads(text)
                    body, sig = str(env.get('b', '')), str(env.get('sig', '')).lower()
                    m = json.loads(body)
                    now = time.time()
                    if not sig:
                        h = str(env.get('h', ''))
                        if not HEX32.match(h) or str(m.get('h')) != h:
                            log('relay: dropped an unsigned message with a bad session hash')
                            continue
                        if h not in claims:
                            claims = read_claims()
                            if acct:
                                claims[acct] = float('inf')
                        if h not in claims:
                            log('relay: dropped a state for unclaimed session %s...' % h[:6])
                            continue
                        replay = body
                    else:
                        expected = hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()
                        if not hmac.compare_digest(sig, expected):
                            log('relay: dropped a message with a bad signature')
                            continue
                        replay = sig
                    for k in [k for k, t in seen.items() if now - t > 600]:
                        del seen[k]
                    if replay in seen:
                        log('relay: dropped a replayed message')
                        continue
                    seen[replay] = now
                    age = now - float(m.get('t', 0))
                    if abs(age) > 300:
                        log('relay: dropped a stale message (%d s old)' % age)
                        continue
                    state = str(m.get('s', '')).lower()
                    if state not in STATES:
                        continue
                    u = str(m.get('u', ''))
                    hh = u if re.match(r'^[0-9a-f]{16}$', u) else re.sub(r'[^0-9a-f]', '', str(m.get('h', '')))
                    session = 'c-' + hh[:16]
                    agent = re.sub(r'[^A-Za-z0-9_-]', '', str(m.get('a') or 'claude')) or 'claude'
                    log('relay: %s %s %s (%d s)' % (state, session, agent, age))
                    run_hn(state, agent, session)
                except Exception as e:
                    log('relay: bad message: %s' % e)
        except Exception as e:
            log('relay: error: %s; retry in %d s' % (e, backoff))
            time.sleep(backoff)
            backoff = min(backoff * 2, 120)
        finally:
            if ws:
                ws.close()


TOOLS = [{
    'name': 'set_state',
    'description': "Shows a session state on the HumanNeeded puck (the desk status light on the user's Mac). Call it "
                   'when the user asks to test the puck, or to link a cloud session: pass that session_id.',
    'inputSchema': {'type': 'object', 'required': ['state'], 'properties': {
        'state': {'type': 'string', 'enum': list(STATES)},
        'session_id': {'type': 'string', 'description': 'For a cloud session: the exact session_id given in the HumanNeeded '
                                                        'hook message. Without it only the light changes.'},
        'agent': {'type': 'string'}}},
}]


def send(obj):
    with _out:
        sys.stdout.write(json.dumps(obj) + '\n')
        sys.stdout.flush()


def main():
    log('mcp: started %s (pid %d, %s)' % (VERSION, os.getpid(), HERE))
    try:
        cfg = relay_config()
        if cfg.get('enabled', True) is not False:
            acct = account_key()
            log("mcp: relay: cloud sessions of this Mac's Claude account go to the puck (key %s...)" % acct[:6] if acct
                else 'mcp: relay: no Claude account found in .claude.json; cloud sessions need linking')
            threading.Thread(target=relay_listener, args=(cfg, acct), daemon=True).start()
    except Exception as e:
        log('mcp: relay: could not start: %s' % e)
    for line in sys.stdin:
        line = line.lstrip('﻿').strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        rid, method = req.get('id'), req.get('method')
        try:
            if method == 'initialize':
                result = {'protocolVersion': (req.get('params') or {}).get('protocolVersion') or '2025-06-18',
                          'capabilities': {'tools': {}}, 'serverInfo': {'name': 'humanneeded', 'version': VERSION}}
            elif method == 'tools/list':
                result = {'tools': TOOLS}
            elif method == 'tools/call':
                p = req.get('params') or {}
                if p.get('name') != 'set_state':
                    raise ValueError('unknown tool %s' % p.get('name'))
                text, err = set_state(p.get('arguments'))
                result = {'content': [{'type': 'text', 'text': text}], 'isError': err}
            elif method == 'ping':
                result = {}
            else:
                if rid is not None:
                    send({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32601, 'message': 'no method %s' % method}})
                continue
            if rid is not None:
                send({'jsonrpc': '2.0', 'id': rid, 'result': result})
        except Exception as e:
            if rid is not None:
                send({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32603, 'message': str(e)}})
    log('mcp: stopped')
    os._exit(0)


if __name__ == '__main__':
    main()
