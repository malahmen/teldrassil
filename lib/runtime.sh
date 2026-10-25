# shellcheck shell=bash
# lib/runtime.sh — The database, the containers and the remote console:
# start, stop, restart, status, save and console.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

# -----------------------------------------------------------------------------
# The database. SQL always goes in on stdin and the password is read inside
# the container from DB_PASS_FILE, so neither reaches a command line.
# -----------------------------------------------------------------------------

# _db_raw — run stdin's SQL; tab-separated rows, no headers, no escaping.
_db_raw() {
    # shellcheck disable=SC2016  # $1/$2 are the inner shell's, by design
    "$PODMAN" exec -i "$DB_CONTAINER" sh -c 'MYSQL_PWD="$(cat "$1")" exec mariadb -u"$2" -N -B -r' _ "$DB_PASS_FILE" "$DB_USER"
}
# _db_table — the same, as a table for people to read.
_db_table() {
    # shellcheck disable=SC2016
    "$PODMAN" exec -i "$DB_CONTAINER" sh -c 'MYSQL_PWD="$(cat "$1")" exec mariadb -u"$2" -t' _ "$DB_PASS_FILE" "$DB_USER"
}
# _db_value <sql> — one value.
_db_value() { printf '%s\n' "$1" | _db_raw | head -1; }
# _sql_str <text> — a quoted SQL string literal.
_sql_str() { local s="${1//\\/\\\\}"; s="${s//\'/\\\'}"; printf "'%s'" "$s"; }

_require_db() {
    _container_running "$DB_CONTAINER" || error_exit "The database container '${DB_CONTAINER}' is not running (set DB_CONTAINER, or start it)."
}

# -----------------------------------------------------------------------------
# Containers
# -----------------------------------------------------------------------------

_container_exists()  { "$PODMAN" container inspect "$1" >/dev/null 2>&1; }
_container_running() { [[ "$("$PODMAN" container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
_container_state() {
    _container_exists "$1" || { printf 'missing'; return; }
    "$PODMAN" container inspect -f '{{.State.Status}}' "$1" 2>/dev/null
}

# _wait_world <since-epoch> — wait for READY_PATTERN in the world server's log
# after that moment. Fails on a crash or when the container stops.
_wait_world() {
    local since="$1" deadline=$((SECONDS + START_TIMEOUT)) log
    info "Waiting for the world server (up to ${START_TIMEOUT}s)..."
    while (( SECONDS < deadline )); do
        log="$("$PODMAN" logs --since "$since" "$SERVER_CONTAINER" 2>&1 || true)"
        if grep -qF -- "$READY_PATTERN" <<<"$log"; then success "World server is up."; return 0; fi
        if grep -qE -e 'terminate called|Segmentation fault' <<<"$log" || ! _container_running "$SERVER_CONTAINER"; then
            error_exit "The world server stopped while starting. Its last lines:
$(tail -5 <<<"$log")"
        fi
        sleep 3
    done
    error_exit "The world server did not report '${READY_PATTERN}' within ${START_TIMEOUT}s."
}

# _wait_bots <count> [names-file] — wait until that many bots are online, or,
# with a names file, until every one of those characters is.
_wait_bots() {
    local want="$1" names="${2:-}" deadline=$((SECONDS + BOTS_TIMEOUT)) n sql list
    if [[ -n "$names" ]]; then
        list="$(while IFS= read -r x; do _sql_str "$x"; printf ','; done < "$names")"
        sql="SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters WHERE online=1 AND name IN (${list%,});"
    else
        sql="SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters c JOIN ${DB_REALMD}.account a ON a.id=c.account WHERE c.online=1 AND a.username LIKE '${BOT_ACCOUNT_PREFIX}%';"
    fi
    info "Waiting for ${want} bots to log in (up to ${BOTS_TIMEOUT}s)..."
    while (( SECONDS < deadline )); do
        n="$(_db_value "$sql")"
        [[ "${n:-0}" -ge "$want" ]] && { success "${n} bots online."; return 0; }
        sleep 5
    done
    warn "Only ${n:-0} of ${want} bots online after ${BOTS_TIMEOUT}s."
    return 1
}

cmd_start() { [[ $# -eq 0 ]] || error_exit "Usage: start"; _start; }
_start() {
    _require_db
    local since
    if ! _container_running "$REALM_CONTAINER"; then
        _container_exists "$REALM_CONTAINER" || error_exit "No container '${REALM_CONTAINER}' (set REALM_CONTAINER)."
        "$PODMAN" start "$REALM_CONTAINER" >/dev/null; success "Realm server started."
    fi
    if _container_running "$SERVER_CONTAINER"; then info "The world server is already running."; return 0; fi
    _container_exists "$SERVER_CONTAINER" || error_exit "No container '${SERVER_CONTAINER}' (set SERVER_CONTAINER)."
    since="$(date +%s)"
    "$PODMAN" start "$SERVER_CONTAINER" >/dev/null
    _wait_world "$since"
}

cmd_stop() { [[ $# -eq 0 ]] || error_exit "Usage: stop"; _stop; }
_stop() {
    _container_running "$SERVER_CONTAINER" || { info "The world server is not running."; return 0; }
    _save_world || warn "Could not save through the console; the server still saves on a clean stop."
    info "Stopping the world server (it disconnects everyone)..."
    "$PODMAN" stop -t "$STOP_TIMEOUT" "$SERVER_CONTAINER" >/dev/null
    success "World server stopped."
}

cmd_restart() { [[ $# -eq 0 ]] || error_exit "Usage: restart"; _stop; _start; }

# -----------------------------------------------------------------------------
# The remote console
# -----------------------------------------------------------------------------

# Commands that must never go through the console. Sending a bot a chat
# command from it ('rndbot c <bot> ...', 'rndbot do ...') gives no answer -
# the bot replies to an in-game master - and crashed the world server
# (std::bad_weak_ptr) on the prototype.
_console_refused() { grep -qiE -e '^[[:space:]]*\.?rndbot[[:space:]]+(c|do|chat)([[:space:]]|$)' <<<"$1"; }

_ra() {
    [[ -n "$RA_PASS_FILE" ]] || error_exit "No console password file: set RA_PASS_FILE (a file with the console account's password)."
    [[ -r "$RA_PASS_FILE" ]] || error_exit "Cannot read RA_PASS_FILE (${RA_PASS_FILE})."
    helper ra --host "$RA_HOST" --port "$RA_PORT" --user "$RA_USER" --pass-file "$RA_PASS_FILE" "$@"
}

_save_world() {
    [[ -n "$RA_PASS_FILE" ]] || return 1
    _container_running "$SERVER_CONTAINER" || return 1
    _ra --quiet saveall >/dev/null 2>&1 && info "World saved."
}

cmd_save() {
    [[ $# -eq 0 ]] || error_exit "Usage: save"
    _container_running "$SERVER_CONTAINER" || error_exit "The world server is not running."
    _ra --quiet saveall
}

cmd_console() {
    [[ $# -gt 0 ]] || error_exit "Usage: console COMMAND [COMMAND...]   (each argument is one console command)"
    local c
    for c in "$@"; do
        _console_refused "$c" && error_exit "Refused: '${c}'. A bot chat command from the console gets no answer and has crashed the world server. Send it in game, as the bot's master."
    done
    _container_running "$SERVER_CONTAINER" || error_exit "The world server is not running."
    _ra "$@"
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------

# cmangos creates these accounts with their name as the password.
DEFAULT_ACCOUNTS=(ADMINISTRATOR GAMEMASTER MODERATOR PLAYER)

cmd_status() {
    [[ $# -eq 0 ]] || error_exit "Usage: status"
    local c s endpoint base code defaults names list
    header "Containers"
    for c in "$DB_CONTAINER" "$REALM_CONTAINER" "$SERVER_CONTAINER"; do
        printf '  %-24s %s\n' "$c" "$(_container_state "$c")"
    done
    header "Ports"
    for s in "$REALM_PORT" "$WORLD_PORT" "$RA_PORT"; do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE -e ":${s}\$"; then printf '  %-6s listening\n' "$s"
        else printf '  %-6s closed\n' "$s"; fi
    done
    _container_running "$DB_CONTAINER" || { warn "The database is not running; nothing more to show."; return 0; }
    header "Online"
    printf '%s\n' "SELECT SUM(a.username LIKE '${BOT_ACCOUNT_PREFIX}%') bots_online, SUM(a.username NOT LIKE '${BOT_ACCOUNT_PREFIX}%') players_online FROM ${DB_CHARACTERS}.characters c JOIN ${DB_REALMD}.account a ON a.id=c.account WHERE c.online=1;" | _db_table
    if [[ -n "$ROSTER_FILE" && -r "$ROSTER_FILE" ]]; then
        names="$(helper names "$ROSTER_FILE" 2>/dev/null || true)"
        if [[ -n "$names" ]]; then
            list="$(while IFS= read -r c; do _sql_str "$c"; printf ','; done <<<"$names")"
            printf '%s\n' "SELECT COUNT(*) roster_bots, SUM(online) roster_online FROM ${DB_CHARACTERS}.characters WHERE name IN (${list%,});" | _db_table
        fi
    fi
    if [[ -n "$BOT_CONF" && -r "$BOT_CONF" ]]; then
        header "LLM"
        endpoint="$(grep -E '^AiPlayerbot\.LLMApiEndpoint[[:space:]]*=' "$BOT_CONF" | tail -1 | cut -d= -f2- | xargs || true)"
        if [[ "$(grep -E '^AiPlayerbot\.LLMEnabled[[:space:]]*=' "$BOT_CONF" | tail -1 | cut -d= -f2- | xargs || true)" =~ ^[123]$ && -n "$endpoint" ]]; then
            base="${endpoint%/chat/completions}"
            code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${base}/models" || true)"
            if [[ "$code" == "200" ]]; then printf '  %s reachable\n' "$base"; else printf '  %s NOT reachable (http %s)\n' "$base" "${code:-none}"; fi
        else
            printf '  LLM chat off\n'
        fi
    fi
    defaults="$(printf '%s\n' "SELECT GROUP_CONCAT(username) FROM ${DB_REALMD}.account WHERE username IN ('${DEFAULT_ACCOUNTS[0]}','${DEFAULT_ACCOUNTS[1]}','${DEFAULT_ACCOUNTS[2]}','${DEFAULT_ACCOUNTS[3]}');" | _db_raw | head -1)"
    if [[ -n "$defaults" && "$defaults" != "NULL" ]]; then
        echo
        warn "cmangos' default accounts exist (${defaults}). Their passwords are well known: remove them with 'delete-account --name NAME --yes' before the realm is reachable from the network."
    fi
}
