#!/bin/bash
export PATH=/usr/bin:/bin
REGEX_SECURITY="\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs)$|\.cy\.(js|jsx|ts|tsx)$|(^|/)__(tests|mocks|snapshots)__/|(^|/)(cypress|playwright)/.*\.(js|ts)$|(^|/)test_[^/]+\.py$|_test\.py$|(^|/)conftest\.py$|_test\.go$|[A-Za-z0-9_]Test(s|Case)?\.(java|kt|cs|scala)$|(^|/)src/test/|_(spec|test)\.rb$|[A-Za-z0-9_]Test\.php$|(^|/)(tests|benches)/.*\.rs$|(^|/)test_[^/]+\.(c|cpp|cc|cxx|h|hpp)$|(^|/)(tests?|specs?|testing|integration_tests?|e2e_tests?|e2e)/"
added_lines="foo
bar"
echo "Added lines:"
echo "$added_lines"
echo "Grep output:"
echo "$added_lines" | grep -ciE "$REGEX_SECURITY" || true
