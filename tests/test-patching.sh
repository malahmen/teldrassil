#!/usr/bin/env bash
# _apply, pulled out of lib/provision.sh and run against throwaway git
# repositories: a patch to playerbots must be detected honestly whether
# playerbots is its own checkout or a subfolder of a bigger repository
# (kalimdor). In a subfolder, plain `git apply` skips every file outside it, so
# the patch became empty and an unpatched tree read as "already applied".
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

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
