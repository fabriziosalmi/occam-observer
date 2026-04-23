#!/usr/bin/env bash
# run_tests.sh — unified test runner.
#
# Runs every *.sh test file matching tests/*.sh. Each test's stdout is shown
# live; pass/fail is aggregated into a final summary. Non-zero exit from any
# test marks the whole run as FAIL.
#
# Skips legacy interactive ad-hoc stubs: test_borders.sh, test_http_parser.sh,
# test_grep.sh, test_sec.sh, test_yaml_fsm.sh (they were exploration scripts,
# not regression tests — kept in-tree for forensic reference).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TESTS=()
if [ -d tests ]; then
    for f in tests/*.sh; do
        [ -f "$f" ] && TESTS+=("$f")
    done
fi

if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "no tests found" >&2
    exit 1
fi

PASS=0; FAIL=0; FAILED_NAMES=()

printf '\n═══ Occam Observer — unified test run ═══\n'
printf '  discovered %d test file(s)\n\n' "${#TESTS[@]}"

for t in "${TESTS[@]}"; do
    printf '\n──── %s ────\n' "$t"
    if bash "$t"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_NAMES+=("$t")
    fi
done

# Go modules — best-effort.
if command -v go >/dev/null 2>&1; then
    for mod in api mcp; do
        [ -f "$mod/go.mod" ] || continue
        printf '\n──── go vet + build (%s/) ────\n' "$mod"
        if (cd "$mod" && go vet ./... && go build -o "/tmp/occam_${mod}_test" .); then
            printf '  ✓ go vet + build (%s)\n' "$mod"
            PASS=$((PASS+1))
            rm -f "/tmp/occam_${mod}_test"
        else
            printf '  ✗ go vet or build (%s)\n' "$mod"
            FAIL=$((FAIL+1))
            FAILED_NAMES+=("go-build-$mod")
        fi
    done
fi

# bash -n on the engine — cheap parse check.
printf '\n──── bash -n telemetry_observer.sh ────\n'
if bash -n telemetry_observer.sh; then
    printf '  ✓ parse clean\n'
    PASS=$((PASS+1))
else
    printf '  ✗ parse errors\n'
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("bash-parse")
fi

# Config validation — exercise --validate path.
printf '\n──── ./telemetry_observer.sh --validate ────\n'
if ./telemetry_observer.sh --validate >/dev/null 2>&1; then
    printf '  ✓ shipped config validates\n'
    PASS=$((PASS+1))
else
    printf '  ✗ shipped config does not validate\n'
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("config-validate")
fi

printf '\n════════════════════════════════════════════════════════════\n'
printf '  passed=%d  failed=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  failures: %s\n' "${FAILED_NAMES[*]}"
    printf '════════════════════════════════════════════════════════════\n'
    exit 1
fi
printf '════════════════════════════════════════════════════════════\n'
