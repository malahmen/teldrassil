# shellcheck shell=bash
# lib/accounts.sh — Accounts: create-account, set-account-level, list-accounts,
# delete-account.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

_account_name_ok() {
    [[ "$1" =~ ^[A-Za-z0-9]{3,16}$ ]] || error_exit "An account name is 3-16 letters or digits (got '${1}')."
}

cmd_create_account() {
    local name="" pass_file="" from_stdin=0 level=0 password v s
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)       _need_value "$@"; name="$2"; shift 2 ;;
        --pass-file)  _need_value "$@"; pass_file="$2"; shift 2 ;;
        --pass-stdin) from_stdin=1; shift ;;
        --level)      _need_value "$@"; level="$2"; shift 2 ;;
        *) error_exit "create-account: unknown flag $1" ;;
    esac; done
    [[ -n "$name" ]] || error_exit "Usage: create-account --name NAME (--pass-file FILE | --pass-stdin) [--level 0-3]"
    _account_name_ok "$name"
    [[ "$level" =~ ^[0-3]$ ]] || error_exit "--level is 0 (player) to 3 (administrator)."
    if [[ -n "$pass_file" ]]; then
        [[ -r "$pass_file" ]] || error_exit "Cannot read ${pass_file}."
        password="$(head -1 "$pass_file")"
    elif (( from_stdin )); then
        IFS= read -r password || true
    else
        error_exit "Give the password with --pass-file FILE or --pass-stdin; it is never taken as an argument."
    fi
    [[ ${#password} -ge 4 && ${#password} -le 16 ]] || error_exit "A 1.12.1 password is 4-16 characters."
    _require_db
    name="${name^^}"
    [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_REALMD}.account WHERE username=$(_sql_str "$name");")" == "0" ]] \
        || error_exit "Account ${name} already exists."
    read -r v s < <(printf '%s\n' "$password" | helper srp6 --user "$name")
    unset password
    printf '%s\n' \
        "INSERT INTO ${DB_REALMD}.account (username, v, s, gmlevel, joindate) VALUES ($(_sql_str "$name"), '${v}', '${s}', ${level}, NOW());" \
        "INSERT INTO ${DB_REALMD}.realmcharacters (realmid, acctid, numchars) SELECT r.id, a.id, 0 FROM ${DB_REALMD}.realmlist r JOIN ${DB_REALMD}.account a ON a.username=$(_sql_str "$name") LEFT JOIN ${DB_REALMD}.realmcharacters rc ON rc.acctid=a.id AND rc.realmid=r.id WHERE rc.acctid IS NULL;" \
        | _db_raw
    success "Account ${name} created (level ${level})."
}

cmd_set_account_level() {
    local name="" level=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)  _need_value "$@"; name="$2"; shift 2 ;;
        --level) _need_value "$@"; level="$2"; shift 2 ;;
        *) error_exit "set-account-level: unknown flag $1" ;;
    esac; done
    [[ -n "$name" && "$level" =~ ^[0-3]$ ]] || error_exit "Usage: set-account-level --name NAME --level 0-3"
    _require_db
    name="${name^^}"
    [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_REALMD}.account WHERE username=$(_sql_str "$name");")" == "1" ]] \
        || error_exit "No account ${name}."
    printf '%s\n' "UPDATE ${DB_REALMD}.account SET gmlevel=${level} WHERE username=$(_sql_str "$name");" | _db_raw
    success "${name} is now level ${level}. It takes effect at the next full login (log out to the login screen, not just the character list)."
}

cmd_list_accounts() {
    local bots=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --bots) bots=1; shift ;;
        *) error_exit "list-accounts: unknown flag $1" ;;
    esac; done
    _require_db
    local where="WHERE a.username NOT LIKE '${BOT_ACCOUNT_PREFIX}%'"
    (( bots )) && where=""
    printf '%s\n' "SELECT a.id, a.username, a.gmlevel, a.joindate, a.locked, COUNT(c.guid) characters FROM ${DB_REALMD}.account a LEFT JOIN ${DB_CHARACTERS}.characters c ON c.account=a.id ${where} GROUP BY a.id ORDER BY a.id;" | _db_table
}

cmd_delete_account() {
    local name="" yes=0 chars
    while [[ $# -gt 0 ]]; do case "$1" in
        --name) _need_value "$@"; name="$2"; shift 2 ;;
        --yes)  yes=1; shift ;;
        *) error_exit "delete-account: unknown flag $1" ;;
    esac; done
    [[ -n "$name" ]] || error_exit "Usage: delete-account --name NAME --yes"
    (( yes )) || error_exit "delete-account removes the account for good: add --yes."
    _require_db
    name="${name^^}"
    [[ "$name" != "${BOT_ACCOUNT_PREFIX}"* ]] || error_exit "That is a bot account; playerbots manages those."
    [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_REALMD}.account WHERE username=$(_sql_str "$name");")" == "1" ]] \
        || error_exit "No account ${name}."
    chars="$(_db_value "SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters c JOIN ${DB_REALMD}.account a ON a.id=c.account WHERE a.username=$(_sql_str "$name");")"
    [[ "$chars" == "0" ]] || error_exit "${name} still has ${chars} character(s); delete them in game first."
    printf '%s\n' \
        "DELETE FROM ${DB_REALMD}.realmcharacters WHERE acctid IN (SELECT id FROM ${DB_REALMD}.account WHERE username=$(_sql_str "$name"));" \
        "DELETE FROM ${DB_REALMD}.account WHERE username=$(_sql_str "$name");" | _db_raw
    success "Account ${name} deleted."
}
