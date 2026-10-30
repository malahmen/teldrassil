# shellcheck shell=bash
# lib/common.sh — Logging, the Python helper, temporary files. Sourced first.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

if [[ -t 2 ]]; then C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""; fi
info()       { printf '%s[info]%s  %s\n' "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s[ok]%s    %s\n' "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s[warn]%s  %s\n' "$C_Y" "$C_N" "$*" >&2; }
error_exit() { printf '%s[error]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }
header()     { printf '\n%s== %s ==%s\n' "$C_C" "$*" "$C_N" >&2; }

# The Python helper (lib/teldrassil.py) does what bash is a poor fit for:
# JSON, the roster plan, SRP6, the console protocol. -I: isolated mode, so
# nothing in the current directory can shadow a module it imports.
helper() { python3 -I "${SCRIPT_DIR}/lib/teldrassil.py" "$@"; }

# One private temporary directory per run, removed on exit.
TMP_DIR=""
tmp_dir() {
    if [[ -z "$TMP_DIR" ]]; then
        TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teldrassil.XXXXXX")"
        chmod 700 "$TMP_DIR"
    fi
    printf '%s' "$TMP_DIR"
}
# _at_exit <function> — something to undo or finish however the run ends: an
# error, a signal or the end. Each is a function that checks for itself
# whether there is anything to do (a command that is done disarms it). They run
# from the one EXIT trap, last registered first, each in a subshell, so one
# that fails does not stop the others.
EXIT_HOOKS=()
_at_exit() { EXIT_HOOKS+=("$1"); }
# Then a bot config pulled from a cluster's Secret and changed is written
# back (lib/target.sh); a failure there is reported, and the files are kept.
_cleanup() {
    local i
    for (( i = ${#EXIT_HOOKS[@]} - 1; i >= 0; i-- )); do
        ( "${EXIT_HOOKS[i]}" ) || warn "Could not finish '${EXIT_HOOKS[i]}' on the way out; see above."
    done
    if declare -F _bots_push >/dev/null && ! ( _bots_push ); then
        warn "The bot config was NOT written back; the changed files are in ${TMP_DIR}/bots."
        return 0
    fi
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -r -- "$TMP_DIR"
    return 0
}
trap _cleanup EXIT
trap 'echo "" >&2; warn "Interrupted."; exit 130' INT TERM

# _need_flag <flag> <value> — a flag that takes a value must be given one.
_need_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || error_exit "$1 needs a value."; }

# _mkdir_private <dir> — owner-only: the config names password files and the
# backups hold the bots' cards.
_mkdir_private() { mkdir -p "$1"; chmod 700 "$1" 2>/dev/null || true; }
