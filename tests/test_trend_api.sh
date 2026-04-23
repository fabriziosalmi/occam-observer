#!/usr/bin/env bash
# End-to-end: bash engine persists snapshots → Go API /trend serves them.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="${SCRIPT_DIR}/telemetry_observer.sh"

command -v jq       >/dev/null || { echo "SKIP: jq required"     >&2; exit 0; }
command -v sqlite3  >/dev/null || { echo "SKIP: sqlite3 required">&2; exit 0; }
command -v go       >/dev/null || { echo "SKIP: go required"     >&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  SQLite persistence + /trend endpoint"
echo "────────────────────────────────────────────────────────────"

repo="$(mktemp -d /tmp/occam_trend_XXXXXX)"
db="$(mktemp /tmp/occam_trend_db_XXXXXX.db)"; rm -f "$db"
bin="$(mktemp /tmp/occam_trend_bin_XXXXXX)"
port=$(( 30000 + RANDOM % 10000 ))

cleanup() { [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null; wait "${API_PID:-0}" 2>/dev/null; rm -rf "$repo" "$db" "$bin" "${db}-wal" "${db}-shm"; }
trap cleanup EXIT

git -C "$repo" init -q
git -C "$repo" config user.email t@t.t && git -C "$repo" config user.name t
echo seed > "$repo/s.txt" && git -C "$repo" add . >/dev/null
git -C "$repo" commit -q -m init

# Write 3 snapshots
for _ in 1 2 3; do
    OCCAM_DB="$db" "$OBSERVER" --json "$repo" >/dev/null 2>/dev/null
done

rows="$(sqlite3 "$db" "SELECT COUNT(*) FROM snapshots;")"
if [ "$rows" = "3" ]; then pass "T1 3 snapshots persisted"
else fail "T1 rows=$rows want 3"; fi

# Build API binary
( cd "$SCRIPT_DIR/api" && go build -o "$bin" . ) 2>/dev/null || { fail "go build failed"; exit 1; }

OCCAM_DB="$db" API_PORT="$port" "$bin" >/dev/null 2>&1 &
API_PID=$!
sleep 1

resp="$(curl -sf "http://127.0.0.1:${port}/trend?limit=100" 2>/dev/null)"
len="$(printf '%s' "$resp" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$len" = "3" ]; then pass "T2 /trend returns 3 rows"
else fail "T2 len=$len  resp=${resp:0:200}"; fi

# filter by target
resp="$(curl -sf "http://127.0.0.1:${port}/trend?target=${repo}&limit=100" 2>/dev/null)"
len="$(printf '%s' "$resp" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$len" = "3" ]; then pass "T3 target filter matches"
else fail "T3 len=$len"; fi

# filter by nonexistent target
resp="$(curl -sf "http://127.0.0.1:${port}/trend?target=/no/such&limit=100" 2>/dev/null)"
len="$(printf '%s' "$resp" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$len" = "0" ]; then pass "T4 unknown target returns empty array"
else fail "T4 len=$len"; fi

# bad limit rejected
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/trend?limit=bogus")"
if [ "$code" = "400" ]; then pass "T5 bad limit → 400"
else fail "T5 code=$code"; fi

# limit cap
resp="$(curl -sf "http://127.0.0.1:${port}/trend?limit=2" 2>/dev/null)"
len="$(printf '%s' "$resp" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "$len" = "2" ]; then pass "T6 limit=2 returns 2"
else fail "T6 len=$len"; fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
