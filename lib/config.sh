# shellcheck shell=bash
# lib/config.sh — The key=value config store, its defaults, profiles, and the
# set, get, config and profiles commands.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teldrassil"
CONFIG_FILE="${CONFIG_DIR}/teldrassil.conf"
BACKUP_DIR="${CONFIG_DIR}/backups"
DUMP_DIR="${CONFIG_DIR}/dumps"
PROFILE_DIR="${CONFIG_DIR}/profiles"

# Profiles, as nordrassil's: one per server. A profile is PROFILE_DIR/NAME.conf,
# layered over teldrassil.conf - a key in the profile wins, anything absent
# falls through - so shared settings (the roster, the console's timeouts) stay
# in one place. --profile NAME or $TELDRASSIL_PROFILE picks one; 'set' writes
# to it, and creates it.
PROFILE="${TELDRASSIL_PROFILE:-}"
PROFILE_FILE=""

# Every setting, with its default and what it is for. The defaults describe a
# server run by teldrassil itself; a prototype or another layout sets its own
# names with 'set'.
CONFIG_KEYS=(
    "PODMAN=podman|the container runtime: podman, or docker (rootful docker: the build image's containers run as you)"
    "SSH_HOST=|run the containers, kubectl and the console's connection on this ssh host (empty: here)"
    "SERVER_KIND=podman|how the servers run: podman (containers) or kube (Deployments, through kubectl)"
    "KUBE_NAMESPACE=|kube: the servers' namespace"
    "BOT_SECRET=|kube: the Secret holding aiplayerbot.conf and the card file (teldrassil edits it)"
    "DB_CONTAINER=teldrassil-db|the MariaDB container"
    "DB_USER=root|the database user"
    "DB_PASS_FILE=/run/pw/root.pw|the database password file, INSIDE the database container"
    "DB_PASS_ENV=|or: the variable holding the password, inside the database container (e.g. MARIADB_ROOT_PASSWORD)"
    "DB_WORLD=classicmangos|the world database"
    "DB_CHARACTERS=classiccharacters|the characters database"
    "DB_REALMD=classicrealmd|the realm (accounts) database"
    "DB_LOGS=classiclogs|the logs database"
    "SERVER_CONTAINER=teldrassil-mangosd|the world server container (kube: its Deployment)"
    "REALM_CONTAINER=teldrassil-realmd|the realm (login) server container (kube: not managed here)"
    "BOT_ACCOUNT_PREFIX=RNDBOT|playerbots' random-bot account names start with this"
    "RA_HOST=127.0.0.1|the remote console's address"
    "RA_PORT=3443|the remote console's port"
    "RA_USER=|the console account (empty: the 'account:' line of RA_PASS_FILE)"
    "RA_PASS_FILE=|a file holding the console account's password (host path)"
    "ETC_DIR=|the server's config directory on the host (mangosd.conf, aiplayerbot.conf)"
    "BOT_CONF=|aiplayerbot.conf on the host (empty: ETC_DIR/aiplayerbot.conf)"
    "CARDS_FILE=|the character-card file on the host (empty: ETC_DIR/llm_character_card.txt)"
    "CARDS_FILE_IN_SERVER=/install/etc/llm_character_card.txt|the same file as the server sees it"
    "ROSTER_FILE=|the roster (JSON) that 'roster' commands use by default"
    "DBC_DIR=|the extracted client dbc directory on the host (zone names in search)"
    "WORLD_PORT=8085|the world server's port"
    "REALM_PORT=3724|the realm server's port"
    "READY_PATTERN=World initialized|the world server's log line that means it is up"
    "START_TIMEOUT=300|seconds to wait for the world server to come up"
    "STOP_TIMEOUT=120|seconds the world server gets to save and stop"
    "BOTS_TIMEOUT=600|seconds to wait for bots to log in"
    "FRESH_STOP_WAIT=120|an interrupted --fresh-population that started a stopped server: seconds to wait for the bot deletion before stopping it again"
    "WORK_DIR=|where provisioning keeps sources, the build, client data, configs, logs and secrets (empty: ~/.local/share/teldrassil)"
    "SOURCE_DIR=|the source checkouts: mangos-classic/, playerbots/, classic-db/ (empty: WORK_DIR/src)"
    "CLIENT_DIR=|the 1.12.1 client, for 'extract' (holds Data/)"
    "BUILD_IMAGE=localhost/teldrassil-build:latest|the build, tools and server image"
    "DB_IMAGE=docker.io/library/mariadb:11.4|the database image"
    "DB_VOLUME=teldrassil-db|the database's volume"
    "DB_PORT=3307|the database's port, on 127.0.0.1 only"
    "DB_TIMEOUT=120|seconds provisioning waits for the database to answer"
    "BUILD_JOBS=0|compile jobs (0: one per CPU)"
    "REALM_NAME=Teldrassil|the realm's name in the realm list"
    "REALM_ADDRESS=127.0.0.1|the address clients connect to after login (this host's LAN address for LAN play)"
    "BOTS=100|random bots for a new configuration ('configure'); the roster can change it later"
    "SOURCE_REPO=|one repository holding mangos-classic/, playerbots/, classic-db/ (and zlib/) - kalimdor; empty: the three upstreams below"
    "SOURCE_REF=main|the branch, tag or commit of SOURCE_REPO 'source' checks out"
    "MANGOS_REPO=https://github.com/cmangos/mangos-classic.git|cmangos-classic's repository"
    "MANGOS_REF=ff53dfc4679cab3521726384e24692fef35d2718|the cmangos-classic commit 'source' checks out"
    "PLAYERBOTS_REPO=https://github.com/cmangos/playerbots.git|playerbots' repository"
    "PLAYERBOTS_REF=39d47006e4aa1658c7e17af15e4f63d47ec5a3eb|the playerbots commit 'source' checks out"
    "CLASSICDB_REPO=https://github.com/cmangos/classic-db.git|classic-db's repository"
    "CLASSICDB_REF=2f5b31bc32e80f121d78656817fbc5d6c3b1e99c|the classic-db commit 'source' checks out"
)

# _cfg_bad <key> <value> — what is wrong with that value, or nothing. Database
# names and the bot account prefix go into SQL (and InstallFullDB.config)
# unquoted, so they are names, nothing more.
_cfg_bad() {
    case "$1" in
        SERVER_KIND)
            [[ "$2" == podman || "$2" == kube ]] || printf "SERVER_KIND is podman or kube (got '%s')." "$2" ;;
        RA_PORT|WORLD_PORT|REALM_PORT|START_TIMEOUT|STOP_TIMEOUT|BOTS_TIMEOUT|DB_TIMEOUT|DB_PORT|BUILD_JOBS|BOTS)
            [[ "$2" =~ ^[0-9]+$ ]] || printf "%s must be a number (got '%s')." "$1" "$2" ;;
        FRESH_STOP_WAIT)
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || printf "%s must be a number of seconds above 0 (got '%s')." "$1" "$2" ;;
        DB_WORLD|DB_CHARACTERS|DB_REALMD|DB_LOGS)
            [[ "$2" =~ ^[A-Za-z0-9_]{1,64}$ ]] || printf "%s is a database name: letters, digits and underscores (got '%s')." "$1" "$2" ;;
        BOT_ACCOUNT_PREFIX)
            [[ "$2" =~ ^[A-Za-z0-9]{1,16}$ ]] || printf "BOT_ACCOUNT_PREFIX is 1-16 letters or digits (got '%s')." "$2" ;;
    esac
    return 0
}

_cfg_default() {
    local entry
    for entry in "${CONFIG_KEYS[@]}"; do
        [[ "${entry%%=*}" == "$1" ]] && { entry="${entry#*=}"; printf '%s' "${entry%%|*}"; return 0; }
    done
    return 1
}
_cfg_known() { _cfg_default "$1" >/dev/null; }
_cfg_has()  { grep -qE "^${2}=" "$1" 2>/dev/null; }
_cfg_read() { grep -E "^${2}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true; }
# _cfg_target — where 'set' writes: the active profile, or the base file.
_cfg_target() { printf '%s' "${PROFILE_FILE:-$CONFIG_FILE}"; }

cfg_get() {
    if [[ -n "$PROFILE_FILE" ]] && _cfg_has "$PROFILE_FILE" "$1"; then _cfg_read "$PROFILE_FILE" "$1"
    elif _cfg_has "$CONFIG_FILE" "$1"; then _cfg_read "$CONFIG_FILE" "$1"
    else _cfg_default "$1" || true; fi
}

# _profile_activate <name> — point the config at a profile. Only the name is
# checked here: 'set' may create the file; _profile_require refuses the rest.
_profile_activate() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$1" != *..* ]] \
        || error_exit "profile: invalid name '${1}' (letters, digits, then . _ - )."
    PROFILE="$1"; PROFILE_FILE="${PROFILE_DIR}/${1}.conf"
}
_profile_deactivate() { PROFILE=""; PROFILE_FILE=""; }

# _profile_require <command> — a profile that does not exist is an error, so a
# typo does not silently act on the base config's server.
_profile_require() {
    [[ -z "$PROFILE_FILE" || -f "$PROFILE_FILE" ]] && return 0
    case "$1" in set|profiles|profile-rename|profile-delete|help|-h|--help) return 0 ;; esac
    error_exit "No such profile: '${PROFILE}' (${PROFILE_FILE} does not exist). 'profiles' lists them; '--profile ${PROFILE} set KEY VALUE' creates it."
}

cmd_profiles() {
    [[ $# -eq 0 ]] || error_exit "Usage: profiles"
    local f n mark found=0
    for f in "$PROFILE_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        found=1; n="$(basename "$f" .conf)"; mark=" "
        [[ "$n" == "$PROFILE" ]] && mark="*"
        printf '%s %s\n' "$mark" "$n"
    done
    (( found )) || info "No profiles yet: '--profile NAME set KEY VALUE' creates one."
    [[ -n "$PROFILE" ]] && printf '\n* = active (%s)\n' "${TELDRASSIL_PROFILE:+from \$TELDRASSIL_PROFILE or }--profile"
    return 0
}

cfg_set() {
    local key="$1" val="$2" tmp target; target="$(_cfg_target)"
    _cfg_known "$key" || error_exit "set: unknown key '${key}' (see 'config')."
    [[ "$val" != *[$'\r\n']* ]] || error_exit "set: ${key}: the value must not contain a newline."
    local bad; bad="$(_cfg_bad "$key" "$val")"
    [[ -z "$bad" ]] || error_exit "set: ${bad}"
    _mkdir_private "$CONFIG_DIR"
    _mkdir_private "$(dirname "$target")"
    tmp="$(mktemp "$(dirname "$target")/.conf.XXXXXX")"
    grep -vE "^${key}=" "$target" 2>/dev/null > "$tmp" || true
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$target"
}

# _settings — read every setting into a shell variable of the same name.
_settings() {
    local entry key
    for entry in "${CONFIG_KEYS[@]}"; do
        key="${entry%%=*}"
        printf -v "$key" '%s' "$(cfg_get "$key")"
    done
    # A config file edited by hand gets the checks 'set' makes.
    local bad
    for key in SERVER_KIND RA_PORT WORLD_PORT REALM_PORT START_TIMEOUT STOP_TIMEOUT BOTS_TIMEOUT FRESH_STOP_WAIT DB_TIMEOUT DB_PORT \
               BUILD_JOBS BOTS DB_WORLD DB_CHARACTERS DB_REALMD DB_LOGS BOT_ACCOUNT_PREFIX; do
        bad="$(_cfg_bad "$key" "${!key}")"
        [[ -z "$bad" ]] || error_exit "${bad} Fix it with 'set ${key} VALUE'."
    done
    WORK_DIR="${WORK_DIR/#\~/$HOME}"; SOURCE_DIR="${SOURCE_DIR/#\~/$HOME}"; CLIENT_DIR="${CLIENT_DIR/#\~/$HOME}"
    [[ -n "$WORK_DIR" ]] || WORK_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teldrassil"
    [[ -n "$SOURCE_DIR" ]] || SOURCE_DIR="${WORK_DIR}/src"
    [[ -n "$BOT_CONF" || -z "$ETC_DIR" ]] || BOT_CONF="${ETC_DIR}/aiplayerbot.conf"
    [[ -n "$CARDS_FILE" || -z "$ETC_DIR" ]] || CARDS_FILE="${ETC_DIR}/llm_character_card.txt"
    # Paths may be written with ~.
    RA_PASS_FILE="${RA_PASS_FILE/#\~/$HOME}"; ETC_DIR="${ETC_DIR/#\~/$HOME}"
    BOT_CONF="${BOT_CONF/#\~/$HOME}"; CARDS_FILE="${CARDS_FILE/#\~/$HOME}"; ROSTER_FILE="${ROSTER_FILE/#\~/$HOME}"; DBC_DIR="${DBC_DIR/#\~/$HOME}"
}

# cfg_unset <key> — drop a key from where 'set' writes, so the profile falls
# through to the base config (or the base to the default).
cfg_unset() {
    local key="$1" tmp target; target="$(_cfg_target)"
    _cfg_known "$key" || error_exit "unset: unknown key '${key}' (see 'config')."
    _cfg_has "$target" "$key" || { info "${key} is not set${PROFILE:+ in profile ${PROFILE}}; nothing to do."; return 0; }
    tmp="$(mktemp "$(dirname "$target")/.conf.XXXXXX")"
    grep -vE "^${key}=" "$target" > "$tmp" || true
    chmod 600 "$tmp"
    mv -f "$tmp" "$target"
    success "${key} unset${PROFILE:+ in profile ${PROFILE}}; it is now '$(cfg_get "$key")'."
}

cmd_unset() {
    [[ $# -eq 1 ]] || error_exit "Usage: unset KEY"
    cfg_unset "$1"
}

# _profile_file <name> — the file of an EXISTING profile.
_profile_file() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$1" != *..* ]] || error_exit "Invalid profile name '${1}'."
    [[ -f "${PROFILE_DIR}/${1}.conf" ]] || error_exit "No such profile: '${1}' ('profiles' lists them)."
    printf '%s' "${PROFILE_DIR}/${1}.conf"
}

# profile-rename OLD NEW — the file, and the console password file that
# console-account made for it (console-OLD.txt), with the setting pointing at it.
cmd_profile_rename() {
    [[ $# -eq 2 ]] || error_exit "Usage: profile-rename OLD NEW"
    local old new
    old="$(_profile_file "$1")"
    [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$2" != *..* ]] || error_exit "Invalid profile name '${2}'."
    new="${PROFILE_DIR}/${2}.conf"
    [[ ! -e "$new" ]] || error_exit "Profile '${2}' already exists."
    mv -- "$old" "$new"
    local c_old="${CONFIG_DIR}/console-${1}.txt" c_new="${CONFIG_DIR}/console-${2}.txt"
    if [[ -f "$c_old" && ! -e "$c_new" ]] && [[ "$(_cfg_read "$new" RA_PASS_FILE)" == "$c_old" ]]; then
        mv -- "$c_old" "$c_new"
        PROFILE="$2"; PROFILE_FILE="$new"; cfg_set RA_PASS_FILE "$c_new"
    fi
    success "Profile '${1}' is now '${2}'."
}

# profile-delete NAME --yes — the profile's settings only. The server and its
# accounts are untouched; a console password file console-account made for
# it is kept, and named, since it is the only copy of that password.
cmd_profile_delete() {
    local name="" yes=0 f c
    while [[ $# -gt 0 ]]; do case "$1" in
        --yes) yes=1; shift ;;
        -*) error_exit "profile-delete: unknown flag $1" ;;
        *) [[ -z "$name" ]] || error_exit "Usage: profile-delete NAME --yes"; name="$1"; shift ;;
    esac; done
    [[ -n "$name" ]] || error_exit "Usage: profile-delete NAME --yes"
    f="$(_profile_file "$name")"
    (( yes )) || error_exit "profile-delete removes the profile's settings for good: add --yes."
    c="$(_cfg_read "$f" RA_PASS_FILE)"
    rm -f -- "$f"
    success "Profile '${name}' deleted (the server it pointed at is untouched)."
    [[ -n "$c" && -f "$c" ]] && info "Its console password file is kept: ${c}"
    return 0
}

cmd_set() {
    [[ $# -eq 2 ]] || error_exit "Usage: set KEY VALUE"
    cfg_set "$1" "$2"
    success "${1} set${PROFILE:+ in profile ${PROFILE}}."
}

cmd_get() {
    [[ $# -eq 1 ]] || error_exit "Usage: get KEY"
    _cfg_known "$1" || error_exit "get: unknown key '${1}'."
    cfg_get "$1"; echo
}

cmd_config() {
    local entry key val mark
    printf 'Config file: %s\n' "$CONFIG_FILE"
    [[ -n "$PROFILE" ]] && printf 'Profile:     %s (%s)\n' "$PROFILE" "$PROFILE_FILE"
    echo
    for entry in "${CONFIG_KEYS[@]}"; do
        key="${entry%%=*}"; val="$(cfg_get "$key")"
        mark=" "
        if [[ -n "$PROFILE_FILE" ]] && _cfg_has "$PROFILE_FILE" "$key"; then mark="P"
        elif _cfg_has "$CONFIG_FILE" "$key"; then mark="*"; fi
        printf '%s %-22s %-40s %s\n' "$mark" "$key" "${val:-(empty)}" "${entry#*|}"
    done
    printf '\n* = set in the config file%s; the rest are defaults.\n' "${PROFILE:+, P = set in the profile}"
}
