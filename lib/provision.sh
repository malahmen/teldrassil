# shellcheck shell=bash
# lib/provision.sh — From nothing to a running server: source, build-image,
# build, extract, db-init, configure, create, install (all of them), remove.
#
# Everything lives under WORK_DIR (default ~/.local/share/teldrassil):
#   src/       the source checkouts, at pinned commits (or SOURCE_DIR)
#   build/     cmake's build tree      install/  the compiled server and tools
#   data/      maps, vmaps, mmaps, dbc extracted from the client
#   etc/       the server's config files (or ETC_DIR)      logs/  every log
#   secrets/   database passwords and the console account (0700, files 0600)
#
# Passwords never reach a command line: MariaDB and the installer read them
# from files mounted into their containers, and the config files get them
# through the helper's --secret-file.
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

_paths() {
    SRC_MANGOS="${SOURCE_DIR}/mangos-classic"
    SRC_PB="${SOURCE_DIR}/playerbots"
    SRC_DB="${SOURCE_DIR}/classic-db"
    BUILD_OUT="${WORK_DIR}/build"
    INSTALL="${WORK_DIR}/install"
    DATA="${WORK_DIR}/data"
    LOGS="${WORK_DIR}/logs"
    SECRETS="${WORK_DIR}/secrets"
    ETC="${ETC_DIR:-${WORK_DIR}/etc}"
    PATCH_DIR="${SCRIPT_DIR}/templates/patches"
}

# _random_word <length> [upper] — random letters and digits. Not
# `tr < /dev/urandom | head`: when head stops reading, tr can die of SIGPIPE,
# and under pipefail that ends the script without a word.
_random_word() {
    python3 -I -c 'import secrets, string, sys
chars = string.ascii_uppercase + string.digits if len(sys.argv) > 2 else string.ascii_letters + string.digits
print("".join(secrets.choice(chars) for _ in range(int(sys.argv[1]))), end="")' "$1" ${2:+"$2"}
}

_secret() {
    # _secret <name> — the path of a generated secret, created on first use:
    # 24 random letters and digits, owner-only.
    local f="${SECRETS}/$1"
    if [[ ! -s "$f" ]]; then
        _mkdir_private "$SECRETS"
        (umask 077; _random_word 24 > "$f")
    fi
    printf '%s' "$f"
}

_log_tail() { tail -"${2:-15}" -- "$1" | sed 's/^/    /' >&2; }

# _run_tools <log> <podman run args...> -- <command> — a throwaway container
# from the build image; output to the log, and its tail shown on failure.
_run_tools() {
    local log="$1"; shift
    mkdir -p "$LOGS"
    if ! "$PODMAN" run --rm "$@" > "$log" 2>&1 </dev/null; then
        _log_tail "$log"
        error_exit "Failed; the full log is ${log}."
    fi
}

_require_image() {
    "$PODMAN" image exists "$BUILD_IMAGE" || error_exit "No image ${BUILD_IMAGE}: run 'build-image' first."
}

# -----------------------------------------------------------------------------
# source — the pinned checkouts
# -----------------------------------------------------------------------------

# _checkout <dir> <repo> <ref> <update> — a shallow checkout of exactly <ref>.
_checkout() {
    local dir="$1" repo="$2" ref="$3" update="$4" head
    if [[ -d "${dir}/.git" ]]; then
        head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
        if [[ "$head" == "$ref"* ]]; then info "$(basename "$dir"): at ${ref:0:12}."; return 0; fi
        if (( ! update )); then
            warn "$(basename "$dir") is at ${head:0:12}, not the pinned ${ref:0:12}; 'source --update' moves it."
            return 0
        fi
        _unpatch "$dir"
        [[ -z "$(git -C "$dir" status --porcelain)" ]] || error_exit "$(basename "$dir") has local changes; commit or remove them first."
    else
        [[ ! -e "$dir" ]] || error_exit "${dir} exists but is not a git checkout."
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$repo"
    fi
    info "$(basename "$dir"): fetching ${ref:0:12}..."
    git -C "$dir" fetch -q --depth 1 origin "$ref" || error_exit "Could not fetch ${ref} from ${repo}."
    git -C "$dir" checkout -q --detach FETCH_HEAD
    success "$(basename "$dir"): at ${ref:0:12}."
}

# _checkout_repo <dir> <repo> <ref> <update> — one repository holding every
# tree, at a branch, tag or commit: cloned once, moved only with --update,
# never over local changes.
_checkout_repo() {
    local dir="$1" repo="$2" ref="$3" update="$4"
    if [[ ! -d "${dir}/.git" ]]; then
        [[ ! -e "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]] || error_exit "${dir} exists and is not a checkout of ${repo}."
        info "Cloning ${repo} (${ref}) into ${dir}..."
        git clone -q --branch "$ref" "$repo" "$dir" 2>/dev/null \
            || { git clone -q "$repo" "$dir" && git -C "$dir" checkout -q "$ref"; } \
            || error_exit "Could not clone ${repo} at ${ref}."
        success "Sources: ${repo} at $(git -C "$dir" rev-parse --short HEAD)."
        return 0
    fi
    if (( ! update )); then info "Sources: ${dir} at $(git -C "$dir" rev-parse --short HEAD) ('source --update' fetches ${ref})."; return 0; fi
    [[ -z "$(git -C "$dir" status --porcelain)" ]] || error_exit "${dir} has local changes; commit or remove them first."
    git -C "$dir" fetch -q origin "$ref" || error_exit "Could not fetch ${ref} from ${repo}."
    git -C "$dir" checkout -q --detach FETCH_HEAD
    success "Sources: ${repo} at $(git -C "$dir" rev-parse --short HEAD)."
}

cmd_source() {
    local update=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --update) update=1; shift ;;
        *) error_exit "source: unknown flag $1" ;;
    esac; done
    command -v git >/dev/null || error_exit "git is required."
    _paths
    # One repository with all three trees (kalimdor), or the three upstreams.
    if [[ -n "$SOURCE_REPO" ]]; then
        _checkout_repo "$SOURCE_DIR" "$SOURCE_REPO" "$SOURCE_REF" "$update"
        local t
        for t in mangos-classic playerbots classic-db; do
            [[ -d "${SOURCE_DIR}/${t}" ]] || error_exit "${SOURCE_REPO} has no ${t}/: it is not a source tree teldrassil can build."
        done
        return 0
    fi
    if git -C "$SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null | grep -qxF -- "$(cd "$SOURCE_DIR" 2>/dev/null && pwd -P)"; then
        info "${SOURCE_DIR} is one repository (set SOURCE_REPO to have 'source' manage it); left as it is."
        return 0
    fi
    mkdir -p "$SOURCE_DIR"
    _checkout "$SRC_MANGOS" "$MANGOS_REPO" "$MANGOS_REF" "$update"
    _checkout "$SRC_PB" "$PLAYERBOTS_REPO" "$PLAYERBOTS_REF" "$update"
    _checkout "$SRC_DB" "$CLASSICDB_REPO" "$CLASSICDB_REF" "$update"
}

# Our playerbots changes (templates/patches/playerbots/*.patch), applied to
# the checkout before every build and taken off before it moves.
# _apply <dir> <git apply args...> — git apply, right in a subfolder too. In a
# subfolder of a bigger repository (kalimdor's playerbots/), git apply skips
# every file outside it, so a patch whose paths are relative to playerbots
# became empty and every check passed - "already applied" on a tree that is
# not. --directory puts the paths where they are.
_apply() {
    local dir="$1"; shift
    local prefix; prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then git -C "$dir" apply --directory="${prefix%/}" "$@"; else git -C "$dir" apply "$@"; fi
}

_patch() {
    local p
    for p in "${PATCH_DIR}"/playerbots/*.patch; do
        [[ -f "$p" ]] || continue
        if _apply "$SRC_PB" --reverse --check "$p" 2>/dev/null; then
            info "Patch $(basename "$p"): already applied."
        elif _apply "$SRC_PB" --check "$p" 2>/dev/null; then
            _apply "$SRC_PB" "$p"; success "Patch $(basename "$p"): applied."
        else
            error_exit "Patch $(basename "$p") does not apply to playerbots at $(git -C "$SRC_PB" rev-parse --short HEAD); it needs updating for that commit."
        fi
    done
}
_unpatch() {
    local dir="$1" p
    [[ "$dir" == "$SRC_PB" ]] || return 0
    for p in "${PATCH_DIR}"/playerbots/*.patch; do
        [[ -f "$p" ]] || continue
        if _apply "$dir" --reverse --check "$p" 2>/dev/null; then _apply "$dir" --reverse "$p"; fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# build-image, build, extract
# -----------------------------------------------------------------------------

cmd_build_image() {
    [[ $# -eq 0 ]] || error_exit "Usage: build-image"
    _paths
    info "Building ${BUILD_IMAGE} (Ubuntu 24.04 with the build tools and the mariadb client)..."
    mkdir -p "$LOGS"
    if ! "$PODMAN" build -t "$BUILD_IMAGE" -f "${SCRIPT_DIR}/templates/Containerfile" "${SCRIPT_DIR}/templates" > "${LOGS}/build-image.log" 2>&1; then
        _log_tail "${LOGS}/build-image.log"; error_exit "Image build failed; see ${LOGS}/build-image.log."
    fi
    success "Image ${BUILD_IMAGE} built."
}

cmd_build() {
    local jobs="$BUILD_JOBS" clean=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --jobs) _need_value "$@"; jobs="$2"; shift 2 ;;
        --clean) clean=1; shift ;;
        *) error_exit "build: unknown flag $1" ;;
    esac; done
    [[ "$jobs" =~ ^[0-9]+$ ]] || error_exit "--jobs must be a number."
    (( jobs > 0 )) || jobs="$(nproc)"
    _paths; _require_image
    [[ -d "$SRC_MANGOS" && -d "$SRC_PB" ]] || error_exit "No sources in ${SOURCE_DIR}: run 'source' first."
    _patch
    if (( clean )) && [[ -d "$BUILD_OUT" ]]; then info "Clearing the build tree."; rm -r -- "${BUILD_OUT:?}"; fi
    mkdir -p "$BUILD_OUT" "$INSTALL"
    # playerbots sits inside the cmangos tree, where its CMake expects it.
    # cmangos fetches zlib from GitHub while configuring; sources with their
    # own zlib/ (kalimdor) are used instead, and then nothing needs the
    # network: the build runs with none.
    local -a zlib=() net=()
    local zflags=""
    if [[ -f "${SOURCE_DIR}/zlib/zlib.h" ]]; then
        zlib=(-v "${SOURCE_DIR}/zlib:/src/zlib:ro,z"); net=(--network none)
        zflags="-DFETCHCONTENT_SOURCE_DIR_ZLIB=/src/zlib -DFETCHCONTENT_FULLY_DISCONNECTED=ON"
        info "Compiling cmangos-classic with playerbots on ${jobs} jobs, offline, with the vendored zlib (the log is ${LOGS}/build.log)..."
    else
        info "Compiling cmangos-classic with playerbots on ${jobs} jobs (tens of minutes the first time; zlib is fetched from GitHub; the log is ${LOGS}/build.log)..."
    fi
    _run_tools "${LOGS}/build.log" "${net[@]}" \
        -v "${SRC_MANGOS}:/src/mangos-classic:z" -v "${SRC_PB}:/src/mangos-classic/src/modules/PlayerBots:z" "${zlib[@]}" \
        -v "${BUILD_OUT}:/build:z" -v "${INSTALL}:/install:z" "$BUILD_IMAGE" bash -c "set -e
            [[ -f /build/CMakeCache.txt ]] || cmake -S /src/mangos-classic -B /build -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/install -DBUILD_PLAYERBOTS=ON -DBUILD_EXTRACTORS=ON -DBUILD_AHBOT=OFF -DPCH=ON \
                -DFETCHCONTENT_SOURCE_DIR_PLAYERBOTS=/src/mangos-classic/src/modules/PlayerBots ${zflags}
            cmake --build /build -j${jobs}
            cmake --install /build"
    [[ -x "${INSTALL}/bin/mangosd" && -x "${INSTALL}/bin/realmd" ]] || error_exit "The build ran but left no mangosd/realmd in ${INSTALL}/bin."
    success "Built: ${INSTALL}/bin."
}

_data_ready() { [[ -d "${DATA}/dbc" && -d "${DATA}/maps" && -d "${DATA}/vmaps" && -d "${DATA}/mmaps" ]]; }

cmd_extract() {
    local client="$CLIENT_DIR" force=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --client) _need_value "$@"; client="${2/#\~/$HOME}"; shift 2 ;;
        --force) force=1; shift ;;
        *) error_exit "extract: unknown flag $1" ;;
    esac; done
    _paths; _require_image
    if _data_ready && (( ! force )); then info "Client data is already in ${DATA} (--force extracts again)."; return 0; fi
    [[ -n "$client" ]] || error_exit "Where is the 1.12.1 client? --client PATH, or set CLIENT_DIR."
    [[ -d "${client}/Data" ]] || error_exit "${client} has no Data/ folder: not a 1.12.1 client."
    [[ -x "${INSTALL}/bin/tools/ExtractResources.sh" || -f "${INSTALL}/bin/tools/ExtractResources.sh" ]] \
        || error_exit "No extractors in ${INSTALL}/bin/tools: run 'build' first."
    mkdir -p "$DATA"
    info "Extracting dbc, maps, vmaps and mmaps from ${client} (about 20 minutes on many cores; ~2.4 GB)..."
    _run_tools "${LOGS}/extract.log" -v "${client}:/client:ro,z" -v "${INSTALL}/bin/tools:/tools:ro,z" \
        -v "${DATA}:/data:z" -w /tools "$BUILD_IMAGE" bash ./ExtractResources.sh a /client /data
    _data_ready || error_exit "The extractors ran but ${DATA} is incomplete; see ${LOGS}/extract.log."
    success "Client data extracted to ${DATA}."
}

# -----------------------------------------------------------------------------
# db-init
# -----------------------------------------------------------------------------

_db_container_up() {
    local root; root="$(_secret root.pw)"
    if ! _container_exists "$DB_CONTAINER"; then
        info "Creating the database container ${DB_CONTAINER} (127.0.0.1:${DB_PORT}, volume ${DB_VOLUME})..."
        "$PODMAN" volume exists "$DB_VOLUME" || "$PODMAN" volume create "$DB_VOLUME" >/dev/null
        "$PODMAN" run -d --name "$DB_CONTAINER" --restart on-failure -p "127.0.0.1:${DB_PORT}:3306" \
            -v "${DB_VOLUME}:/var/lib/mysql" -v "${root}:${DB_PASS_FILE}:ro,z" \
            -e "MARIADB_ROOT_PASSWORD_FILE=${DB_PASS_FILE}" "$DB_IMAGE" >/dev/null
    elif ! _container_running "$DB_CONTAINER"; then
        "$PODMAN" start "$DB_CONTAINER" >/dev/null
    fi
    local deadline=$((SECONDS + 120))
    until printf 'SELECT 1;\n' | _db_raw >/dev/null 2>&1; do
        (( SECONDS < deadline )) || error_exit "The database did not answer within 120s: '${PODMAN} logs ${DB_CONTAINER}'."
        sleep 2
    done
    success "Database ${DB_CONTAINER} is up."
}

cmd_db_init() {
    local yes=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --yes) yes=1; shift ;;
        *) error_exit "db-init: unknown flag $1" ;;
    esac; done
    _paths; _require_image
    [[ -d "$SRC_DB" && -d "$SRC_MANGOS" && -d "$SRC_PB" ]] || error_exit "No sources in ${SOURCE_DIR}: run 'source' first."
    (( yes )) || error_exit "db-init creates the four databases and REPLACES any that exist (classic-db's DeleteAll): add --yes."
    if _container_running "$SERVER_CONTAINER"; then error_exit "Stop the world server first ('stop')."; fi
    _db_container_up
    local root mangos; root="$(_secret root.pw)"; mangos="$(_secret mangos.pw)"

    # classic-db's installer reads this file from its own folder; it holds no
    # password - it reads them from the mounted files when it is sourced.
    cat > "${SRC_DB}/InstallFullDB.config" <<EOF
# Written by teldrassil db-init. Passwords are read from mounted files.
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="${DB_PORT}"
MYSQL_USERNAME="mangos"
MYSQL_PASSWORD="\$(cat /run/pw/mangos.pw)"
MYSQL_USERIP="%"
MYSQL_COLSTAT=""
WORLD_DB_NAME="${DB_WORLD}"
REALM_DB_NAME="${DB_REALMD}"
CHAR_DB_NAME="${DB_CHARACTERS}"
LOGS_DB_NAME="${DB_LOGS}"
MYSQL_PATH="/usr/bin/mariadb"
CORE_PATH="/src/mangos-classic"
MYSQL_DUMP_PATH="/usr/bin/mariadb-dump"
LOCALES="NO"
DEV_UPDATES="NO"
AHBOT="NO"
PLAYERBOTS_DB="YES"
FORCE_WAIT="NO"
EOF
    info "Installing the databases (classic-db with playerbots' tables; a few minutes; the log is ${LOGS}/db-install.log)..."
    _run_tools "${LOGS}/db-install.log" --network host \
        -v "${SRC_MANGOS}:/src/mangos-classic:z" -v "${SRC_PB}:/src/mangos-classic/src/modules/PlayerBots:z" \
        -v "${SRC_DB}:/src/classic-db:z" -v "${root}:/run/pw/root.pw:ro,z" -v "${mangos}:/run/pw/mangos.pw:ro,z" \
        -w /src/classic-db "$BUILD_IMAGE" bash -c 'set -- -InstallAll root "$(cat /run/pw/root.pw)" DeleteAll; source ./InstallFullDB.sh'
    if grep -qiE '^(ERROR [0-9]+|.*\bfailed\b)' "${LOGS}/db-install.log"; then
        _log_tail "${LOGS}/db-install.log"; error_exit "The installer reported errors; see ${LOGS}/db-install.log."
    fi
    [[ "$(_db_value "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_WORLD}' AND TABLE_NAME='ai_playerbot_help_texts';")" == "1" ]] \
        || error_exit "The world database has no playerbots tables; see ${LOGS}/db-install.log."
    success "Databases installed."

    _db_finish
}

# _db_finish — the steps after the databases exist, each safe to repeat: the
# realm's row, cmangos' default accounts gone, teldrassil's console account.
# install runs it on a server whose databases are already there, so an
# install that stopped part-way finishes.
_db_finish() {
    _paths
    printf '%s\n' "UPDATE ${DB_REALMD}.realmlist SET name=$(_sql_str "$REALM_NAME"), address=$(_sql_str "$REALM_ADDRESS"), port=${WORLD_PORT} WHERE id=1;" | _db_raw
    success "Realm: ${REALM_NAME} at ${REALM_ADDRESS}:${WORLD_PORT}."

    # cmangos ships four accounts with well-known passwords; a new server has
    # no characters on them, so they go.
    local defaults="'ADMINISTRATOR','GAMEMASTER','MODERATOR','PLAYER'"
    if [[ "$(_db_value "SELECT COUNT(*) FROM ${DB_CHARACTERS}.characters c JOIN ${DB_REALMD}.account a ON a.id=c.account WHERE a.username IN (${defaults});")" != "0" ]]; then
        warn "cmangos' default accounts have characters, so they are kept; delete them with 'delete-account' once those are gone."
    else
        printf '%s\n' "DELETE FROM ${DB_REALMD}.realmcharacters WHERE acctid IN (SELECT id FROM ${DB_REALMD}.account WHERE username IN (${defaults}));" \
            "DELETE FROM ${DB_REALMD}.account WHERE username IN (${defaults});" | _db_raw
        success "cmangos' default accounts removed."
    fi

    # teldrassil's own console account, so 'stop' can save and 'console' works.
    local console="${SECRETS}/console.txt" pw v s
    if [[ -s "$console" && "$(_db_value "SELECT COUNT(*) FROM ${DB_REALMD}.account WHERE username='TELDRASSIL';")" == "1" ]]; then
        info "Console account TELDRASSIL: present."
        cfg_set RA_PASS_FILE "$console"; cfg_set RA_USER TELDRASSIL
        return 0
    fi
    pw="$(_random_word 12 upper)"
    read -r v s < <(printf '%s\n' "$pw" | helper srp6 --user TELDRASSIL)
    printf '%s\n' "DELETE FROM ${DB_REALMD}.account WHERE username='TELDRASSIL';" \
        "INSERT INTO ${DB_REALMD}.account (username, v, s, gmlevel, joindate) VALUES ('TELDRASSIL', '${v}', '${s}', 3, NOW());" | _db_raw
    (umask 077; printf 'teldrassil console account\naccount: TELDRASSIL\npassword: %s\n' "$pw" > "$console")
    unset pw
    cfg_set RA_PASS_FILE "$console"; cfg_set RA_USER TELDRASSIL
    success "Console account TELDRASSIL created (password in ${console})."
}

# -----------------------------------------------------------------------------
# configure, create
# -----------------------------------------------------------------------------

# _render <dist> <out> <force> --set K=V ... — a config file from its shipped
# template, only if absent (or --force); owner-only, since it holds the
# database password.
_render() {
    local dist="$1" out="$2" force="$3"; shift 3
    [[ -f "$dist" ]] || error_exit "No ${dist}: run 'build' first."
    if [[ -f "$out" ]] && (( ! force )); then info "$(basename "$out"): kept (--force rewrites it from the template)."; return 0; fi
    [[ -f "$out" ]] && _backup "$out"
    local tmp; tmp="$(tmp_dir)/$(basename "$out")"
    helper conf --conf "$dist" --out "$tmp" --require --secret-file "$(_secret mangos.pw)" "$@" >/dev/null
    (umask 077; cat -- "$tmp" > "$out"); chmod 600 "$out"
    success "$(basename "$out") written."
}

cmd_configure() {
    local force=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --force) force=1; shift ;;
        *) error_exit "configure: unknown flag $1" ;;
    esac; done
    _paths
    mkdir -p "$ETC" "$LOGS"
    local E="${INSTALL}/etc" accounts=$(( (BOTS + 4) / 5 + 4 )) guilds=$(( BOTS / 5 > 0 ? BOTS / 5 : 1 ))
    db() { printf '"127.0.0.1;%s;mangos;@SECRET@;%s"' "$DB_PORT" "$1"; }
    _render "${E}/mangosd.conf.dist" "${ETC}/mangosd.conf" "$force" \
        --set 'DataDir="/data"' --set 'LogsDir="/logs"' \
        --set "LoginDatabaseInfo=$(db "$DB_REALMD")" --set "WorldDatabaseInfo=$(db "$DB_WORLD")" \
        --set "CharacterDatabaseInfo=$(db "$DB_CHARACTERS")" --set "LogsDatabaseInfo=$(db "$DB_LOGS")" \
        --set "WorldServerPort=${WORLD_PORT}" --set "Console.Enable=0" \
        --set "Ra.Enable=1" --set "Ra.IP=127.0.0.1" --set "Ra.Port=${RA_PORT}"
    _render "${E}/realmd.conf.dist" "${ETC}/realmd.conf" "$force" \
        --set "LoginDatabaseInfo=$(db "$DB_REALMD")" --set 'LogsDir="/logs"' --set "RealmServerPort=${REALM_PORT}"
    # Bot accounts: one per five bots, plus four. playerbots fills accounts
    # before it honours every fixed class/race count, so a tight fit leaves
    # pairs uncreated (20 bots on 4 accounts did; on 8 they all were).
    # Bots fully active everywhere (they stand in for players), and in the
    # battleground queues; LLM chat off until 'llm on'; one random guild per
    # five bots (playerbots' default 20 swallows a small population). The
    # roster sets the rest.
    _render "${E}/aiplayerbot.conf.dist" "${ETC}/aiplayerbot.conf" "$force" \
        --set "AiPlayerbot.MinRandomBots=${BOTS}" --set "AiPlayerbot.MaxRandomBots=${BOTS}" \
        --set "AiPlayerbot.RandomBotAccountCount=${accounts}" \
        --set "AiPlayerbot.DisableActivityPriorities=1" --set "AiPlayerbot.DisableBotOptimizations=1" \
        --set "AiPlayerbot.RandomBotAutoJoinBG=1" --set "AiPlayerbot.LLMEnabled=0" \
        --set "AiPlayerbot.RandomBotGuildCount=${guilds}"
    _render "${E}/ahbot.conf.dist" "${ETC}/ahbot.conf" "$force"
    [[ -n "$(cfg_get ETC_DIR)" ]] || cfg_set ETC_DIR "$ETC"
    return 0
}

_server_mounts() {
    SERVER_MOUNTS=(-v "${INSTALL}/bin:/install/bin:ro,z" -v "${ETC}:/install/etc:ro,z"
                   -v "${DATA}:/data:ro,z" -v "${LOGS}:/logs:z")
}

cmd_create() {
    local force=0 c
    while [[ $# -gt 0 ]]; do case "$1" in
        --force) force=1; shift ;;
        *) error_exit "create: unknown flag $1" ;;
    esac; done
    _paths; _require_image
    [[ -x "${INSTALL}/bin/mangosd" ]] || error_exit "No server in ${INSTALL}/bin: run 'build' first."
    _data_ready || error_exit "No client data in ${DATA}: run 'extract' first."
    [[ -f "${ETC}/mangosd.conf" && -f "${ETC}/realmd.conf" ]] || error_exit "No config in ${ETC}: run 'configure' first."
    for c in "$REALM_CONTAINER" "$SERVER_CONTAINER"; do
        if _container_exists "$c"; then
            if (( ! force )); then info "${c}: exists (--force recreates it)."; continue; fi
            _container_running "$c" && error_exit "${c} is running: 'stop' first."
            "$PODMAN" rm "$c" >/dev/null
        fi
        _server_mounts
        # on-failure: a crash restarts it; a stop does not.
        if [[ "$c" == "$REALM_CONTAINER" ]]; then
            "$PODMAN" create --name "$c" --network host --restart on-failure "${SERVER_MOUNTS[@]}" -w /install/bin \
                "$BUILD_IMAGE" ./realmd -c /install/etc/realmd.conf >/dev/null
        else
            "$PODMAN" create --name "$c" --network host --restart on-failure "${SERVER_MOUNTS[@]}" -w /install/bin \
                "$BUILD_IMAGE" ./mangosd -c /install/etc/mangosd.conf -a /install/etc/ahbot.conf >/dev/null
        fi
        success "${c} created."
    done
}

# -----------------------------------------------------------------------------
# install, remove
# -----------------------------------------------------------------------------

cmd_install() {
    local client="$CLIENT_DIR" yes=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --client) _need_value "$@"; client="$2"; shift 2 ;;
        --yes) yes=1; shift ;;
        *) error_exit "install: unknown flag $1" ;;
    esac; done
    (( yes )) || error_exit "install builds and starts a whole server, and creates its databases: add --yes."
    _paths
    header "1/7 Sources";      cmd_source
    header "2/7 Build image";  if "$PODMAN" image exists "$BUILD_IMAGE"; then info "${BUILD_IMAGE}: present."; else cmd_build_image; fi
    header "3/7 Build";        if [[ -x "${INSTALL}/bin/mangosd" ]]; then info "Already built (run 'build' to rebuild)."; else cmd_build; fi
    header "4/7 Client data";  if [[ -n "$client" ]]; then cmd_extract --client "$client"; else cmd_extract; fi
    header "5/7 Databases"
    if _container_exists "$DB_CONTAINER" && _container_running "$DB_CONTAINER" \
        && [[ "$(_db_value "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_WORLD}';")" == "1" ]]; then
        info "The databases exist; kept ('db-init --yes' recreates them)."
        _db_finish
    else
        cmd_db_init --yes
    fi
    _settings; _paths
    header "6/7 Configuration"; cmd_configure
    _settings; _paths
    header "7/7 Containers";   cmd_create
    header "Start";            _start
    success "Installed. 'status' shows it; the roster commands shape its bots."
}

cmd_remove() {
    local yes=0 database=0 c
    while [[ $# -gt 0 ]]; do case "$1" in
        --yes) yes=1; shift ;;
        --database) database=1; shift ;;
        *) error_exit "remove: unknown flag $1" ;;
    esac; done
    (( yes )) || error_exit "remove deletes the server's containers (with --database, the databases too): add --yes."
    _stop
    for c in "$SERVER_CONTAINER" "$REALM_CONTAINER"; do
        if _container_exists "$c"; then "$PODMAN" rm -f "$c" >/dev/null; success "${c} removed."; fi
    done
    if (( database )); then
        if _container_exists "$DB_CONTAINER"; then "$PODMAN" rm -f "$DB_CONTAINER" >/dev/null; success "${DB_CONTAINER} removed."; fi
        if "$PODMAN" volume exists "$DB_VOLUME"; then "$PODMAN" volume rm "$DB_VOLUME" >/dev/null; success "Volume ${DB_VOLUME} (every account and character) removed."; fi
    fi
    info "Files under ${WORK_DIR} are kept: sources, the build, client data, configs, secrets."
}
