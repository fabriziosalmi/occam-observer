#!/usr/bin/env bash
# Regression coverage for --check / --fail-on / --diff modes / severity engine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="${SCRIPT_DIR}/telemetry_observer.sh"

command -v jq >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

mk_repo() {
    local repo; repo="$(mktemp -d /tmp/occam_check_XXXXXX)"
    git -C "$repo" init -q
    git -C "$repo" config user.email "t@t.local"
    git -C "$repo" config user.name  "Tester"
    echo seed > "$repo/seed.txt"
    git -C "$repo" add . >/dev/null
    git -C "$repo" commit -q -m init
    printf '%s' "$repo"
}

echo "────────────────────────────────────────────────────────────"
echo "  --check / --fail-on / --diff"
echo "────────────────────────────────────────────────────────────"

# T1: clean repo, --check default fail-on=high → exit 0
repo="$(mk_repo)"
"$OBSERVER" --check "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 0 ]; then pass "T1 clean repo exits 0"
else fail "T1 clean repo exit=$ec"; fi

# T2: security violation → exit 1 at fail-on=high
cat > "$repo/bad.py" <<'PY'
API_KEY = "leak"
password = "hunter2"
PY
git -C "$repo" add bad.py >/dev/null
"$OBSERVER" --check --fail-on=high --staged "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 1 ]; then pass "T2 security→critical≥high exits 1"
else fail "T2 expected exit=1, got $ec"; fi

# T3: same security violation, fail-on=critical → exit 1 (critical ≥ critical)
"$OBSERVER" --check --fail-on=critical --staged "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 1 ]; then pass "T3 security→critical≥critical exits 1"
else fail "T3 expected exit=1, got $ec"; fi

# T4: low-severity only debt, fail-on=high → exit 0 (low < high)
git -C "$repo" reset -q HEAD bad.py
rm "$repo/bad.py"
cat > "$repo/minor.py" <<'PY'
# TODO: refactor
PY
git -C "$repo" add minor.py >/dev/null
"$OBSERVER" --check --fail-on=high --staged "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 0 ]; then pass "T4 debt-only at fail-on=high exits 0"
else fail "T4 expected exit=0, got $ec"; fi

# T5: same debt-only, fail-on=low → exit 1
"$OBSERVER" --check --fail-on=low --staged "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 1 ]; then pass "T5 debt-only at fail-on=low exits 1"
else fail "T5 expected exit=1, got $ec"; fi

# T6: invalid --fail-on → exit 3
"$OBSERVER" --check --fail-on=bogus "$repo" >/dev/null 2>/dev/null
ec=$?
if [ "$ec" -eq 3 ]; then pass "T6 invalid fail-on exits 3"
else fail "T6 expected exit=3, got $ec"; fi

# T7: --diff=head vs --diff=working against a TRACKED file that was modified
# (untracked files don't appear in `git diff`; the engine only sees changes
# to files git knows about, so the test uses an edit-in-place).
rm -f "$repo/minor.py"
git -C "$repo" reset -q --hard >/dev/null
# seed.txt is tracked; append a secret line, leave unstaged
echo 'password = "plain"' >> "$repo/seed.txt"
out_head="$("$OBSERVER" --json --diff=head "$repo" 2>/dev/null)"
out_work="$("$OBSERVER" --json --diff=working "$repo" 2>/dev/null)"
sec_head="$(echo "$out_head" | jq -r '.metrics.security_violations')"
sec_work="$(echo "$out_work" | jq -r '.metrics.security_violations')"
if [ "$sec_head" = "1" ] && [ "$sec_work" = "1" ]; then
    pass "T7 head and working both capture unstaged violation"
else
    fail "T7 head=$sec_head working=$sec_work"
fi

# T8: violations[] exists and carries blame info
vio_len="$(echo "$out_head" | jq -r '.intelligence.violations | length')"
if [ "$vio_len" -ge 1 ]; then pass "T8 violations array populated"
else fail "T8 violations len=$vio_len"; fi
vio_kind="$(echo "$out_head" | jq -r '.intelligence.violations[0].kind')"
vio_blame="$(echo "$out_head" | jq -r '.intelligence.violations[0].blame.commit')"
[ "$vio_kind" = "security" ]     && pass "T8a first violation kind=security" || fail "T8a kind=$vio_kind"
[ "$vio_blame" = "uncommitted" ] && pass "T8b blame marks new violation as uncommitted" || fail "T8b blame=$vio_blame"

# T9: --staged mode label round-trips through the JSON
out_s="$("$OBSERVER" --json --staged "$repo" 2>/dev/null)"
mode="$(echo "$out_s" | jq -r '.diff_mode')"
if [ "$mode" = "staged" ]; then pass "T9 diff_mode=staged round-trips"
else fail "T9 mode=$mode"; fi

rm -rf "$repo"

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
