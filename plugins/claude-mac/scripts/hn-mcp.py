#!/usr/bin/env python3
# HumanNeeded connector for macOS (MCP over stdio), the counterpart of hn-mcp.ps1.
# Standard library only. hn-mcp.sh starts it when python3 is usable.
#
#  - Tool set_state: shows a state on the puck through hn.sh (for testing it from a session that
#    can't run hn.sh itself, such as a Cowork session).
#  - Cloud relay listener: connects to the HumanNeeded relay with this Claude account's key,
#    sha256("humanneeded-account:" + accountUuid)[:32] (accountUuid from ~/.claude.json, the same
#    as in the account's cloud VMs), and passes the states that arrive to hn.sh. States must be
#    for this key and under 5 min old.
import base64, hashlib, json, os, re, secrets, socket, ssl, struct, subprocess, sys, threading, time
from urllib.parse import urlsplit
try:
    import fcntl
except ImportError:   # Windows, when testing there
    fcntl = None

RELAY_WS = 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1'
HERE = os.path.dirname(os.path.abspath(__file__))
HN = os.environ.get('HN_SCRIPT') or os.path.join(HERE, 'hn.sh')
BASH = os.environ.get('HN_BASH') or '/bin/bash'   # overridable for tests
HOME = os.path.expanduser('~')
DIR = os.path.join(HOME, '.humanneeded')
LOG = os.path.join(DIR, 'hn.log')
STATES = ('working', 'needs', 'done', 'idle', 'end')
_out = threading.Lock()

try:
    with open(os.path.join(HERE, '..', '.claude-plugin', 'plugin.json'), encoding='utf-8') as _f:
        VERSION = json.load(_f)['version']
except Exception:
    VERSION = 'dev'


def log(text):
    try:
        os.makedirs(DIR, exist_ok=True)
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(time.strftime('%Y-%m-%d %H:%M:%S') + '  ' + text + '\n')
    except OSError:
        pass


def run_hn(state, agent, session):
    try:
        subprocess.run([BASH, HN, state, agent], input=json.dumps({'session_id': session}).encode(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception as e:
        log('mcp: hn.sh failed: %s' % e)


def account_key():
    for d in (os.environ.get('CLAUDE_CONFIG_DIR'), HOME):
        if not d:
            continue
        try:
            with open(os.path.join(d, '.claude.json'), encoding='utf-8', errors='replace') as f:
                m = re.search(r'"accountUuid"\s*:\s*"([0-9a-fA-F-]{36})"', f.read())
            if m:
                return hashlib.sha256(('humanneeded-account:' + m.group(1)).encode()).hexdigest()[:32]
        except OSError:
            pass
    return ''


def set_state(args):
    args = args or {}
    state = str(args.get('state', '')).lower()
    if state not in STATES:
        return "unknown state '%s'" % state, True
    agent = re.sub(r'[^A-Za-z0-9_-]', '', str(args.get('agent') or 'claude')) or 'claude'
    log('mcp: set_state %s %s' % (state, agent))
    run_hn(state, agent, 'default')
    return 'The puck on %s now shows %s.' % (socket.gethostname(), state), False


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


def relay_listener(key):
    # One listener per account: other connector instances wait for the lock.
    lock = open(os.path.join(DIR, 'relay-%s.lock' % key[:12]), 'w')
    if fcntl:
        fcntl.flock(lock, fcntl.LOCK_EX)
    url = '%s?k=%s' % (RELAY_WS, key)
    backoff = 5
    while True:
        ws = None
        try:
            ws = WebSocket(url)
            log('relay: connected')
            backoff = 5
            last_ping = time.time()
            while True:
                # API Gateway drops idle sockets after 10 min; ping every 5.
                if time.time() - last_ping > 300:
                    ws.send('{"action":"ping"}')
                    last_ping = time.time()
                text = ws.recv(1.0)
                if text is None:
                    continue
                try:
                    # {"s":state,"h":account key,"u":session hash,"t":unix time,"a":agent}
                    m = json.loads(text)
                    if str(m.get('h')) != key:
                        log('relay: dropped a state for another key')
                        continue
                    age = time.time() - float(m.get('t', 0))
                    if abs(age) > 300:
                        log('relay: dropped a stale state (%d s old)' % age)
                        continue
                    state = str(m.get('s', '')).lower()
                    if state not in STATES:
                        continue
                    session = 'c-' + re.sub(r'[^0-9a-f]', '', str(m.get('u', '')))
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
    'description': "Shows a state on the HumanNeeded puck (the desk status light on the user's computer). Call it "
                   'when the user asks to test or preview the puck.',
    'inputSchema': {'type': 'object', 'required': ['state'], 'properties': {
        'state': {'type': 'string', 'enum': list(STATES)},
        'agent': {'type': 'string'}}},
}]


def send(obj):
    with _out:
        sys.stdout.write(json.dumps(obj) + '\n')
        sys.stdout.flush()


def main():
    log('mcp: started %s (pid %d, %s)' % (VERSION, os.getpid(), HERE))
    try:
        key = account_key()
        if key:
            os.makedirs(DIR, exist_ok=True)
            log('mcp: relay: cloud sessions of this Claude account go to the puck (key %s...)' % key[:6])
            threading.Thread(target=relay_listener, args=(key,), daemon=True).start()
        else:
            log("mcp: relay: no Claude account in .claude.json, so cloud sessions can't reach the puck")
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
