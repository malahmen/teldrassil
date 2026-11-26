#!/usr/bin/env bash
# Applies teldrassil's patch stack, in order, to kalimdor's untouched import in
# a scratch worktree, and compares both trees with a kalimdor ref. Read-only
# for both repositories: the worktree is temporary and removed on exit.
#
# Usage: stack-test.sh <kalimdor checkout> <teldrassil checkout> [<kalimdor ref, default origin/main>] [<import commit, default 5ade959>]
# Exit:  0 both trees identical; 1 a patch did not apply or a tree differs.
set -euo pipefail
K="$(cd "$1" && pwd)"; T="$(cd "$2" && pwd)"
TARGET="${3:-origin/main}"; IMPORT="${4:-5ade959}"
P="$T/templates/patches"
W="$(mktemp -d)/import"
git -C "$K" worktree add -q --detach "$W" "$IMPORT"
trap 'git -C "$K" worktree remove --force "$W"' EXIT
for tree in mangos-classic playerbots; do
    n=0
    for p in "$P/$tree"/*.patch; do
        [[ -f "$p" ]] || continue
        git -C "$W/$tree" apply --whitespace=nowarn --directory="$tree" "$p" || { echo "FAIL: $tree/$(basename "$p") does not apply after $n"; exit 1; }
        n=$((n + 1))
    done
    echo "$tree: $n patches applied in order"
done
git -C "$W" add -A mangos-classic playerbots
rc=0
for tree in mangos-classic playerbots; do
    if git -C "$W" diff --cached --quiet "$TARGET" -- "$tree"; then
        echo "$tree: identical to kalimdor $TARGET ($(git -C "$K" rev-parse --short "$TARGET"))"
    else
        echo "$tree: DIFFERS from kalimdor $TARGET:"; git -C "$W" diff --cached --stat "$TARGET" -- "$tree" | tail -8; rc=1
    fi
done
exit $rc
