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
    _bots_pull
    [[ -n "$BOT_CONF" ]] || error_exit "Where is aiplayerbot.conf? Set ETC_DIR (or BOT_CONF)."
    [[ -r "$BOT_CONF" ]] || error_exit "Cannot read ${BOT_CONF}."
}

# _roster_state <out> — the database state a plan needs, as JSON. Saves the
# world first when it is running, so what the database says is current.
_roster_state() {
    _save_world || true
    helper state-sql --chars "$DB_CHARACTERS" --realmd "$DB_REALMD" --prefix "$BOT_ACCOUNT_PREFIX" | _db_raw > "$1"
}

# _roster_bindings — where the roster's guilds are bound to the server's guild
# ids (one file per profile): written by 'roster apply', so a guild the roster
# made or took over stays its own whatever it is renamed to, and a guild of
# the same name never becomes the roster's.
_roster_bindings() { printf '%s/roster-guilds%s.json' "$CONFIG_DIR" "${PROFILE:+-${PROFILE}}"; }

# _roster_plan <roster> <dir> — run the plan; leaves plan.sql, plan.conf,
# plan.cards, plan.upgrade (each empty when there is nothing) and the guild
# bindings once applied (bindings.json) in <dir>.
_roster_plan() {
    local roster="$1" d="$2"
    helper plan "$roster" --state "$d/state.json" --conf "$BOT_CONF" \
        --cards "${CARDS_FILE:-/nonexistent}" --cards-in-server "$CARDS_FILE_IN_SERVER" \
        --out-sql "$d/plan.sql" --out-conf "$d/plan.conf" --out-cards "$d/plan.cards" --out-upgrade "$d/plan.upgrade" \
        --bindings "$(_roster_bindings)" --out-bindings "$d/bindings.json"
}

# _roster_bind <dir> — record the applied plan's guild bindings.
_roster_bind() {
    local f; f="$(_roster_bindings)"
    [[ -s "$1/bindings.json" ]] || return 0
    cmp -s -- "$1/bindings.json" "$f" && return 0
    _mkdir_private "$CONFIG_DIR"
    if (umask 077; cat -- "$1/bindings.json" > "${f}.tmp") && mv -f -- "${f}.tmp" "$f"; then
        info "Roster guilds bound to their guild ids (${f})."
    else
        warn "Could not record the guild bindings in ${f}; the next apply matches guilds by name again (bot-only guilds only)."
    fi
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
# in aiplayerbot.conf, then one start with playerbots' "delete all random bot
# characters" request (a 'bot_delete' row of value 2; playerbots removes it
# itself once done) - stronger than DeleteRandomBotAccounts, which keeps any
# bot that is in a guild or someone's friend. Bot guilds go too; the roster
# recreates its own. Players' characters are on other accounts and untouched.
#
# Guild deletion is on, and random guilds off, for that one start only: if it
# does not get through it (the start fails, an error, a signal), the exit hook
# puts both settings back and withdraws a deletion request still pending, so
# no later start deletes anything.
FRESH_PENDING=0; FRESH_GUILDS=""; FRESH_DELETE=""
_fresh_population() {
    local roster="$1" d; d="$(tmp_dir)"
    local total; total="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("population",{}).get("bots",""))' "$roster")"
    [[ "$total" =~ ^[0-9]+$ ]] || error_exit "--fresh-population needs a 'population' section with 'bots' in the roster."
    header "Fresh population: ${total} new bots"
    warn "Every random bot, including the roster's own, and every guild a bot leads is deleted and recreated."
    _stop
    # No random guilds while the new bots are made: a bot that founds one in
    # the first minute leads it, and a leader cannot be taken over. They
    # form on the next start, from the bots the roster leaves.
    FRESH_GUILDS="$(_bot_conf_value RandomBotGuildCount)"; FRESH_DELETE="$(_bot_conf_value DeleteRandomBotGuilds)"
    FRESH_PENDING=1; _at_exit _fresh_on_exit
    helper conf --conf "$BOT_CONF" --out "$d/fresh.conf" --roster "$roster" --cards-in-server "$CARDS_FILE_IN_SERVER" \
        --set AiPlayerbot.DeleteRandomBotGuilds=1 --set AiPlayerbot.RandomBotGuildCount=0 >/dev/null
    _replace "$d/fresh.conf" "$BOT_CONF"
    printf '%s\n' "DELETE FROM ${DB_CHARACTERS}.ai_playerbot_random_bots WHERE event='bot_delete';" \
        "INSERT INTO ${DB_CHARACTERS}.ai_playerbot_random_bots (owner, bot, \`time\`, validIn, event, \`value\`) VALUES (0, 0, UNIX_TIMESTAMP(), 0, 'bot_delete', 2);" | _db_raw
    _start
    _wait_bot_characters "$total" || warn "Carrying on with the bots that were created."
    _stop
    _fresh_conf_restore
    FRESH_PENDING=0
    success "New population created; guild deletion off and random guilds back on (${FRESH_GUILDS:-20})."
}

# _bot_conf_value <key> — an AiPlayerbot.<key> setting as aiplayerbot.conf has it.
_bot_conf_value() {
    grep -E "^AiPlayerbot\.${1}[[:space:]]*=" "$BOT_CONF" | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true
}

# _fresh_conf_restore — guild deletion and random guilds as they were before.
_fresh_conf_restore() {
    local d; d="$(tmp_dir)"
    helper conf --conf "$BOT_CONF" --out "$d/after.conf" --set "AiPlayerbot.DeleteRandomBotGuilds=${FRESH_DELETE:-0}" \
        --set "AiPlayerbot.RandomBotGuildCount=${FRESH_GUILDS:-20}" >/dev/null
    cat -- "$d/after.conf" > "$BOT_CONF"
}

_fresh_on_exit() {
    (( FRESH_PENDING )) || return 0
    warn "The fresh population did not finish: putting aiplayerbot.conf's guild settings back and withdrawing the deletion request."
    _fresh_conf_restore
    info "aiplayerbot.conf: DeleteRandomBotGuilds=${FRESH_DELETE:-0}, RandomBotGuildCount=${FRESH_GUILDS:-20} again."
    printf '%s\n' "DELETE FROM ${DB_CHARACTERS}.ai_playerbot_random_bots WHERE event='bot_delete';" | _db_raw
    info "No 'delete every random bot' request is left for a later start."
}

# _wait_bot_characters <count> — until that many characters exist on bot
# accounts: the plan needs them to exist, not to be online.
_wait_bot_characters() {
    local want="$1" deadline=$((SECONDS + BOTS_TIMEOUT)) n
    info "Waiting for ${want} bot characters to be created (up to ${BOTS_TIMEOUT}s)..."
    while (( SECONDS < deadline )); do
        n="$(_db_value "SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters c JOIN ${DB_REALMD}.account a ON a.id=c.account WHERE a.username LIKE '${BOT_ACCOUNT_PREFIX}%';")"
        if [[ "${n:-0}" -ge "$want" ]]; then success "${n} bot characters."; return 0; fi
        sleep 5
    done
    warn "Only ${n:-0} of ${want} bot characters after ${BOTS_TIMEOUT}s."
    return 1
}

_roster_cmd_apply() {
    local roster d was_running=0 n
    roster="$(_roster_file "$R_FILE")"; d="$(tmp_dir)"
    _require_db; _require_bot_conf
    [[ -n "$CARDS_FILE" ]] || error_exit "Where does the card file go? Set ETC_DIR (or CARDS_FILE)."
    helper check "$roster" >/dev/null
    _server_running && was_running=1

    if (( ! R_YES )); then
        header "Plan (nothing is changed without --yes)"
        _roster_state "$d/state.json"
        _roster_plan "$roster" "$d"
        (( R_FRESH )) && warn "With --fresh-population, every random bot would first be replaced."
        echo
        info "Applying stops the world server (everyone is disconnected for about a minute). Re-run with --yes."
        return 0
    fi

    # A plan that cannot be made (a guild that is not the roster's to take
    # over, a missing bot) is found before anything stops.
    if (( ! R_FRESH )); then
        _roster_state "$d/state.json"
        _roster_plan "$roster" "$d" >/dev/null || error_exit "Nothing was changed; the server was left as it was."
    fi

    # From here the server is stopped: whatever fails - the state query, the
    # plan, the transaction, a signal - one that was running is started again
    # on the way out (and a fresh population's settings are put back first).
    (( was_running )) && _restart_arm
    (( R_FRESH )) && _fresh_population "$roster"

    header "Stop, so the database can be written"
    _stop
    _roster_state "$d/state.json"
    header "Plan"
    _roster_plan "$roster" "$d" || error_exit "Nothing was changed."

    if [[ ! -s "$d/plan.sql" && ! -s "$d/plan.conf" && ! -s "$d/plan.cards" ]]; then
        success "The server already matches the roster."
    else
        header "Apply"
        if [[ -s "$d/plan.sql" ]]; then
            # The plan names tables, not databases. A failed statement ends
            # the session, and MariaDB rolls the transaction back: nothing is
            # half-written - and the exit hook starts the server again.
            if ! { printf 'USE `%s`;\n' "$DB_CHARACTERS"; cat -- "$d/plan.sql"; } | _db_raw; then
                error_exit "The database refused the plan; nothing was written."
            fi
            success "Database written ($(grep -cvE '^(START TRANSACTION|COMMIT);$' "$d/plan.sql") statements, one transaction)."
        fi
        if [[ -s "$d/plan.conf" ]]; then _replace "$d/plan.conf" "$BOT_CONF"; success "aiplayerbot.conf updated (old copy in ${BACKUP_DIR})."; fi
        if [[ -s "$d/plan.cards" ]]; then _replace "$d/plan.cards" "$CARDS_FILE"; success "Card file written."; fi
    fi
    _roster_bind "$d"

    if (( was_running || R_FRESH )) || [[ -s "$d/plan.sql" || -s "$d/plan.conf" || -s "$d/plan.cards" ]]; then
        header "Start"
        _restart_disarm
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
