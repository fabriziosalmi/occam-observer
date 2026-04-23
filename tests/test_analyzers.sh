#!/usr/bin/env bash
# Pluggable analyzers + severity escalation + performance block.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="${SCRIPT_DIR}/telemetry_observer.sh"

command -v jq      >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: python3 required for python-ast tests" >&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

mk_repo() {
    local repo; repo="$(mktemp -d /tmp/occam_an_XXXXXX)"
    git -C "$repo" init -q
    git -C "$repo" config user.email "t@t.t"
    git -C "$repo" config user.name  "t"
    echo seed > "$repo/seed.txt"
    git -C "$repo" add . >/dev/null
    git -C "$repo" commit -q -m init
    printf '%s' "$repo"
}

echo "────────────────────────────────────────────────────────────"
echo "  pluggable analyzers + severity escalation"
echo "────────────────────────────────────────────────────────────"

# T1: python-ast picks up eval()
repo="$(mk_repo)"
cat > "$repo/a.py" <<'PY'
def run(x): return eval(x)
PY
git -C "$repo" add a.py >/dev/null
out="$("$OBSERVER" --json --staged "$repo" 2>/dev/null)"
# Find python-ast report in analyzers list
py_findings="$(echo "$out" | jq '[.intelligence.analyzers[] | select(.name=="python-ast")][0].findings | length')"
if [ "${py_findings:-0}" -ge 1 ]; then pass "T1 python-ast emits finding for eval()"
else fail "T1 py_findings=$py_findings"; fi

# T2: severity escalated to critical
level="$(echo "$out" | jq -r '.check.level')"
if [ "$level" = "critical" ]; then pass "T2 analyzer critical → .check.level=critical"
else fail "T2 level=$level"; fi

# T3: reasons mentions analyzer
reasons="$(echo "$out" | jq -r '.check.reasons | join(",")')"
if [[ "$reasons" == *analyzer_critical* ]]; then pass "T3 .check.reasons mentions analyzer_critical"
else fail "T3 reasons=$reasons"; fi

# T4: performance block present with expected shape
dur="$(echo "$out" | jq -r '.performance.engine_duration_ms')"
bytes="$(echo "$out" | jq -r '.performance.diff_bytes')"
alist="$(echo "$out" | jq -c '.performance.analyzers_run')"
if [[ "$dur" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] && [[ "$alist" == *python-ast* ]]; then
    pass "T4 performance block populated"
else
    fail "T4 dur=$dur bytes=$bytes alist=$alist"
fi

# T5: OCCAM_NO_ANALYZERS=1 skips the pluggable path
out2="$(OCCAM_NO_ANALYZERS=1 "$OBSERVER" --json --staged "$repo" 2>/dev/null)"
alen="$(echo "$out2" | jq -r '.intelligence.analyzers | length')"
if [ "$alen" = "0" ]; then pass "T5 OCCAM_NO_ANALYZERS=1 disables analyzers"
else fail "T5 alen=$alen"; fi

# T6: trace_id propagates into JSON from env
out3="$(OCCAM_TRACE_ID=deadbeef "$OBSERVER" --json --staged "$repo" 2>/dev/null)"
tid="$(echo "$out3" | jq -r '.trace_id')"
if [ "$tid" = "deadbeef" ]; then pass "T6 trace_id propagated from env"
else fail "T6 tid=$tid"; fi

rm -rf "$repo"

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
