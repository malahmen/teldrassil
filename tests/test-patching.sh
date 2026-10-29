#!/usr/bin/env bash
# _apply, pulled out of lib/provision.sh and run against throwaway git
# repositories: a patch to playerbots must be detected honestly whether
# playerbots is its own checkout or a subfolder of a bigger repository
# (kalimdor). In a subfolder, plain `git apply` skips every file outside it, so
# the patch became empty and an unpatched tree read as "already applied".
# Then _patch's own report.
# shellcheck disable=SC2034  # out/rc and PATCH_DIR are read by the code chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${TEST_DIR}/../lib/provision.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eval "$(sed -n '/^_apply() {/,/^}/p' "$SRC")"
declare -F _apply >/dev/null || { echo "no _apply in $SRC"; exit 1; }

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# A playerbots-like tree and a patch written relative to it.
mk_tree() { mkdir -p "$1/playerbot"; printf 'line one\nline two\n' > "$1/playerbot/x.cpp"; }
mkdir -p "$T/orig"; mk_tree "$T/orig"; g -C "$T/orig" init -q; g -C "$T/orig" add -A; g -C "$T/orig" commit -qm base
printf 'line one\nline 2\n' > "$T/orig/playerbot/x.cpp"; g -C "$T/orig" diff > "$T/fix.patch"
[[ -s "$T/fix.patch" ]] || { echo "could not make the patch"; exit 1; }

state() {   # state <dir> -> "applied", "clean" or "neither"
    if _apply "$1" --reverse --check "$T/fix.patch" 2>/dev/null; then echo applied
    elif _apply "$1" --check "$T/fix.patch" 2>/dev/null; then echo clean
    else echo neither; fi
}

printf '\n== playerbots as its own checkout\n'
mkdir -p "$T/solo"; mk_tree "$T/solo"; g -C "$T/solo" init -q
chk "an unpatched tree reads clean"       '[[ "$(state "$T/solo")" == clean ]]'
_apply "$T/solo" "$T/fix.patch"
chk "after applying, it reads applied"    '[[ "$(state "$T/solo")" == applied ]]'

printf '\n== playerbots as a subfolder of a bigger repository (kalimdor)\n'
mkdir -p "$T/kal/playerbots" "$T/kal/other"; mk_tree "$T/kal/playerbots"; echo x > "$T/kal/other/y"
g -C "$T/kal" init -q; g -C "$T/kal" add -A; g -C "$T/kal" commit -qm import
chk "an unpatched subfolder reads clean, not applied" '[[ "$(state "$T/kal/playerbots")" == clean ]]'
chk "plain git apply would have lied (both checks pass)" 'git -C "$T/kal/playerbots" apply --reverse --check "$T/fix.patch" 2>/dev/null && git -C "$T/kal/playerbots" apply --check "$T/fix.patch" 2>/dev/null'
_apply "$T/kal/playerbots" "$T/fix.patch"
chk "after applying, the file really changed" 'grep -qx "line 2" "$T/kal/playerbots/playerbot/x.cpp"'
chk "and it reads applied"                 '[[ "$(state "$T/kal/playerbots")" == applied ]]'
chk "nothing outside the subfolder moved"  '[[ "$(cat "$T/kal/other/y")" == x ]]'

# _patch, with the messages it prints kept.
eval "$(sed -n -e '/^_patch() {/,/^}/p' "$SRC")"
info() { echo "info: $*"; }; success() { echo "ok: $*"; }; warn() { echo "warn: $*"; }
error_exit() { echo "error: $*"; exit 1; }
mkdir -p "$T/patches/playerbots"; cp "$T/fix.patch" "$T/patches/playerbots/0001-fix.patch"
PATCH_DIR="$T/patches"

printf '\n== _patch says what it did, and did it (Kamino 192)\n'
# kalimdor-like: one repository, playerbots a subfolder.
mk_origin() {   # mk_origin <dir> [committed] — with the patch committed, or not
    rm -rf "$1"; mkdir -p "$1/mangos-classic" "$1/classic-db"; mk_tree "$1/playerbots"
    g -C "$1" init -q; g -C "$1" add -A; g -C "$1" commit -qm import
    if [[ "${2:-}" == committed ]]; then
        g -C "$1/playerbots" apply --directory=playerbots "$T/fix.patch"; g -C "$1" commit -qam "teldrassil's patches"
    fi
}
mk_origin "$T/kal-origin"
g clone -q "$T/kal-origin" "$T/src"
SRC_PB="$T/src/playerbots"
out="$(_patch 2>&1)"
chk "a clean tree: 'applied'"                       '[[ "$out" == *"Patch 0001-fix.patch: applied"* ]]'
chk "  and the file really changed"                 'grep -qx "line 2" "$SRC_PB/playerbot/x.cpp"'
out="$(_patch 2>&1)"
chk "again: 'already applied', nothing changes"     '[[ "$out" == *"0001-fix.patch: already applied"* ]] && [[ "$(grep -c "line 2" "$SRC_PB/playerbot/x.cpp")" == 1 ]]'
printf 'line one\nsomething else\n' > "$SRC_PB/playerbot/x.cpp"
out="$( (_patch) 2>&1)"; rc=$?
chk "a tree it does not fit: an error, not 'applied'" '[[ $rc -ne 0 && "$out" == *"does not apply"* && "$out" != *"applied."* ]]'
g -C "$T/src" checkout -q -- .

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
