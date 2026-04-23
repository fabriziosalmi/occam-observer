#!/usr/bin/env bash
# Smoke test for the ./occam convenience CLI: version, doctor, help,
# start→status→stop lifecycle, analyze/check wiring, clean.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCCAM="${SCRIPT_DIR}/occam"

command -v go  >/dev/null || { echo "SKIP: go required"  >&2; exit 0; }
command -v jq  >/dev/null || { echo "SKIP: jq required"  >&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  ./occam CLI — smoke"
echo "────────────────────────────────────────────────────────────"

# Isolate everything under a temp runtime + DB so we don't touch real state.
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/occam_cli_rt_XXXXXX)"
export XDG_DATA_HOME="$(mktemp -d /tmp/occam_cli_data_XXXXXX)"
export OCCAM_PORT=$((40000 + RANDOM % 20000))

cleanup() {
    "$OCCAM" stop >/dev/null 2>&1 || true
    rm -rf "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"
}
trap cleanup EXIT

# ── T1: ./occam version ──────────────────────────────────────────────────────
v="$("$OCCAM" version)"
if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "T1 ./occam version → $v"
else
    fail "T1 version='$v'"
fi

# ── T2: ./occam help shows all commands ──────────────────────────────────────
help="$("$OCCAM" help)"
for cmd in start stop status restart logs analyze check ui doctor clean mcp; do
    [[ "$help" == *"./occam $cmd"* ]] || { fail "T2 help missing: $cmd"; continue; }
done
pass "T2 help mentions every command"

# ── T3: unknown command → non-zero exit ──────────────────────────────────────
"$OCCAM" nonsense >/dev/null 2>&1
if [ $? -ne 0 ]; then pass "T3 unknown command → non-zero exit"
else fail "T3 unknown command returned 0"; fi

# ── T4: doctor runs without crashing ─────────────────────────────────────────
"$OCCAM" doctor >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "T4 ./occam doctor exits 0"
else fail "T4 doctor failed"; fi

# ── T5: lifecycle start → status → stop ─────────────────────────────────────
"$OCCAM" stop >/dev/null 2>&1 || true   # belt and braces
"$OCCAM" start >/dev/null 2>&1
if [ $? -eq 0 ] && [ -f "$XDG_RUNTIME_DIR/occam-gateway.pid" ]; then
    pass "T5 ./occam start creates pid file"
else
    fail "T5 start failed"
fi

# Status should report running
status_out="$("$OCCAM" status 2>&1)"
if [[ "$status_out" == *"running"* ]] && [[ "$status_out" == *"port=${OCCAM_PORT}"* ]]; then
    pass "T5a status reports running + port"
else
    fail "T5a status=$status_out"
fi

# Healthz should answer
if curl -sf "http://127.0.0.1:${OCCAM_PORT}/healthz" >/dev/null 2>&1; then
    pass "T5b gateway responds on /healthz"
else
    fail "T5b gateway unreachable"
fi

# ── T6: analyze via CLI ──────────────────────────────────────────────────────
# Make a throwaway git repo
repo="$(mktemp -d /tmp/occam_cli_repo_XXXXXX)"
git -C "$repo" init -q
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name  t
echo seed > "$repo/s.txt"
git -C "$repo" add . >/dev/null
git -C "$repo" commit -q -m init

analyze_out="$("$OCCAM" analyze "$repo" 2>/dev/null)"
v="$(echo "$analyze_out" | jq -r '.version' 2>/dev/null || echo '')"
if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "T6 ./occam analyze emits JSON (version=$v)"
else
    fail "T6 analyze output malformed"
fi

# ── T7: check command exits 0 on clean repo ──────────────────────────────────
"$OCCAM" check "$repo" high >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "T7 ./occam check clean → exit 0"
else fail "T7 exit $?"; fi

# With a critical violation, exit 1
echo 'API_KEY = "leaked"' >> "$repo/s.txt"
"$OCCAM" check "$repo" high >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "T7a ./occam check w/ critical → exit 1"
else fail "T7a expected 1, got $?"; fi

rm -rf "$repo"

# ── T8: logs has content ─────────────────────────────────────────────────────
logs="$("$OCCAM" logs 2>&1)"
if [ -n "$logs" ]; then pass "T8 ./occam logs has content"
else fail "T8 logs empty"; fi

# ── T9: stop removes pid file ────────────────────────────────────────────────
"$OCCAM" stop >/dev/null 2>&1
if [ ! -f "$XDG_RUNTIME_DIR/occam-gateway.pid" ]; then
    pass "T9 ./occam stop removes pid file"
else
    fail "T9 pid file still present"
fi

# Double stop should be graceful (no crash)
"$OCCAM" stop >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "T9a second stop is graceful"
else fail "T9a exit $?"; fi

# ── T10: clean runs ──────────────────────────────────────────────────────────
"$OCCAM" clean >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "T10 ./occam clean exits 0"
else fail "T10 clean failed"; fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
