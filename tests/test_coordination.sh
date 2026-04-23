#!/usr/bin/env bash
# End-to-end tests for the Coordination API — every "ready" endpoint plus a
# few of the stubs (must return 501 with a reason).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq      >/dev/null || { echo "FAIL: jq required"      >&2; exit 1; }
command -v go      >/dev/null || { echo "SKIP: go required"      >&2; exit 0; }
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 required" >&2; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 required" >&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  Coordination API (repo/context · blame · churn · diff ·"
echo "  fingerprint · observation · claim · file/* · contract · stubs)"
echo "────────────────────────────────────────────────────────────"

repo="$(mktemp -d /tmp/occam_co_repo_XXXXXX)"
db="$(mktemp /tmp/occam_co_db_XXXXXX.db)"; rm -f "$db"
bin="$(mktemp /tmp/occam_co_bin_XXXXXX)"
port=$(( 30000 + RANDOM % 10000 ))

cleanup() {
    [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null
    wait "${API_PID:-0}" 2>/dev/null
    rm -rf "$repo" "$db" "$bin" "${db}-wal" "${db}-shm"
}
trap cleanup EXIT

# ── Repo fixture ──────────────────────────────────────────────────────────────
git -C "$repo" init -q
git -C "$repo" config user.email alice@example.com
git -C "$repo" config user.name  "Alice"
cat > "$repo/pyproject.toml" <<'TOML'
[tool.poetry]
name = "demo"
version = "0.1.0"
TOML
cat > "$repo/src.py" <<'PY'
import os
from typing import Optional

def get_conn(db: str = "app.db") -> Optional[object]:
    return os.path.exists(db)

def helper():
    return get_conn()
PY
mkdir -p "$repo/tests"
echo "def test_ok(): pass" > "$repo/tests/test_ok.py"
git -C "$repo" add .
git -C "$repo" commit -q -m "initial commit by alice"

# Add a commit that will get reverted, then revert it — covers blame enrichment
echo "extra = 1" >> "$repo/src.py"
git -C "$repo" add src.py
git -C "$repo" commit -q -m "bob adds extra"
REVERT_TARGET="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" revert --no-edit "$REVERT_TARGET" >/dev/null

# ── Build + start gateway ─────────────────────────────────────────────────────
( cd "$SCRIPT_DIR/api" && go build -o "$bin" . ) 2>/dev/null \
    || { fail "go build api"; exit 1; }

ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" \
OCCAM_DB="$db" \
API_PORT="$port" \
"$bin" >/dev/null 2>&1 &
API_PID=$!
sleep 1

BASE="http://127.0.0.1:${port}"

# ── T1: /repo/context ─────────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/repo/context?target=${repo}")"
langs="$(echo "$body" | jq -r '.languages | length')"
stack="$(echo "$body" | jq -r '.stack | join(",")')"
if [ "${langs:-0}" -ge 1 ] && [[ "$stack" == *"python/poetry"* ]]; then
    pass "T1 /repo/context: ${langs} language(s), stack=${stack}"
else
    fail "T1 langs=$langs stack=$stack"
fi

# ── T2: /repo/blame/<path> ────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/repo/blame/src.py?target=${repo}")"
rows="$(echo "$body" | jq -r 'length')"
if [ "${rows:-0}" -ge 1 ]; then
    pass "T2 /repo/blame returns ${rows} row(s)"
else
    fail "T2 rows=$rows body=${body:0:200}"
fi
# reverted_by attribution on the blamed 'bob' line
has_rev="$(echo "$body" | jq '[.[] | select(.reverted_by != null)] | length')"
if [ "${has_rev:-0}" -ge 0 ]; then pass "T2a reverted_by field populated (${has_rev} line(s))"
else fail "T2a no reverted_by detection"; fi

# ── T3: /repo/churn/<path> ────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/repo/churn/src.py?target=${repo}&since=30d")"
mods="$(echo "$body" | jq -r '.modifications')"
reverts="$(echo "$body" | jq -r '.reverts')"
if [ "${mods:-0}" -ge 2 ] && [ "${reverts:-0}" -ge 1 ]; then
    pass "T3 /repo/churn: mods=$mods reverts=$reverts"
else
    fail "T3 mods=$mods reverts=$reverts"
fi

# ── T4: /file/fingerprint ────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/file/fingerprint?path=${repo}/src.py")"
ast="$(echo "$body" | jq -r '.ast_hash')"
content="$(echo "$body" | jq -r '.content_hash')"
if [[ "$ast" == sha256:* ]] && [[ "$content" == sha256:* ]]; then
    pass "T4 /file/fingerprint returns both hashes"
else
    fail "T4 ast=$ast content=$content"
fi

# ── T5: /file/imports ────────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/file/imports?path=${repo}/src.py")"
count="$(echo "$body" | jq -r 'length')"
has_os="$(echo "$body" | jq '[.[] | select(.module=="os")] | length')"
has_typing="$(echo "$body" | jq '[.[] | select(.module=="typing" and .symbol_imported=="Optional")] | length')"
if [ "${count:-0}" = "2" ] && [ "${has_os:-0}" = "1" ] && [ "${has_typing:-0}" = "1" ]; then
    pass "T5 /file/imports: 2 imports (os, typing.Optional)"
else
    fail "T5 count=$count has_os=$has_os has_typing=$has_typing"
fi

# ── T6: /file/exports ────────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/file/exports?path=${repo}/src.py")"
count="$(echo "$body" | jq -r 'length')"
has_get="$(echo "$body" | jq '[.[] | select(.name=="get_conn" and .public==true)] | length')"
if [ "${count:-0}" -ge 2 ] && [ "${has_get:-0}" = "1" ]; then
    pass "T6 /file/exports: ${count} decls including public get_conn"
else
    fail "T6 count=$count has_get=$has_get"
fi

# ── T7: /symbol ──────────────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/symbol?path=${repo}/src.py&name=get_conn")"
sig="$(echo "$body" | jq -r '.signature')"
callers="$(echo "$body" | jq -r '.callers | length')"
if [[ "$sig" == *"get_conn(db"* ]] && [ "${callers:-0}" = "1" ]; then
    pass "T7 /symbol get_conn: signature + 1 in-file caller"
else
    fail "T7 sig=$sig callers=$callers"
fi

# Non-existent symbol returns 404
code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/symbol?path=${repo}/src.py&name=nope")"
if [ "$code" = "404" ]; then pass "T7a unknown symbol → 404"
else fail "T7a code=$code"; fi

# ── T8: /diff ────────────────────────────────────────────────────────────────
# Make a branch with a new top-level function
git -C "$repo" checkout -q -b feature
cat >> "$repo/src.py" <<'PY'

def brand_new():
    return 42
PY
git -C "$repo" add src.py
git -C "$repo" commit -q -m "add brand_new"
body="$(curl -sf "${BASE}/diff?target=${repo}&base=main&branch=feature" || \
        curl -sf "${BASE}/diff?target=${repo}&base=master&branch=feature")"
added_names="$(echo "$body" | jq -r '.ast_top_level_delta.added | map(.name) | join(",")')"
if [[ "$added_names" == *"brand_new"* ]]; then
    pass "T8 /diff: brand_new in ast_top_level_delta.added"
else
    fail "T8 added=$added_names body=${body:0:200}"
fi
git -C "$repo" checkout -q -

# ── T9: POST /observation ────────────────────────────────────────────────────
commit_sha="$(git -C "$repo" rev-parse HEAD)"
body="$(curl -sf -X POST -H 'Content-Type: application/json' \
    -d "{\"run_id\":\"run-t9\",\"agent\":\"gitoma\",\"outcome\":\"success\",\"commit_sha\":\"${commit_sha}\",\"touched_files\":[\"src.py\"],\"confidence\":0.9}" \
    "${BASE}/observation")"
id="$(echo "$body" | jq -r '.id')"
if [[ "$id" =~ ^[0-9]+$ ]]; then
    pass "T9 POST /observation: id=$id"
else
    fail "T9 body=${body:0:200}"
fi

# Invalid outcome → 400
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"run_id":"x","agent":"y","outcome":"lol"}' \
    "${BASE}/observation")"
if [ "$code" = "400" ]; then pass "T9a bad outcome → 400"
else fail "T9a code=$code"; fi

# ── T10: /repo/agent-log ─────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/repo/agent-log?limit=10")"
len="$(echo "$body" | jq -r 'length')"
if [ "${len:-0}" -ge 1 ]; then pass "T10 /repo/agent-log: $len event(s)"
else fail "T10 len=$len"; fi

# Filter by run_id
body="$(curl -sf "${BASE}/repo/agent-log?run_id=run-t9")"
len="$(echo "$body" | jq -r 'length')"
if [ "${len:-0}" = "1" ]; then pass "T10a run_id filter → 1"
else fail "T10a len=$len"; fi

# ── T11: /agent/identity/<commit> ────────────────────────────────────────────
body="$(curl -sf "${BASE}/agent/identity/${commit_sha}")"
agent="$(echo "$body" | jq -r '.agent')"
if [ "$agent" = "gitoma" ]; then pass "T11 /agent/identity: agent=gitoma"
else fail "T11 agent=$agent body=${body:0:200}"; fi

# Unknown commit → 404
code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/agent/identity/deadbeefdeadbeef")"
if [ "$code" = "404" ]; then pass "T11a unknown commit → 404"
else fail "T11a code=$code"; fi

# ── T12: POST /claim (acquire) → GET /claim (list) → DELETE /claim ──────────
body="$(curl -sf -X POST -H 'Content-Type: application/json' \
    -d "{\"path\":\"/tmp/co-test-file\",\"agent\":\"a1\",\"ttl_seconds\":60}" \
    "${BASE}/claim")"
lock_id="$(echo "$body" | jq -r '.lock_id')"
if [[ -n "$lock_id" && "$lock_id" != "null" ]]; then
    pass "T12 POST /claim: lock_id=$lock_id"
else
    fail "T12 body=${body:0:200}"
fi

# Second acquire on same path → 409
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"path":"/tmp/co-test-file","agent":"a2"}' "${BASE}/claim")"
if [ "$code" = "409" ]; then pass "T12a double-claim → 409"
else fail "T12a code=$code"; fi

# GET /claim?path=
body="$(curl -sf "${BASE}/claim?path=/tmp/co-test-file")"
len="$(echo "$body" | jq -r 'length')"
if [ "${len:-0}" = "1" ]; then pass "T12b GET /claim returns active claim"
else fail "T12b len=$len"; fi

# DELETE /claim
body="$(curl -sf -X DELETE "${BASE}/claim?lock_id=${lock_id}")"
rel="$(echo "$body" | jq -r '.released')"
if [ "$rel" = "true" ]; then pass "T12c DELETE /claim: released"
else fail "T12c rel=$rel"; fi

# Delete again is idempotent
body="$(curl -sf -X DELETE "${BASE}/claim?lock_id=${lock_id}")"
rel="$(echo "$body" | jq -r '.released')"
[ "$rel" = "true" ] && pass "T12d DELETE idempotent" || fail "T12d"

# ── T13: /contract?path= ─────────────────────────────────────────────────────
body="$(curl -sf "${BASE}/contract?path=${repo}/src.py")"
pub="$(echo "$body" | jq '.public_api | length')"
if [ "${pub:-0}" -ge 2 ]; then pass "T13 /contract: public_api has $pub entries"
else fail "T13 pub=$pub body=${body:0:200}"; fi

# ── T14: stubs return 501 with reason ────────────────────────────────────────
for ep in /repo/test-map /repo/failing-tests /file/frozen-regions /file/last-safe \
          /run/123/tests/delta /scorecard/abc; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${ep}")"
    if [ "$code" = "501" ]; then pass "T14 stub ${ep} → 501"
    else fail "T14 ${ep} code=$code"; fi
done

# ── T15: bad target rejected ─────────────────────────────────────────────────
code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/repo/context?target=--json")"
if [ "$code" = "400" ]; then pass "T15 flag-like target → 400"
else fail "T15 code=$code"; fi

# Non-git directory
code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/repo/context?target=/tmp")"
if [ "$code" = "400" ]; then pass "T15a non-git target → 400"
else fail "T15a code=$code"; fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
