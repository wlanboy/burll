#!/usr/bin/env bash
# Run with: bash test.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0
PORT=18080
BASE="http://127.0.0.1:${PORT}"
SERVER_PID=""

# --- Minimal HTTP server (GET + POST, /slow stalls for timeout tests) --------

start_server() {
    python3 - <<'PYEOF' &
import http.server, json, time

class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/slow":
            time.sleep(30)
        self._reply(200, {"method": "GET", "path": self.path,
                          "headers": dict(self.headers), "status": "UP"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        received = self.rfile.read(n).decode()
        self._reply(201, {"method": "POST", "received": received,
                          "content-type": self.headers.get("Content-Type", "")})

    def log_message(self, *_): pass

http.server.ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
PYEOF
    SERVER_PID=$!
    # Wait up to 4 s for the server to accept connections
    for _ in {1..20}; do
        (exec 3<>/dev/tcp/127.0.0.1/"${PORT}") 2>/dev/null && return 0
        sleep 0.2
    done
    echo "ERROR: test server did not start" >&2
    return 1
}

stop_server() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; }
trap stop_server EXIT

# --- Assertion helpers --------------------------------------------------------

pass() { printf "${GREEN}PASS${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}FAIL${NC} %s\n     %s\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local desc="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then pass "$desc"
    else fail "$desc" "expected '${needle}' in output"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" hay="$3"
    if [[ "$hay" != *"$needle"* ]]; then pass "$desc"
    else fail "$desc" "did not expect '${needle}' in output"; fi
}

assert_rc_nonzero() {
    local desc="$1" rc="$2"
    if [[ "$rc" -ne 0 ]]; then pass "$desc"
    else fail "$desc" "expected non-zero exit code, got 0"; fi
}

# --- Setup -------------------------------------------------------------------

# shellcheck source=../burll.sh
source "$(dirname "$0")/../burll.sh"
start_server

printf "\n${BOLD}=== burl tests ===${NC}\n\n"

# --- Tests -------------------------------------------------------------------

# 1. Basic GET returns JSON body
out=$(burl "$BASE/health")
assert_contains "GET returns body" '"status": "UP"' "$out"

# 2. Body-only mode strips HTTP headers
out=$(burl "$BASE/health")
assert_not_contains "GET body-only has no status line" "HTTP/" "$out"

# 3. -i includes response headers and body
out=$(burl -i "$BASE/health")
assert_contains "-i includes HTTP status line" "HTTP/1.0 200" "$out"
assert_contains "-i still includes body" '"status": "UP"' "$out"

# 4. -X POST sends correct method and body
out=$(burl -X POST -d 'key=value' "$BASE/submit")
assert_contains "POST method reflected" '"method": "POST"' "$out"
assert_contains "POST body received by server" '"received": "key=value"' "$out"

# 5. -H custom header
out=$(burl -H 'Accept: application/json' "$BASE/health")
assert_contains "-H does not break request" '"status": "UP"' "$out"

# 6. Default Content-Type for POST with -d
out=$(burl -X POST -d 'x=1' "$BASE/submit")
assert_contains "default Content-Type is form-urlencoded" 'application/x-www-form-urlencoded' "$out"

# 7. Explicit Content-Type overrides default
out=$(burl -X POST -H 'Content-Type: application/json' -d '{"x":1}' "$BASE/submit")
assert_contains "-H Content-Type override respected" 'application/json' "$out"

# 8. -o writes response body to file
tmp=$(mktemp)
burl -o "$tmp" "$BASE/health"
assert_contains "-o writes body to file" '"status": "UP"' "$(cat "$tmp")"
rm -f "$tmp"

# 9. -v shows outgoing request on stderr
stderr=$(burl -v "$BASE/health" 2>&1 >/dev/null)
assert_contains "-v shows > request line on stderr" "> GET" "$stderr"

# 10. -v shows incoming status line on stderr
assert_contains "-v shows < response line on stderr" "< HTTP" "$stderr"

# 11. -m timeout aborts slow request
out=$(burl -m 1 "$BASE/slow" 2>&1) && rc=0 || rc=$?
assert_rc_nonzero "-m 1 times out against slow endpoint" "$rc"

# 12. Connection refused returns non-zero
out=$(burl "http://127.0.0.1:19999/" 2>&1) && rc=0 || rc=$?
assert_rc_nonzero "connection refused returns error exit code" "$rc"

# 13. Path is preserved correctly
out=$(burl "$BASE/actuator/health")
assert_contains "multi-segment path sent correctly" '"/actuator/health"' "$out"

# --- Summary -----------------------------------------------------------------

printf "\n${BOLD}Results: ${GREEN}${PASS} passed${NC}${BOLD}, "
if [[ "$FAIL" -gt 0 ]]; then
    printf "${RED}${FAIL} failed${NC}\n"
    exit 1
else
    printf "${GREEN}0 failed${NC}\n"
fi
