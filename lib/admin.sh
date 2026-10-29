# shellcheck shell=bash
# lib/admin.sh — Administration: rename-character, apply-sql, dump, restore,
# and the graceful restart.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

# -----------------------------------------------------------------------------
# rename-character
# -----------------------------------------------------------------------------

cmd_rename_character() {
    local from="" to="" row guid online
    while [[ $# -gt 0 ]]; do case "$1" in
        --from) _need_value "$@"; from="$2"; shift 2 ;;
        --to)   _need_value "$@"; to="$2"; shift 2 ;;
        *) error_exit "rename-character: unknown flag $1" ;;
    esac; done
    [[ -n "$from" && -n "$to" ]] || error_exit "Usage: rename-character --from OLD --to NEW"
    [[ "$to" =~ ^[A-Z][a-z]{1,11}$ ]] || error_exit "A name is 2-12 letters, capital first, the rest lower-case (got '${to}')."
    _require_db
    row="$(_db_value "SELECT CONCAT(guid, ' ', online) FROM ${DB_CHARACTERS}.characters WHERE name=$(_sql_str "$from");")"
    [[ -n "$row" ]] || error_exit "No character named ${from}."
    read -r guid online <<<"$row"
    [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters WHERE name=$(_sql_str "$to");")" == "0" ]] \
        || error_exit "The name ${to} is taken."
    # The world server holds an online character in memory and would write
    # the old name back.
    if [[ "$online" == "1" ]] && _server_running; then
        error_exit "${from} is online. Log it out first - or, for a bot, stop the server ('stop'), rename, then 'start'."
    fi
    printf '%s\n' "UPDATE ${DB_CHARACTERS}.characters SET name=$(_sql_str "$to") WHERE guid=${guid};" | _db_raw
    success "${from} is now ${to}."
    if [[ -n "$ROSTER_FILE" && -r "$ROSTER_FILE" ]] && helper names "$ROSTER_FILE" 2>/dev/null | grep -qxF -- "$from"; then
        warn "${from} is in the roster: rename it there too, or the next 'roster apply' gives the name to another bot."
    fi
}

# -----------------------------------------------------------------------------
# apply-sql — run a .sql file once, tracked by its content's hash in
# <realmd>.teldrassil_applied, so re-running an unchanged file does nothing.
# -----------------------------------------------------------------------------

cmd_apply_sql() {
    local file="" db="" force=0 record=1 hash name
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) _need_value "$@"; file="$2"; shift 2 ;;
        --db)   _need_value "$@"; db="$2"; shift 2 ;;
        --force) force=1; shift ;;
        --no-record) record=0; shift ;;
        *) error_exit "apply-sql: unknown flag $1" ;;
    esac; done
    [[ -n "$file" && -n "$db" ]] || error_exit "Usage: apply-sql --file PATH --db NAME [--force] [--no-record]"
    [[ -r "$file" ]] || error_exit "Cannot read ${file}."
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "--db: a database name (letters, digits, underscore)."
    _require_db
    hash="$(sha256sum -- "$file" | cut -d' ' -f1)"; name="$(basename -- "$file")"
    printf '%s\n' "CREATE TABLE IF NOT EXISTS ${DB_REALMD}.teldrassil_applied (
        sha256 CHAR(64) NOT NULL, file VARCHAR(255) NOT NULL, db VARCHAR(64) NOT NULL,
        applied_at DATETIME NOT NULL, PRIMARY KEY (sha256, db));" | _db_raw
    if (( ! force )) && [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_REALMD}.teldrassil_applied WHERE sha256='${hash}' AND db=$(_sql_str "$db");")" != "0" ]]; then
        info "${name} (this exact content) was already applied to ${db}; nothing to do. --force runs it again."
        return 0
    fi
    { printf 'USE `%s`;\n' "$db"; cat -- "$file"; printf '\n'; } | _db_raw >/dev/null
    if (( record )); then
        printf '%s\n' "REPLACE INTO ${DB_REALMD}.teldrassil_applied (sha256, file, db, applied_at) VALUES ('${hash}', $(_sql_str "$name"), $(_sql_str "$db"), NOW());" | _db_raw
    fi
    success "${name} applied to ${db}."
    _server_running && warn "The world server is running: what it holds in memory (characters, guilds) may overwrite this, and world data takes a restart to load."
    return 0
}

# -----------------------------------------------------------------------------
# dump / restore. mariadb-dump runs inside the database container, with the
# password read there; the dump comes out on stdout.
# -----------------------------------------------------------------------------

_db_dump() { _db_in mariadb-dump --single-transaction --routines --events "$@"; }

cmd_dump() {
    local all=0 db="" tables="" out="" gzip=1 stamp
    while [[ $# -gt 0 ]]; do case "$1" in
        --all) all=1; shift ;;
        --db) _need_value "$@"; db="$2"; shift 2 ;;
        --tables) _need_value "$@"; tables="$2"; shift 2 ;;
        --out) _need_value "$@"; out="$2"; shift 2 ;;
        --no-gzip) gzip=0; shift ;;
        *) error_exit "dump: unknown flag $1" ;;
    esac; done
    (( all )) || [[ -n "$db" ]] || error_exit "Usage: dump --all | --db NAME [--tables \"a b c\"] [--out PATH] [--no-gzip]"
    (( all )) && [[ -n "$db" ]] && error_exit "dump: --all or --db, not both."
    [[ -z "$tables" || -n "$db" ]] || error_exit "dump: --tables needs --db."
    _require_db
    local -a args
    if (( all )); then
        args=(--databases "$DB_WORLD" "$DB_CHARACTERS" "$DB_REALMD" "$DB_LOGS")
    elif [[ -n "$tables" ]]; then
        local -a t; read -ra t <<<"$tables"
        args=("$db" "${t[@]}")
    else
        args=(--databases "$db")
    fi
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [[ -z "$out" ]]; then
        _mkdir_private "$DUMP_DIR"
        local base="$db" suffix=""
        if (( all )); then base="all"; fi
        if [[ -n "$tables" ]]; then suffix="-tables"; fi
        out="${DUMP_DIR}/${base}${suffix}-${stamp}.sql"
        if (( gzip )); then out+=".gz"; fi
    fi
    _save_world || true
    (umask 077
     if (( gzip )); then _db_dump "${args[@]}" | gzip -c > "$out"; else _db_dump "${args[@]}" > "$out"; fi)
    success "Dumped to ${out} ($(du -h -- "$out" | cut -f1))."
    [[ -n "$tables" ]] && info "A --tables dump carries no CREATE DATABASE: restore it with --db ${db}."
    return 0
}

cmd_restore() {
    local file="" yes=0 db="" names
    while [[ $# -gt 0 ]]; do case "$1" in
        --file) _need_value "$@"; file="$2"; shift 2 ;;
        --db) _need_value "$@"; db="$2"; shift 2 ;;
        --yes) yes=1; shift ;;
        *) error_exit "restore: unknown flag $1" ;;
    esac; done
    [[ -n "$file" ]] || error_exit "Usage: restore --file PATH --yes [--db NAME]"
    [[ -r "$file" ]] || error_exit "Cannot read ${file}."
    (( yes )) || error_exit "restore REPLACES the data in the databases the dump names: add --yes."
    _require_db
    _server_running && error_exit "Stop the world server first ('stop'): it would write its own state over the restored data."
    _cat_dump() { if [[ "$(head -c 2 -- "$file" | od -An -tx1 | tr -d ' ')" == "1f8b" ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi; }
    # No CREATE DATABASE (a --tables dump) is an answer, not an error: grep
    # finding nothing must not end the script under pipefail.
    names="$({ _cat_dump | grep -oE '^CREATE DATABASE[^`]*`[^`]+`' || true; } | sed -E 's/.*`([^`]+)`/\1/' | sort -u | tr '\n' ' ')"
    if [[ -z "$names" ]]; then
        [[ -n "$db" ]] || error_exit "This dump names no database (a --tables dump): give --db NAME."
        info "Restoring into ${db}..."
        { printf 'USE `%s`;\n' "$db"; _cat_dump; } | _db_raw >/dev/null
    else
        [[ -z "$db" ]] || warn "The dump names its databases (${names% }); --db is ignored."
        info "Restoring ${names% }..."
        _cat_dump | _db_raw >/dev/null
    fi
    success "Restored. Start the server with 'start'."
}

# -----------------------------------------------------------------------------
# restart --graceful: mangosd warns players, saves and exits after SECS.
#
# A container made by 'create' has --restart on-failure: when mangosd exits
# with a failure code (cmangos' restart code is not 0), podman starts it again
# itself; on a clean exit it stays stopped. Which one happens is not assumed:
# the container's StartedAt tells a restart podman made from one this has to
# make, so a restart that worked is reported as one, and this never races
# podman's. A Deployment's pod restarts the container itself; this waits for it.
# -----------------------------------------------------------------------------

# How long an exited world server gets for its restart policy to start it
# again before this starts it.
RESTART_GRACE=10

_server_started_at() { _on_host "$PODMAN" container inspect -f '{{.State.StartedAt}}' "$SERVER_CONTAINER" 2>/dev/null || true; }

_restart_graceful() {
    local secs="$1" deadline since restarts=0 started="" now=""
    [[ "$secs" =~ ^[0-9]+$ ]] || error_exit "--graceful takes seconds (got '${secs}')."
    _server_running || error_exit "The world server is not running."
    _is_kube && restarts="$(_kube_restarts)"
    _is_kube || started="$(_server_started_at)"
    since="$(date +%s)"
    _ra --quiet "server restart ${secs}" >/dev/null
    info "Restart announced: players are warned, the world saves, and mangosd exits in ${secs}s."
    deadline=$((SECONDS + secs + STOP_TIMEOUT))
    if _is_kube; then
        until [[ "$(_kube_restarts)" -gt "$restarts" ]]; do
            (( SECONDS < deadline )) || error_exit "The world server did not exit within $((secs + STOP_TIMEOUT))s."
            sleep 3
        done
        _wait_world 0 "$((restarts + 1))"
        return
    fi
    while :; do
        if _server_running; then
            now="$(_server_started_at)"
            if [[ -n "$now" && "$now" != "$started" ]]; then
                info "mangosd exited and its container's restart policy started it again."
                break
            fi
        else
            info "mangosd exited."
            _restart_after_exit "$started"
            break
        fi
        (( SECONDS < deadline )) || error_exit "The world server did not exit within $((secs + STOP_TIMEOUT))s."
        sleep 3
    done
    _wait_world "$since"
}

# _restart_after_exit <started-at> — the container stopped: give its restart
# policy RESTART_GRACE seconds to start it, then start it here. A start of a
# container that is running already changes nothing, so a late policy restart
# and this one cannot both happen.
_restart_after_exit() {
    local grace=$((SECONDS + RESTART_GRACE)) now
    while (( SECONDS < grace )); do
        sleep 2
        if _server_running; then
            now="$(_server_started_at)"
            [[ "$now" == "$1" ]] || { info "Its container's restart policy started it again."; return 0; }
        fi
    done
    info "Starting it again."
    _server_start_raw
}
