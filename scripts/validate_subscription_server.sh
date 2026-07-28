#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON_BIN="${PYTHON_BIN:-python3}"
if [[ "$PYTHON_BIN" == */* ]]; then
    [[ -x "$PYTHON_BIN" ]] || { echo "Python 不可执行: $PYTHON_BIN" >&2; exit 1; }
else
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || { echo "未找到 Python: $PYTHON_BIN" >&2; exit 1; }
fi

TMP_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SERVER_FILE="$TMP_DIR/subscription_server.py"
awk '
    /subscription_server\.py.*<<'"'"'PYEOF'"'"'/ { capture=1; next }
    capture && /^PYEOF$/ { exit }
    capture { print }
' "$ROOT_DIR/modules/subscription.sh" > "$SERVER_FILE"

grep -q 'class SubscriptionHTTPServer(http.server.ThreadingHTTPServer)' "$SERVER_FILE"
grep -q 'request_queue_size = 128' "$SERVER_FILE"
grep -q "request.settimeout(15)" "$SERVER_FILE"
grep -q "request_path == '/healthz'" "$SERVER_FILE"
"$PYTHON_BIN" -m py_compile "$SERVER_FILE"

mkdir -p "$TMP_DIR/subscriptions" "$TMP_DIR/data"
printf 'fixture-subscription\n' > "$TMP_DIR/subscriptions/demo_fixture_raw.txt"
cat > "$TMP_DIR/data/users.json" <<'JSON'
{"users":[{"id":"fixture","username":"fixture","traffic_used_gb":"1.5","traffic_limit_gb":"10","expire_date":"unlimited"}]}
JSON

PORT=$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)
"$PYTHON_BIN" "$SERVER_FILE" "$PORT" "$TMP_DIR/subscriptions" "$TMP_DIR/data" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID=$!

"$PYTHON_BIN" - "$PORT" <<'PY'
import sys
import time
import urllib.request

url = f"http://127.0.0.1:{sys.argv[1]}/healthz"
for _ in range(30):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            if response.status == 200 and b'"status":"ok"' in response.read():
                break
    except Exception:
        time.sleep(0.1)
else:
    raise SystemExit("subscription server health check did not become ready")
PY

"$PYTHON_BIN" - "$PORT" <<'PY'
import concurrent.futures
import socket
import sys
import time
import urllib.request

port = int(sys.argv[1])
slow = socket.create_connection(('127.0.0.1', port), timeout=2)
slow.sendall(b'GET /sub/demo_fixture_raw.txt HTTP/1.1\r\nHost: localhost\r\n')
time.sleep(0.2)

started = time.monotonic()
with urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=2) as response:
    assert response.status == 200
    assert b'"status":"ok"' in response.read()
assert time.monotonic() - started < 1.5

def health(_):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=2) as response:
        return response.status, response.read()

with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
    results = list(executor.map(health, range(32)))
assert all(status == 200 and b'"status":"ok"' in body for status, body in results)

with urllib.request.urlopen(f'http://127.0.0.1:{port}/sub/demo_fixture_raw.txt', timeout=2) as response:
    assert response.read() == b'fixture-subscription\n'
    assert 'upload=' in response.headers['subscription-userinfo']

slow.close()
PY

echo "订阅服务并发与健康检查通过"
