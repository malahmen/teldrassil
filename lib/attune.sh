# shellcheck shell=bash
# lib/attune.sh — attune: grant bots the raid attunements they cannot earn.
#
# Molten Core, Blackwing Lair and Naxxramas check a completed quest at the
# door; bots never pursue those chains, and their dungeon steps need a group
# bots do not form. The rules - the roster's "attunements", or defaults in
# lib/teldrassil.py - say what a bot must reach instead: a level, and for
# Naxxramas a reputation. Bots only; players earn theirs.
#
# A character's quest log lives in the world server's memory, so the grant is
# written with it stopped.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

cmd_attune() {
    local sub="${1:-}"; [[ $# -gt 0 ]] && shift
    local file="$ROSTER_FILE" yes=0 d was_running=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) _need_value "$@"; file="$2"; shift 2 ;;
        --yes) yes=1; shift ;;
        *) error_exit "attune: unknown flag $1" ;;
    esac; done
    [[ "$sub" == plan || "$sub" == apply ]] || error_exit "Usage: attune plan|apply [--file ROSTER] [--yes]"
    [[ -z "$file" || -r "$file" ]] || error_exit "Cannot read the roster ${file}."
    local -a roster=(); [[ -n "$file" ]] && roster=(--roster "$file")
    _require_db
    d="$(tmp_dir)"

    _attune_plan() {
        helper attune-sql "${roster[@]}" --chars "$DB_CHARACTERS" --realmd "$DB_REALMD" --prefix "$BOT_ACCOUNT_PREFIX" | _db_raw > "$d/attune.json"
        helper attune-plan "${roster[@]}" --state "$d/attune.json" --out-sql "$d/attune.sql"
    }

    if [[ "$sub" == plan || $yes -eq 0 ]]; then
        _save_world || true
        _attune_plan
        [[ "$sub" == apply ]] && info "Granting stops the world server for about a minute. Re-run with --yes."
        return 0
    fi

    _container_running "$SERVER_CONTAINER" && was_running=1
    _stop
    _attune_plan
    if [[ -s "$d/attune.sql" ]]; then
        if ! { printf 'USE `%s`;\n' "$DB_CHARACTERS"; cat -- "$d/attune.sql"; } | _db_raw; then
            if (( was_running )); then _start; fi
            error_exit "The database refused the grants; nothing was written."
        fi
        success "Granted ($(grep -c '^INSERT' "$d/attune.sql") attunement(s), one transaction)."
    else
        success "No bot is due an attunement."
    fi
    (( was_running )) && _start
    return 0
}
