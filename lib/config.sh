# shellcheck shell=bash
# lib/config.sh — The key=value config store, its defaults, and the set, get
# and config commands.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teldrassil"
CONFIG_FILE="${CONFIG_DIR}/teldrassil.conf"
BACKUP_DIR="${CONFIG_DIR}/backups"

# Every setting, with its default and what it is for. The defaults describe a
# server run by teldrassil itself; a prototype or another layout sets its own
# names with 'set'.
CONFIG_KEYS=(
    "PODMAN=podman|the container runtime (podman or docker)"
    "DB_CONTAINER=teldrassil-db|the MariaDB container"
    "DB_USER=root|the database user"
    "DB_PASS_FILE=/run/pw/root.pw|the database password file, INSIDE the database container"
    "DB_WORLD=classicmangos|the world database"
    "DB_CHARACTERS=classiccharacters|the characters database"
    "DB_REALMD=classicrealmd|the realm (accounts) database"
    "SERVER_CONTAINER=teldrassil-mangosd|the world server container"
    "REALM_CONTAINER=teldrassil-realmd|the realm (login) server container"
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
    "WORLD_PORT=8085|the world server's port"
    "REALM_PORT=3724|the realm server's port"
    "READY_PATTERN=World initialized|the world server's log line that means it is up"
    "START_TIMEOUT=300|seconds to wait for the world server to come up"
    "STOP_TIMEOUT=120|seconds the world server gets to save and stop"
    "BOTS_TIMEOUT=600|seconds to wait for bots to log in"
)

_cfg_default() {
    local entry
    for entry in "${CONFIG_KEYS[@]}"; do
        [[ "${entry%%=*}" == "$1" ]] && { entry="${entry#*=}"; printf '%s' "${entry%%|*}"; return 0; }
    done
    return 1
}
_cfg_known() { _cfg_default "$1" >/dev/null; }
_cfg_read() { grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true; }

cfg_get() {
    if grep -qE "^${1}=" "$CONFIG_FILE" 2>/dev/null; then _cfg_read "$1"; else _cfg_default "$1" || true; fi
}

cfg_set() {
    local key="$1" val="$2" tmp
    _cfg_known "$key" || error_exit "set: unknown key '${key}' (see 'config')."
    [[ "$val" != *$'\n'* ]] || error_exit "set: ${key}: the value must not contain a newline."
    case "$key" in
        RA_PORT|WORLD_PORT|REALM_PORT|START_TIMEOUT|STOP_TIMEOUT|BOTS_TIMEOUT)
            [[ "$val" =~ ^[0-9]+$ ]] || error_exit "set: ${key} must be a number (got '${val}')." ;;
    esac
    _mkdir_private "$CONFIG_DIR"
    tmp="$(mktemp "${CONFIG_DIR}/.conf.XXXXXX")"
    grep -vE "^${key}=" "$CONFIG_FILE" 2>/dev/null > "$tmp" || true
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# _settings — read every setting into a shell variable of the same name.
_settings() {
    local entry key
    for entry in "${CONFIG_KEYS[@]}"; do
        key="${entry%%=*}"
        printf -v "$key" '%s' "$(cfg_get "$key")"
    done
    [[ -n "$BOT_CONF" || -z "$ETC_DIR" ]] || BOT_CONF="${ETC_DIR}/aiplayerbot.conf"
    [[ -n "$CARDS_FILE" || -z "$ETC_DIR" ]] || CARDS_FILE="${ETC_DIR}/llm_character_card.txt"
    # Paths may be written with ~.
    RA_PASS_FILE="${RA_PASS_FILE/#\~/$HOME}"; ETC_DIR="${ETC_DIR/#\~/$HOME}"
    BOT_CONF="${BOT_CONF/#\~/$HOME}"; CARDS_FILE="${CARDS_FILE/#\~/$HOME}"; ROSTER_FILE="${ROSTER_FILE/#\~/$HOME}"
}

cmd_set() {
    [[ $# -eq 2 ]] || error_exit "Usage: set KEY VALUE"
    cfg_set "$1" "$2"
    success "${1} set."
}

cmd_get() {
    [[ $# -eq 1 ]] || error_exit "Usage: get KEY"
    _cfg_known "$1" || error_exit "get: unknown key '${1}'."
    cfg_get "$1"; echo
}

cmd_config() {
    local entry key val mark
    printf 'Config file: %s\n\n' "$CONFIG_FILE"
    for entry in "${CONFIG_KEYS[@]}"; do
        key="${entry%%=*}"; val="$(cfg_get "$key")"
        mark=" "; grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null && mark="*"
        printf '%s %-22s %-40s %s\n' "$mark" "$key" "${val:-(empty)}" "${entry#*|}"
    done
    printf '\n* = set in the config file; the rest are defaults.\n'
}
