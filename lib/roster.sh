# shellcheck shell=bash
# lib/roster.sh — The roster (shaped bots, their guilds, cards, the LLM and
# population settings) and playerbots' command list: roster check, plan,
# apply, show; commands.
#
# The roster logic lives in lib/teldrassil.py; this file moves data between it,
# the database and the server, in the order that is safe: guilds and
# characters are held in the world server's memory, so the database is only
# written while it is stopped.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

_roster_file() {
    local f="${1:-$ROSTER_FILE}"
    [[ -n "$f" ]] || error_exit "No roster: pass --file FILE, or set ROSTER_FILE."
    [[ -r "$f" ]] || error_exit "Cannot read the roster ${f}."
    printf '%s' "$f"
}

_require_bot_conf() {
    [[ -n "$BOT_CONF" ]] || error_exit "Where is aiplayerbot.conf? Set ETC_DIR (or BOT_CONF)."
    [[ -r "$BOT_CONF" ]] || error_exit "Cannot read ${BOT_CONF}."
}

# _roster_state <out> — the database state a plan needs, as JSON. Saves the
# world first when it is running, so what the database says is current.
_roster_state() {
    _save_world || true
    helper state-sql --chars "$DB_CHARACTERS" --realmd "$DB_REALMD" --prefix "$BOT_ACCOUNT_PREFIX" | _db_raw > "$1"
}

# _roster_plan <roster> <dir> — run the plan; leaves plan.sql, plan.conf,
# plan.cards and plan.upgrade in <dir> (each empty when there is nothing).
_roster_plan() {
    local roster="$1" d="$2"
    helper plan "$roster" --state "$d/state.json" --conf "$BOT_CONF" \
        --cards "${CARDS_FILE:-/nonexistent}" --cards-in-server "$CARDS_FILE_IN_SERVER" \
        --out-sql "$d/plan.sql" --out-conf "$d/plan.conf" --out-cards "$d/plan.cards" --out-upgrade "$d/plan.upgrade"
}

_roster_flags() {
    R_FILE=""; R_YES=0; R_FRESH=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) _need_value "$@"; R_FILE="$2"; shift 2 ;;
        --yes) R_YES=1; shift ;;
        --fresh-population) R_FRESH=1; shift ;;
        *) error_exit "roster: unknown flag $1" ;;
    esac; done
}

cmd_roster() {
    local sub="${1:-}"; [[ $# -gt 0 ]] && shift
    case "$sub" in
        check) _roster_flags "$@"; helper check "$(_roster_file "$R_FILE")" ;;
        plan)  _roster_flags "$@"; _roster_cmd_plan ;;
        apply) _roster_flags "$@"; _roster_cmd_apply ;;
        show)  _roster_flags "$@"; _roster_cmd_show ;;
        *) error_exit "Usage: roster check|plan|show|apply [--file FILE] [--yes] [--fresh-population]" ;;
    esac
}

_roster_cmd_plan() {
    local roster d; roster="$(_roster_file "$R_FILE")"; d="$(tmp_dir)"
    _require_db; _require_bot_conf
    helper check "$roster" >/dev/null
    _roster_state "$d/state.json"
    _roster_plan "$roster" "$d"
}

_roster_cmd_show() {
    local roster d; roster="$(_roster_file "$R_FILE")"; d="$(tmp_dir)"
    _require_db
    _roster_state "$d/state.json"
    helper show "$roster" --state "$d/state.json"
}

# _backup <file> — a timestamped copy under BACKUP_DIR before it is replaced.
_backup() {
    [[ -f "$1" ]] || return 0
    _mkdir_private "$BACKUP_DIR"
    cp -p -- "$1" "${BACKUP_DIR}/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
}

# _replace <new> <target> — put a generated file in place, keeping a backup.
_replace() {
    [[ -s "$1" ]] || return 0
    _backup "$2"
    cat -- "$1" > "$2"
}

# _fresh_population <roster> — replace every random bot: the roster's counts
# and the delete flags in aiplayerbot.conf, one start to recreate them, then
# the flags off again. Bot guilds go too; the roster recreates its own.
_fresh_population() {
    local roster="$1" d; d="$(tmp_dir)"
    local total; total="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("population",{}).get("bots",""))' "$roster")"
    [[ "$total" =~ ^[0-9]+$ ]] || error_exit "--fresh-population needs a 'population' section with 'bots' in the roster."
    header "Fresh population: ${total} new bots"
    warn "Every random bot and every guild a bot leads is deleted and recreated."
    _stop
    helper conf --conf "$BOT_CONF" --out "$d/fresh.conf" --roster "$roster" --cards-in-server "$CARDS_FILE_IN_SERVER" \
        --set AiPlayerbot.DeleteRandomBotAccounts=1 --set AiPlayerbot.DeleteRandomBotGuilds=1 >/dev/null
    _replace "$d/fresh.conf" "$BOT_CONF"
    _start
    _wait_bots "$total" || warn "Carrying on with the bots that did log in."
    _stop
    helper conf --conf "$BOT_CONF" --out "$d/after.conf" \
        --set AiPlayerbot.DeleteRandomBotAccounts=0 --set AiPlayerbot.DeleteRandomBotGuilds=0 >/dev/null
    cat -- "$d/after.conf" > "$BOT_CONF"
    success "New population created; the delete flags are off again."
}

_roster_cmd_apply() {
    local roster d was_running=0 n
    roster="$(_roster_file "$R_FILE")"; d="$(tmp_dir)"
    _require_db; _require_bot_conf
    [[ -n "$CARDS_FILE" ]] || error_exit "Where does the card file go? Set ETC_DIR (or CARDS_FILE)."
    helper check "$roster" >/dev/null
    _container_running "$SERVER_CONTAINER" && was_running=1

    if (( ! R_YES )); then
        header "Plan (nothing is changed without --yes)"
        _roster_state "$d/state.json"
        _roster_plan "$roster" "$d"
        (( R_FRESH )) && warn "With --fresh-population, every random bot would first be replaced."
        echo
        info "Applying stops the world server (everyone is disconnected for about a minute). Re-run with --yes."
        return 0
    fi

    (( R_FRESH )) && _fresh_population "$roster"

    header "Stop, so the database can be written"
    _stop
    _roster_state "$d/state.json"
    header "Plan"
    _roster_plan "$roster" "$d"

    if [[ ! -s "$d/plan.sql" && ! -s "$d/plan.conf" && ! -s "$d/plan.cards" ]]; then
        success "The server already matches the roster."
    else
        header "Apply"
        if [[ -s "$d/plan.sql" ]]; then
            _db_raw < "$d/plan.sql"
            success "Database written ($(grep -cvE '^(START TRANSACTION|COMMIT);$' "$d/plan.sql") statements, one transaction)."
        fi
        if [[ -s "$d/plan.conf" ]]; then _replace "$d/plan.conf" "$BOT_CONF"; success "aiplayerbot.conf updated (old copy in ${BACKUP_DIR})."; fi
        if [[ -s "$d/plan.cards" ]]; then _replace "$d/plan.cards" "$CARDS_FILE"; success "Card file written."; fi
    fi

    if (( was_running || R_FRESH )) || [[ -s "$d/plan.sql" || -s "$d/plan.conf" || -s "$d/plan.cards" ]]; then
        header "Start"
        _start
    fi
    if [[ -s "$d/plan.upgrade" ]]; then
        helper names "$roster" > "$d/names"
        n="$(wc -l < "$d/names")"
        _wait_bots "$n" "$d/names" || true
        header "Professions"
        local -a cmds=()
        while IFS= read -r name; do cmds+=("rndbot upgrade ${name}"); done < "$d/plan.upgrade"
        _ra "${cmds[@]}" | grep -E 'applied|not found|error' || true
        _ra --quiet saveall >/dev/null || true
        success "Professions applied to $(wc -l < "$d/plan.upgrade") bot(s)."
    fi
}

cmd_commands() {
    local any=0 search="" verbose=0 d; d="$(tmp_dir)"
    while [[ $# -gt 0 ]]; do case "$1" in
        --any) any=1; shift ;;
        --search) _need_value "$@"; search="$2"; shift 2 ;;
        --verbose|-v) verbose=1; shift ;;
        *) error_exit "commands: unknown flag $1" ;;
    esac; done
    _require_db
    printf '%s\n' "SET SESSION group_concat_max_len = 268435456; SELECT JSON_ARRAYAGG(JSON_ARRAY(name, template_text)) FROM ${DB_WORLD}.ai_playerbot_help_texts WHERE name='strategy:chat' OR name LIKE 'action:%' OR name LIKE 'trigger:%';" \
        | _db_raw > "$d/help.json"
    local -a flags=(--help-json "$d/help.json")
    (( any )) && flags+=(--any)
    (( verbose )) && flags+=(--verbose)
    [[ -n "$search" ]] && flags+=(--search "$search")
    printf '%-28s %s\n' "COMMAND" "WHO (anyone, or only the bot's master)"
    helper commands "${flags[@]}"
}
