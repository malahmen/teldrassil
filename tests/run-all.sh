#!/usr/bin/env bash
# Every test: the helper's unit tests, then each tests/test-*.sh. No network,
# no database, no containers: tests/stubs shadows podman, and each shell test
# works in its own XDG_CONFIG_HOME under a temporary directory.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
if out=$(python3 "$TEST_DIR/test_helper.py" 2>&1); then
    printf 'PASS  %-24s %s\n' "test_helper.py" "$(grep -oE 'Ran [0-9]+ tests' <<<"$out")"
else
    printf 'FAIL  test_helper.py\n'; sed 's/^/        /' <<<"$out" | tail -20; failed+=(test_helper.py)
fi
for t in "$TEST_DIR"/test-*.sh; do
    name=$(basename "$t")
    if out=$(bash "$t" </dev/null 2>&1); then
        printf 'PASS  %-24s %s\n' "$name" "$(grep -oE 'pass=[0-9]+ fail=[0-9]+' <<<"$out" | tail -1)"
    else
        printf 'FAIL  %s\n' "$name"; grep -E 'FAIL' <<<"$out" | sed 's/^/        /'; failed+=("$name")
    fi
done
echo
if (( ${#failed[@]} )); then echo "${#failed[@]} failed: ${failed[*]}"; exit 1; fi
echo "all tests passed"
