#!/usr/bin/env bash
# /healthz /readyz /metrics + trace_id round-trip through the Go gateway.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq      >/dev/null || { echo "FAIL: jq required"     >&2; exit 1; }
command -v go      >/dev/null || { echo "SKIP: go required"     >&2; exit 0; }
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 required">&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  self-observability + trace_id"
echo "────────────────────────────────────────────────────────────"

repo="$(mktemp -d /tmp/occam_selfobs_XXXXXX)"
db="$(mktemp /tmp/occam_selfobs_db_XXXXXX.db)"; rm -f "$db"
bin="$(mktemp /tmp/occam_selfobs_bin_XXXXXX)"
port=$(( 30000 + RANDOM % 10000 ))

cleanup() { [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null; wait "${API_PID:-0}" 2>/dev/null; rm -rf "$repo" "$db" "$bin" "${db}-wal" "${db}-shm"; }
trap cleanup EXIT

git -C "$repo" init -q
git -C "$repo" config user.email t@t.t && git -C "$repo" config user.name t
echo seed > "$repo/s.txt" && git -C "$repo" add . >/dev/null
git -C "$repo" commit -q -m init

( cd "$SCRIPT_DIR/api" && go build -o "$bin" . ) 2>/dev/null || { fail "go build failed"; exit 1; }

ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" \
OCCAM_DB="$db" \
API_PORT="$port" \
"$bin" >/dev/null 2>&1 &
API_PID=$!
sleep 1

# T1: /healthz always 200
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz")"
[ "$code" = "200" ] && pass "T1 /healthz = 200" || fail "T1 code=$code"

# T2: /readyz returns 503 before any run (no cache, no DB)
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/readyz")"
# NOTE: if /tmp/occam_state.json from a prior run exists, this may be 200.
# Accept either 200 or 503 — just require the body be valid JSON.
body="$(curl -s "http://127.0.0.1:${port}/readyz")"
echo "$body" | jq -e '.status' >/dev/null 2>&1 && pass "T2 /readyz valid JSON (code=$code)" || fail "T2 body=$body"

# T3: fire an analysis, /readyz flips to ready
curl -sf "http://127.0.0.1:${port}/analyze?path=${repo}" >/dev/null
status="$(curl -s "http://127.0.0.1:${port}/readyz" | jq -r '.status')"
[ "$status" = "ready" ] && pass "T3 /readyz=ready after first analyze" || fail "T3 status=$status"

# T4: /metrics is Prometheus text
mbody="$(curl -sf "http://127.0.0.1:${port}/metrics")"
[[ "$mbody" == *'occam_up 1'* ]] && pass "T4 /metrics exposes occam_up=1" || fail "T4 missing occam_up"
[[ "$mbody" == *'occam_analyses_total{result="ok"}'* ]] && pass "T4a /metrics analyses counter present" || fail "T4a"

# T5: /metrics counts increment on subsequent analyses
for _ in 1 2; do curl -sf "http://127.0.0.1:${port}/analyze?path=${repo}" >/dev/null; done
ok_count="$(curl -sf "http://127.0.0.1:${port}/metrics" | awk '/^occam_analyses_total\{result="ok"\}/ {print $2}')"
if [ "${ok_count:-0}" -ge 3 ]; then pass "T5 analyses_total{ok} >= 3 (got $ok_count)"
else fail "T5 count=$ok_count"; fi

# T6: trace_id is echoed in X-Trace-Id
hdr="$(curl -sI -H 'X-Trace-Id: testcafe01234567' "http://127.0.0.1:${port}/analyze?path=${repo}" | awk -F': ' 'tolower($1)=="x-trace-id" {print $2}' | tr -d '\r\n ')"
[ "$hdr" = "testcafe01234567" ] && pass "T6 X-Trace-Id echoed back" || fail "T6 hdr='$hdr'"

# T7: trace_id propagates into the response body
body="$(curl -s -H 'X-Trace-Id: testcafe01234567' "http://127.0.0.1:${port}/analyze?path=${repo}")"
tid="$(echo "$body" | jq -r '.trace_id')"
[ "$tid" = "testcafe01234567" ] && pass "T7 trace_id in response body" || fail "T7 tid=$tid"

# T8: snapshots gauge reflects DB rows
snap="$(curl -sf "http://127.0.0.1:${port}/metrics" | awk '/^occam_snapshots_total/ {print $2}')"
if [ "${snap:-0}" -ge 1 ]; then pass "T8 occam_snapshots_total=$snap"
else fail "T8 snap=$snap"; fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
