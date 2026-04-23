#!/usr/bin/env bash
# test_json.sh — validates that the --json mode emits RFC 8259-valid JSON
# even when the target repo contains pathological content (quotes, backslashes,
# newlines, tabs, control chars) in commit messages, paths, and diff hunks.
#
# Exit 0 on success, 1 on any failure. Requires: jq, git, bash >= 3.2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="${SCRIPT_DIR}/telemetry_observer.sh"

command -v jq >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }
[ -x "$OBSERVER" ] || { echo "FAIL: $OBSERVER not executable" >&2; exit 1; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

mk_repo() {
    local repo; repo="$(mktemp -d /tmp/occam_test_XXXXXX)"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@occam.local"
    git -C "$repo" config user.name "Test"
    echo "seed" > "$repo/seed.txt"
    git -C "$repo" add . >/dev/null
    git -C "$repo" commit -q -m "init"
    printf '%s' "$repo"
}

run_json() {
    local repo="$1"
    "$OBSERVER" --json "$repo" 2>/dev/null
}

assert_valid_json() {
    local label="$1" out="$2"
    if printf '%s' "$out" | jq empty >/dev/null 2>&1; then
        pass "$label: valid JSON"
    else
        fail "$label: INVALID JSON"
        printf '    first 400 bytes: %s\n' "$(printf '%s' "$out" | head -c 400)"
    fi
}

assert_field_contains() {
    local label="$1" out="$2" jq_expr="$3" needle="$4"
    local got
    got="$(printf '%s' "$out" | jq -r "$jq_expr" 2>/dev/null)" || {
        fail "$label: jq extract failed for $jq_expr"; return
    }
    if [[ "$got" == *"$needle"* ]]; then
        pass "$label: field contains expected substring"
    else
        fail "$label: expected '$needle' in $jq_expr, got '$got'"
    fi
}

echo "────────────────────────────────────────────────────────────"
echo "  Occam Observer — JSON robustness test"
echo "────────────────────────────────────────────────────────────"

# ── T1: baseline (clean repo, no diff) ────────────────────────────────────────
repo="$(mk_repo)"
out="$(run_json "$repo")"
assert_valid_json "T1 baseline clean" "$out"
rm -rf "$repo"

# ── T2: commit message with double quotes and backslashes ────────────────────
repo="$(mk_repo)"
# shellcheck disable=SC2016
git -C "$repo" commit --allow-empty -q -m 'evil: "quoted" \backslash and $var'
out="$(run_json "$repo")"
assert_valid_json "T2 commit msg w/ quotes+backslash" "$out"
assert_field_contains "T2" "$out" '.git.message' 'quoted'
assert_field_contains "T2" "$out" '.git.message' 'backslash'
rm -rf "$repo"

# ── T3: diff containing a literal double-quote in a code snippet ─────────────
repo="$(mk_repo)"
cat > "$repo/hack.py" <<'PYEOF'
password = "p\"ass\\word"   # TODO: rotate
API_KEY = "sk-xxx"
def evil():
    if True:
        print("hello")
PYEOF
# stage so it appears in `git diff HEAD`
git -C "$repo" add hack.py >/dev/null
out="$(run_json "$repo")"
assert_valid_json "T3 diff w/ embedded quotes+backslash" "$out"
# security_violations should be > 0 (password / API key pattern)
sec="$(printf '%s' "$out" | jq -r '.metrics.security_violations' 2>/dev/null)"
if [[ "${sec:-0}" -gt 0 ]]; then
    pass "T3 security_violations detected ($sec)"
else
    fail "T3 security_violations not detected"
fi
rm -rf "$repo"

# ── T4: diff with tab and CR characters ──────────────────────────────────────
repo="$(mk_repo)"
printf 'def f():\n\tif x:\n\t\treturn "a\\tb"\r\n' > "$repo/tabs.py"
out="$(run_json "$repo")"
assert_valid_json "T4 diff w/ tabs+CR" "$out"
rm -rf "$repo"

# ── T5: commit message with literal newline ──────────────────────────────────
repo="$(mk_repo)"
git -C "$repo" commit --allow-empty -q -m "$(printf 'multi\nline\nmsg')"
out="$(run_json "$repo")"
assert_valid_json "T5 multi-line commit message" "$out"
# jq -r will collapse \n → newline; re-encoding round-trip must still be valid.
msg="$(printf '%s' "$out" | jq -r '.git.message' 2>/dev/null || true)"
if [[ -n "$msg" ]]; then
    pass "T5 message extractable"
else
    fail "T5 message not extractable"
fi
rm -rf "$repo"

# ── T6: branch name with odd but legal characters ────────────────────────────
repo="$(mk_repo)"
git -C "$repo" checkout -q -b 'feat/weird-#42'
out="$(run_json "$repo")"
assert_valid_json "T6 branch name w/ # and /" "$out"
assert_field_contains "T6" "$out" '.branch' 'feat/weird-#42'
rm -rf "$repo"

# ── T7: headless mode should NOT leak /tmp cache file after exit ─────────────
# (mktemp is used; analyze_and_json rm -f's it at the end)
before="$(ls /tmp/occam_json_* 2>/dev/null | wc -l | tr -d ' ')"
repo="$(mk_repo)"
run_json "$repo" >/dev/null
after="$(ls /tmp/occam_json_* 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$before" == "$after" ]]; then
    pass "T7 no stray cache file left in /tmp"
else
    fail "T7 cache leak: before=$before after=$after"
fi
rm -rf "$repo"

# ── T8: cache file permissions are 0600 ──────────────────────────────────────
repo="$(mk_repo)"
probe_out="$(bash -c '
    set +e
    source "$1"
    TARGET_PATH="$2"
    CACHE_FILE="$(mktemp /tmp/occam_perm_check_XXXXXX.json)"
    write_cache "false" "main" "0000000" "$(date "+%Y-%m-%dT%H:%M:%S%z")" \
        0 0 0 0 0 0 0 100 "" "" "{}" "{}"
    stat -f "%Lp" "$CACHE_FILE" 2>/dev/null || stat -c "%a" "$CACHE_FILE" 2>/dev/null
    rm -f "$CACHE_FILE"
' _ "$OBSERVER" "$repo" 2>/dev/null)"
if [[ "$probe_out" == "600" ]]; then
    pass "T8 cache file is 0600"
else
    fail "T8 cache perms: got '$probe_out' want '600'"
fi
rm -rf "$repo"

# ── T9: targeted json_escape_str unit check ──────────────────────────────────
probe="$(bash -c '
    source "$1"
    json_escape_str "$2"
' _ "$OBSERVER" $'a"b\\c\nd\te' 2>/dev/null)"
expected='a\"b\\c\nd\te'
if [[ "$probe" == "$expected" ]]; then
    pass "T9 json_escape_str: quote/backslash/newline/tab"
else
    fail "T9 json_escape_str mismatch: got '$probe' want '$expected'"
fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[[ $FAIL -eq 0 ]] || exit 1
