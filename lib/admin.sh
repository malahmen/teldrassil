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

# An accounts-only dump: --db DB_REALMD with --tables among these, account
# included. It carries rows only (no DROP or CREATE TABLE, REPLACE INTO with
# the column names), under a first line that marks it, and restore MERGES it:
# restoring accounts must never wipe another server's own - its bots, its
# console account, the players it has that the dump has not.
ACCOUNT_TABLES=(account account_banned realmcharacters)
ACCOUNTS_MARK="-- teldrassil accounts-only dump: restore merges it (Kamino 232)"
ACCOUNTS_STAGE=teldrassil_import

# _accounts_only <db> <table...> — is this dump an accounts-only one?
_accounts_only() {
    local db="$1" t has=0; shift
    [[ "$db" == "$DB_REALMD" && $# -gt 0 ]] || return 1
    for t in "$@"; do
        case "$t" in
            account) has=1 ;;
            account_banned|realmcharacters) ;;
            *) return 1 ;;
        esac
    done
    (( has ))
}

cmd_dump() {
    local all=0 db="" tables="" out="" gzip=1 force=0 stamp
    while [[ $# -gt 0 ]]; do case "$1" in
        --all) all=1; shift ;;
        --db) _need_value "$@"; db="$2"; shift 2 ;;
        --tables) _need_value "$@"; tables="$2"; shift 2 ;;
        --out) _need_value "$@"; out="$2"; shift 2 ;;
        --no-gzip) gzip=0; shift ;;
        --force) force=1; shift ;;
        *) error_exit "dump: unknown flag $1" ;;
    esac; done
    (( all )) || [[ -n "$db" ]] || error_exit "Usage: dump --all | --db NAME [--tables \"a b c\"] [--out PATH [--force]] [--no-gzip]"
    (( all )) && [[ -n "$db" ]] && error_exit "dump: --all or --db, not both."
    [[ -z "$tables" || -n "$db" ]] || error_exit "dump: --tables needs --db."
    _require_db
    local -a args; local mark=""
    if (( all )); then
        args=(--databases "$DB_WORLD" "$DB_CHARACTERS" "$DB_REALMD" "$DB_LOGS")
    elif [[ -n "$tables" ]]; then
        local -a t; read -ra t <<<"$tables"
        args=("$db" "${t[@]}")
        if _accounts_only "$db" "${t[@]}"; then
            mark="${ACCOUNTS_MARK}"
            args=(--no-create-info --replace --complete-insert --skip-triggers --skip-routines --skip-events "${args[@]}")
        fi
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
    [[ ! -e "$out" ]] || (( force )) || error_exit "${out} exists; --force replaces it."
    # Written next to it under a temporary name and moved into place only
    # once whole: a dump that fails leaves no file that looks like a backup.
    DUMP_TMP="$(mktemp "$(dirname -- "$out")/.$(basename -- "$out").XXXXXX")" || error_exit "Cannot write in $(dirname -- "$out")."
    _at_exit _dump_tmp_remove
    _save_world || true
    # The mark, when there is one, is the first line; the dump after it must
    # not be empty.
    local skip=1; [[ -z "$mark" ]] || skip=2
    if ! (umask 077
          _marked() { if [[ -n "$mark" ]]; then printf '%s\n' "$mark"; fi; _db_dump "${args[@]}"; }
          if (( gzip )); then _marked | gzip -c > "$DUMP_TMP"; else _marked > "$DUMP_TMP"; fi) \
        || [[ -z "$(if (( gzip )); then gzip -dc -- "$DUMP_TMP" 2>/dev/null; else cat -- "$DUMP_TMP"; fi | tail -n +"$skip" | head -c 1)" ]]; then
        error_exit "The dump failed or was empty; nothing was written to ${out}."
    fi
    chmod 600 -- "$DUMP_TMP"
    mv -f -- "$DUMP_TMP" "$out"; DUMP_TMP=""
    success "Dumped to ${out} ($(du -h -- "$out" | cut -f1))."
    if [[ -n "$mark" ]]; then
        info "An accounts-only dump: restore merges it into a server's accounts by name, leaving out that server's bot and console accounts."
    elif [[ -n "$tables" ]]; then
        info "A --tables dump carries no CREATE DATABASE: restore it with --db ${db}."
    fi
    return 0
}

DUMP_TMP=""
_dump_tmp_remove() { [[ -z "$DUMP_TMP" ]] || rm -f -- "$DUMP_TMP"; }

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
    [[ -z "$db" || "$db" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "--db: a database name (letters, digits, underscore)."
    _cat_dump() { if [[ "$(head -c 2 -- "$file" | od -An -tx1 | tr -d ' ')" == "1f8b" ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi; }
    # The first line only: what follows is not read (gzip may stop early).
    if [[ "$({ _cat_dump 2>/dev/null || true; } | head -n 1)" == "$ACCOUNTS_MARK" ]]; then
        (( yes )) || error_exit "restore merges this accounts-only dump into ${db:-$DB_REALMD}'s accounts (same name: the dump's password and level): add --yes."
        _require_db
        _restore_accounts "${db:-$DB_REALMD}"
        return
    fi
    (( yes )) || error_exit "restore REPLACES the data in the databases the dump names: add --yes."
    _require_db
    _server_running && error_exit "Stop the world server first ('stop'): it would write its own state over the restored data."
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

# _console_names — the target's console account(s), upper-case and quoted
# for SQL: TELDRASSIL (console-account's), RA_USER, and the 'account:' line
# of RA_PASS_FILE.
_console_names() {
    local -a n=(TELDRASSIL); local u
    [[ -z "$RA_USER" ]] || n+=("${RA_USER^^}")
    if [[ -n "$RA_PASS_FILE" && -r "$RA_PASS_FILE" ]]; then
        u="$(sed -nE 's/^[[:space:]]*account:[[:space:]]*([^[:space:]]+).*/\1/p' -- "$RA_PASS_FILE" | head -1)"
        [[ -z "$u" ]] || n+=("${u^^}")
    fi
    local out="" x; for x in "${n[@]}"; do out+="$(_sql_str "$x"),"; done
    printf '%s' "${out%,}"
}

# _restore_accounts <realmd> — merge an accounts-only dump. It is loaded into
# a staging database (tables made LIKE the target's), then merged by name in
# one transaction: an account the target has gets the dump's verifier, salt,
# GM level and lock (its id, and so its characters, stay); a new one is added
# with a new id and a realmcharacters row per realm. Bans come along for the
# accounts merged. The dump's bot accounts (BOT_ACCOUNT_PREFIX) and console
# accounts are left out, so the target's own are never touched; neither is
# any account the dump does not have. The world server may run.
_restore_accounts() {
    local r="$1" st="$ACCOUNTS_STAGE" keep res total kept new
    [[ "$r" =~ ^[A-Za-z0-9_]+$ ]] || error_exit "${r}: not a database name."
    keep="UPPER(i.username) NOT IN ($(_console_names))"
    [[ -z "$BOT_ACCOUNT_PREFIX" ]] || keep+=" AND LEFT(UPPER(i.username), ${#BOT_ACCOUNT_PREFIX}) <> $(_sql_str "${BOT_ACCOUNT_PREFIX^^}")"
    info "Merging the dump's accounts into ${r}..."
    if ! res="$({
        printf '%s\n' "DROP DATABASE IF EXISTS \`${st}\`;" "CREATE DATABASE \`${st}\`;"
        local t; for t in "${ACCOUNT_TABLES[@]}"; do printf '%s\n' "CREATE TABLE \`${st}\`.\`${t}\` LIKE \`${r}\`.\`${t}\`;"; done
        printf 'USE `%s`;\n' "$st"
        # A dump that cannot be read whole (a damaged gzip) ends in a
        # statement that fails, so the client stops before the merge.
        _cat_dump || printf '%s\n' ";" "teldrassil_the_dump_could_not_be_read_whole;"
        printf '%s\n' ";" "START TRANSACTION;" \
            "SELECT COUNT(*), COALESCE(SUM(${keep}), 0), COALESCE(SUM((${keep}) AND t.id IS NULL), 0) FROM \`${st}\`.account i LEFT JOIN \`${r}\`.account t ON t.username=i.username;" \
            "INSERT INTO \`${r}\`.account (username, gmlevel, v, s, joindate, locked) SELECT i.username, i.gmlevel, i.v, i.s, i.joindate, i.locked FROM \`${st}\`.account i WHERE ${keep} ON DUPLICATE KEY UPDATE gmlevel=VALUES(gmlevel), v=VALUES(v), s=VALUES(s), locked=VALUES(locked);" \
            "INSERT IGNORE INTO \`${r}\`.realmcharacters (realmid, acctid, numchars) SELECT rl.id, a.id, 0 FROM \`${r}\`.realmlist rl JOIN \`${r}\`.account a JOIN \`${st}\`.account i ON a.username=i.username WHERE ${keep};" \
            "INSERT IGNORE INTO \`${r}\`.account_banned (id, bandate, unbandate, bannedby, banreason, active) SELECT a.id, b.bandate, b.unbandate, b.bannedby, b.banreason, b.active FROM \`${st}\`.account_banned b JOIN \`${st}\`.account i ON i.id=b.id JOIN \`${r}\`.account a ON a.username=i.username WHERE ${keep};" \
            "COMMIT;" "DROP DATABASE \`${st}\`;"
    } | _db_raw)"; then
        printf '%s\n' "DROP DATABASE IF EXISTS \`${st}\`;" | _db_raw >/dev/null 2>&1 || true
        error_exit "The merge failed; ${r}'s accounts are as they were (it runs in one transaction)."
    fi
    read -r total kept new <<<"$(tail -n 1 <<<"$res")" || true
    if [[ "$total" =~ ^[0-9]+$ && "$kept" =~ ^[0-9]+$ && "$new" =~ ^[0-9]+$ ]]; then
        success "Merged ${kept} of the dump's ${total} accounts into ${r} (${new} new, $((kept - new)) updated); $((total - kept)) bot or console accounts left out."
    else
        success "Merged the dump's accounts into ${r}."
    fi
    info "Bot accounts (${BOT_ACCOUNT_PREFIX}*) and the console account were left as they were."
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
