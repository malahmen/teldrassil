# shellcheck shell=bash
# lib/runtime.sh — The database, the containers and the remote console:
# start, stop, restart, status, save and console.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

# -----------------------------------------------------------------------------
# The database. SQL always goes in on stdin and the password is read inside
# the container - from DB_PASS_FILE, or from the variable DB_PASS_ENV names -
# so neither reaches a command line, here or on SSH_HOST.
# -----------------------------------------------------------------------------

# _db_in <program> <args...> — a MariaDB client program in the database
# container, logged in.
_db_in() {
    # shellcheck disable=SC2016  # $1.. are the inner shell's, by design
    _on_host "$PODMAN" exec -i "$DB_CONTAINER" sh -c \
        'if [ -n "$3" ]; then p="$(printenv "$3")"; else p="$(cat "$1")"; fi; u="$2"; shift 3; prog="$1"; shift; MYSQL_PWD="$p" exec "$prog" -u"$u" "$@"' \
        _ "$DB_PASS_FILE" "$DB_USER" "$DB_PASS_ENV" "$@"
}
# _db_raw — run stdin's SQL; tab-separated rows, no headers, no escaping.
_db_raw() { _db_in mariadb -N -B -r; }
# _db_table — the same, as a table for people to read.
_db_table() { _db_in mariadb -t; }
# _db_value <sql> — one value.
_db_value() { printf '%s\n' "$1" | _db_raw | head -1; }
# _sql_str <text> — a quoted SQL string literal.
_sql_str() { local s="${1//\\/\\\\}"; s="${s//\'/\\\'}"; printf "'%s'" "$s"; }

_require_db() {
    _container_running "$DB_CONTAINER" || error_exit "The database container '${DB_CONTAINER}' is not running on $( [[ -n "$SSH_HOST" ]] && printf '%s' "$SSH_HOST" || printf 'this host') (set DB_CONTAINER, or start it)."
}

# _wait_world <since-epoch> [restarts] — wait for READY_PATTERN in the world
# server's log after that moment. Fails on a crash or when it stops; for a
# Deployment, a crash is its container restarting past [restarts].
_wait_world() {
    local since="$1" restarts="${2:-0}" deadline=$((SECONDS + START_TIMEOUT)) log
    info "Waiting for the world server (up to ${START_TIMEOUT}s)..."
    while (( SECONDS < deadline )); do
        log="$(_server_log "$since")"
        if grep -qF -- "$READY_PATTERN" <<<"$log"; then success "World server is up."; return 0; fi
        if _is_kube && [[ "$(_kube_restarts)" -gt "$restarts" ]]; then
            error_exit "The world server crashed while starting. Its last lines:
$(_kube logs "deployment/${SERVER_CONTAINER}" --previous 2>&1 | tail -5)"
        fi
        # A Deployment's pod may still be scheduling or syncing data: no
        # log yet is not a failure.
        if grep -qE -e 'terminate called|Segmentation fault' <<<"$log" || { ! _is_kube && ! _container_running "$SERVER_CONTAINER"; }; then
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
    # The login server: a container here; in a cluster it is not ours to
    # start (which realm owns the login port is decided where it is deployed).
    if ! _is_kube && ! _container_running "$REALM_CONTAINER"; then
        _container_exists "$REALM_CONTAINER" || error_exit "No container '${REALM_CONTAINER}' (set REALM_CONTAINER)."
        _on_host "$PODMAN" start "$REALM_CONTAINER" >/dev/null; success "Realm server started."
    fi
    if _server_running; then _bots_push_pending_warn; info "The world server is already running."; return 0; fi
    since="$(date +%s)"
    _server_start_raw
    _wait_world "$since"
}

# Changed bot config is written when the server starts; one already running
# keeps what it read until its next start.
_bots_push_pending_warn() {
    (( BOTS_PULLED )) && [[ "$(_bots_sum)" != "$BOTS_SUM" ]] && info "The bot config changes are saved and take effect at the next restart."
    return 0
}

cmd_stop() { [[ $# -eq 0 ]] || error_exit "Usage: stop"; _stop; }
_stop() {
    _server_running || { info "The world server is not running."; return 0; }
    _save_world || warn "Could not save through the console; the server still saves on a clean stop."
    info "Stopping the world server (it disconnects everyone)..."
    _server_stop_raw
    success "World server stopped."
}

# A command that stops a running world server to write the database arms
# this first, and disarms it when it starts the server itself: whatever ends
# the command before then - an error, a signal - the server is started again
# on the way out, and the realm is left as it was found.
RESTART_ON_EXIT=0; RESTART_HOOKED=0
_restart_arm() {
    (( RESTART_HOOKED )) || { _at_exit _restart_on_exit; RESTART_HOOKED=1; }
    RESTART_ON_EXIT=1
}
_restart_disarm() { RESTART_ON_EXIT=0; }
_restart_on_exit() {
    (( RESTART_ON_EXIT )) || return 0
    _server_running && return 0
    warn "The world server was running before this command stopped it: starting it again."
    _start
}

# restart [--graceful [SECS]]: by default stop and start here. --graceful asks
# mangosd itself (players warned, world saved, default 60 s), then starts it
# again when it has exited.
cmd_restart() {
    if [[ $# -eq 0 ]]; then _stop; _start; return; fi
    [[ "$1" == "--graceful" && $# -le 2 ]] || error_exit "Usage: restart [--graceful [SECS]]"
    _restart_graceful "${2:-60}"
}

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
    local -a via=(); [[ -n "$SSH_HOST" ]] && via=(--ssh "$SSH_HOST")
    helper ra --host "$RA_HOST" --port "$RA_PORT" --user "$RA_USER" --pass-file "$RA_PASS_FILE" "${via[@]}" "$@"
}

_save_world() {
    [[ -n "$RA_PASS_FILE" ]] || return 1
    _server_running || return 1
    _ra --quiet saveall >/dev/null 2>&1 && info "World saved."
}

cmd_save() {
    [[ $# -eq 0 ]] || error_exit "Usage: save"
    _server_running || error_exit "The world server is not running."
    _ra --quiet saveall
}

cmd_console() {
    [[ $# -gt 0 ]] || error_exit "Usage: console COMMAND [COMMAND...]   (each argument is one console command)"
    local c
    for c in "$@"; do
        _console_refused "$c" && error_exit "Refused: '${c}'. A bot chat command from the console gets no answer and has crashed the world server. Send it in game, as the bot's master."
    done
    _server_running || error_exit "The world server is not running."
    _ra "$@"
}

# console-account [--file F] — teldrassil's console account, TELDRASSIL at
# level 3, with a new random password in F (0600), and RA_USER/RA_PASS_FILE
# pointed at it in the active profile. A server teldrassil installed has one
# already; this is for one it did not.
cmd_console_account() {
    local file="" pw v s
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) _need_value "$@"; file="$2"; shift 2 ;;
        *) error_exit "console-account: unknown flag $1" ;;
    esac; done
    [[ -n "$file" ]] || file="${CONFIG_DIR}/console${PROFILE:+-$PROFILE}.txt"
    _require_db
    _mkdir_private "$(dirname "$file")"
    pw="$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 12 || true)"
    [[ ${#pw} -eq 12 ]] || error_exit "Could not make a random password."
    read -r v s < <(printf '%s\n' "$pw" | helper srp6 --user TELDRASSIL)
    printf '%s\n' "INSERT INTO ${DB_REALMD}.account (username, v, s, gmlevel, joindate) VALUES ('TELDRASSIL', '${v}', '${s}', 3, NOW()) ON DUPLICATE KEY UPDATE v=VALUES(v), s=VALUES(s), gmlevel=3;" | _db_raw
    (umask 077; printf 'teldrassil console account\naccount: TELDRASSIL\npassword: %s\n' "$pw" > "$file")
    unset pw
    cfg_set RA_USER TELDRASSIL; cfg_set RA_PASS_FILE "$file"
    success "Console account TELDRASSIL ready (password in ${file})${PROFILE:+; profile ${PROFILE} points at it}."
    _server_running && info "The world server reads accounts as they log in: 'console' works now."
    return 0
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------

# cmangos creates these accounts with their name as the password.
DEFAULT_ACCOUNTS=(ADMINISTRATOR GAMEMASTER MODERATOR PLAYER)

cmd_status() {
    [[ $# -eq 0 ]] || error_exit "Usage: status"
    local c s endpoint base code defaults names list
    local listening
    header "Server: $(_where)"
    printf '  %-24s %s\n' "$DB_CONTAINER" "$(_container_state "$DB_CONTAINER")"
    _is_kube || printf '  %-24s %s\n' "$REALM_CONTAINER" "$(_container_state "$REALM_CONTAINER")"
    printf '  %-24s %s\n' "$SERVER_CONTAINER" "$(_server_state)"
    header "Ports"
    listening="$(_on_host ss -ltn 2>/dev/null | awk '{print $4}' || true)"
    for s in "$REALM_PORT" "$WORLD_PORT" "$RA_PORT"; do
        if grep -qE -e ":${s}\$" <<<"$listening"; then printf '  %-6s listening\n' "$s"
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
    _bots_pull
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
