#!/usr/bin/env bash
# Regression coverage for validate_target: when git refuses a repo, the engine
# reports git's own error instead of the misleading "Repo has no commits".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="${SCRIPT_DIR}/telemetry_observer.sh"

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  validate_target: git errors are reported as git reports them"
echo "────────────────────────────────────────────────────────────"

tmp="$(mktemp -d /tmp/occam_giterr_XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# T1: an empty repo is still reported as having no commits.
git -C "$tmp" init -q empty
err="$("$OBSERVER" --json "$tmp/empty" 2>&1 >/dev/null)"; ec=$?
if [ "$ec" -ne 0 ] && [[ "$err" == *"Repo has no commits"* ]]; then
    pass "T1 empty repo -> 'no commits' (exit=$ec)"
else
    fail "T1 exit=$ec err=$err"
fi

# T2: a repo git refuses (dubious ownership, as with a container mount owned
# by another uid) surfaces git's error, not "no commits". Git's own test
# switch simulates the foreign owner without needing root.
git -C "$tmp" init -q owned
git -C "$tmp/owned" -c user.email=t@t.local -c user.name=Tester \
    commit -q --allow-empty -m init
if GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$tmp/owned" rev-parse --git-dir >/dev/null 2>&1; then
    printf "  - T2 skipped: this git ignores GIT_TEST_ASSUME_DIFFERENT_OWNER\n"
else
    err="$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$OBSERVER" --json "$tmp/owned" 2>&1 >/dev/null)"; ec=$?
    if [ "$ec" -ne 0 ] && [[ "$err" == *"dubious ownership"* ]] && [[ "$err" != *"no commits"* ]]; then
        pass "T2 refused repo -> git's 'dubious ownership' error (exit=$ec)"
    else
        fail "T2 exit=$ec err=$err"
    fi
fi

printf '\n  passed=%d  failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
