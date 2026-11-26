#!/usr/bin/env bash
# Writes teldrassil's next patch(es) for one merged kalimdor PR: the diff of
# the merge against its first parent, per tree, relative to the tree - the
# form teldrassil applies (git apply --directory=<tree>). A tree the merge did
# not touch gets no patch.
#
# Usage: new-patch.sh <kalimdor checkout> <teldrassil checkout> <merge commit> <slug>
#   e.g. new-patch.sh ../kalimdor . 25dc689 group-queue
#        -> templates/patches/playerbots/0053-group-queue.patch (the next number)
set -euo pipefail
K="$(cd "$1" && pwd)"; T="$(cd "$2" && pwd)"; M="$3"; SLUG="$4"
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "slug: lowercase words and dashes"; exit 1; }
git -C "$K" rev-parse --verify -q "$M^2" >/dev/null || echo "note: $M has one parent - not a merge; diffing it against its parent"
for tree in playerbots mangos-classic; do
    dir="$T/templates/patches/$tree"
    if git -C "$K" diff --quiet "$M^1" "$M" -- "$tree"; then
        echo "$tree: untouched by $M - no patch"; continue
    fi
    last="$(ls "$dir"/*.patch 2>/dev/null | sed -E 's|.*/([0-9]{4})-.*|\1|' | sort -n | tail -1)"
    next="$(printf '%04d' $((10#${last:-0} + 1)))"
    out="$dir/$next-$SLUG.patch"
    git -C "$K" diff --binary --relative="$tree" "$M^1" "$M" -- "$tree" > "$out"
    echo "$tree: $(basename "$out") ($(grep -c '^diff --git' "$out") files)"
done
