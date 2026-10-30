#!/usr/bin/env bash
# install and db-init over a database that exists (Kamino 162): install never
# replaces a database - stopped, slow to answer, its container gone but its
# volume kept, or under other names - and db-init dumps what it replaces.
# podman is stubbed (tests/stubs/podman): no container or database runs, and
# the database installer's run (classic-db's DeleteAll) is only logged.
# shellcheck disable=SC2034  # out/rc are read by the assertions chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${TELDRASSIL:-${TEST_DIR}/../teldrassil.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH" XDG_CONFIG_HOME="$T/config" STUB_LOG="$T/podman.log" STUB_SQL_IN="$T/sql.in"
unset TELDRASSIL_PROFILE
umask 022   # what a login shell has: the files below must be private anyway
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }
run(){ out="$("$ENG" "$@" 2>&1)"; rc=$?; }

# Everything before the databases is done: sources (one repository, left as
# it is), the image, the build, the client data. install then reaches step 5.
W="$T/work"
mkdir -p "$W/src/mangos-classic" "$W/src/playerbots" "$W/src/classic-db" "$W/install/bin" \
         "$W/data/dbc" "$W/data/maps" "$W/data/vmaps" "$W/data/mmaps"
git -C "$W/src" init -q
printf '#!/bin/sh\n' > "$W/install/bin/mangosd"; chmod +x "$W/install/bin/mangosd"
run set WORK_DIR "$W"
run set DB_TIMEOUT 4
export STUB_IMAGE=1
ALL="classicmangos classiccharacters classicrealmd classiclogs"

# scenario — a clean stub: no container, no volume, nothing logged.
scenario() {
    unset STUB_RUNNING STUB_STOPPED STUB_VOLUMES STUB_DB_SLOW STUB_SCHEMAS STUB_DUMP_FAIL
    rm -rf "$T/state"; mkdir -p "$T/state"; export STUB_STATE="$T/state"
    : > "$T/podman.log"; : > "$T/sql.in"
}
no_delete_all() { ! grep -q DeleteAll "$T/podman.log"; }

hdr "install: the database container exists but is stopped (after a reboot)"
scenario; export STUB_STOPPED=teldrassil-db STUB_SCHEMAS="$ALL"
run install --yes
chk "it is started"                              'grep -qx "podman start teldrassil-db" "$T/podman.log"'
chk "no DeleteAll: the databases are kept"       'no_delete_all'
chk "  and install says so"                      '[[ "$out" == *"The databases exist; kept"* ]]'

hdr "install: the database is running but slow to answer"
scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="$ALL" STUB_DB_SLOW=2
run install --yes
chk "no DeleteAll"                               'no_delete_all'
chk "  install waited and kept them"             '[[ "$out" == *"The databases exist; kept"* ]]'

hdr "install: the database never answers"
scenario; export STUB_STOPPED=teldrassil-db STUB_SCHEMAS="$ALL" STUB_DB_SLOW=100000
run install --yes
chk "stops with a clear error, in DB_TIMEOUT"    '[[ $rc -ne 0 && "$out" == *"did not answer within 4s"* ]]'
chk "  no DeleteAll"                             'no_delete_all'

hdr "install: only the volume is left (the container was removed)"
scenario; export STUB_VOLUMES=teldrassil-db STUB_SCHEMAS="$ALL"
run install --yes
chk "a container is made on that volume"         'grep -q "^podman run -d --name teldrassil-db .*-v teldrassil-db:/var/lib/mysql" "$T/podman.log"'
chk "  no DeleteAll; kept"                       'no_delete_all && [[ "$out" == *"The databases exist; kept"* ]]'

hdr "install: a database is missing"
scenario; export STUB_STOPPED=teldrassil-db STUB_SCHEMAS="classicmangos classiccharacters classicrealmd"
run install --yes
chk "stops"                                      '[[ $rc -ne 0 ]]'
chk "  naming the missing one"                   '[[ "$out" == *"has no classiclogs"* ]]'
chk "  and what db-init --yes would do"          '[[ "$out" == *"db-init --yes"* && "$out" == *"REPLACE"* ]]'
chk "  no DeleteAll"                             'no_delete_all'

hdr "install: DB_WORLD names a database the server does not hold"
scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="$ALL"
run set DB_WORLD otherworld
run install --yes
chk "stops, naming it and what is there"         '[[ $rc -ne 0 && "$out" == *"has no otherworld"* && "$out" == *"classicmangos"* ]]'
chk "  no DeleteAll"                             'no_delete_all'
run set DB_WORLD classicmangos

hdr "install: a fresh host still gets its databases"
scenario
run install --yes
chk "the volume and container are created"       'grep -q "^podman volume create teldrassil-db" "$T/podman.log" && grep -q "^podman run -d --name teldrassil-db" "$T/podman.log"'
chk "  and the installer runs (DeleteAll on nothing)" 'grep -q "podman run --rm .*InstallFullDB.sh" "$T/podman.log" && grep -q DeleteAll "$T/podman.log"'
chk "  with no dump (there is nothing to keep)"  '! grep -q mariadb-dump "$T/podman.log"'
chk "  its database password is private (0600, in a 0700 folder)" '[[ "$(stat -c %a "$W/secrets/root.pw")" == 600 && "$(stat -c %a "$W/secrets")" == 700 ]]'

hdr "db-init --yes over existing databases dumps them first"
scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="classicmangos classiccharacters classicrealmd"
run db-init --yes
chk "the existing three are dumped"              'grep -q "mariadb-dump .*--databases classicmangos classiccharacters classicrealmd$" "$T/podman.log"'
chk "  before the installer runs"                'd=$(grep -n -m1 mariadb-dump "$T/podman.log" | cut -d: -f1); i=$(grep -n -m1 DeleteAll "$T/podman.log" | cut -d: -f1); [[ -n "$d" && -n "$i" && $d -lt $i ]]'
chk "  to a private, gzipped file"               'f=$(ls "$T"/config/teldrassil/dumps/before-db-init-*.sql.gz) && [[ "$(stat -c %a "$f")" == 600 ]] && gzip -dc "$f" | grep -q "CREATE TABLE t"'
scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="$ALL" STUB_DUMP_FAIL=1
run db-init --yes
chk "a failed dump stops db-init: no DeleteAll"  '[[ $rc -ne 0 && "$out" == *"nothing was replaced"* ]] && no_delete_all'
for how in partial empty; do
    scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="$ALL" STUB_DUMP_FAIL=$how
    run db-init --yes
    chk "  so does a dump that fails part-way or is empty ($how)" '[[ $rc -ne 0 && "$out" == *"nothing was replaced"* ]] && no_delete_all'
done

hdr "PODMAN=docker (docker has no 'image exists' or 'volume exists')"
run set PODMAN docker
scenario; export STUB_VOLUMES=teldrassil-db STUB_SCHEMAS="$ALL"
run install --yes
chk "the image is found: not rebuilt"            '[[ "$out" == *"present"* ]] && ! grep -q "^docker build" "$T/podman.log"'
chk "the volume is found: a container on it, no DeleteAll" 'grep -q "^docker run -d --name teldrassil-db .*-v teldrassil-db:/var/lib/mysql" "$T/podman.log" && no_delete_all'
chk "  and no 'exists' was asked"                '! grep -qE "^docker (image|volume) exists" "$T/podman.log"'
scenario; mkdir -p "$T/state/volume"; : > "$T/state/volume/teldrassil-db"
run remove --yes --database
chk "remove --database removes the volume"       '[[ $rc -eq 0 ]] && grep -q "^docker volume rm teldrassil-db" "$T/podman.log" && [[ ! -e "$T/state/volume/teldrassil-db" ]]'
run set PODMAN podman

hdr "configure: the config files hold the database password, so are 0600"
E="$W/install/etc"; mkdir -p "$E"
printf '%s = x\n' DataDir LogsDir LoginDatabaseInfo WorldDatabaseInfo CharacterDatabaseInfo LogsDatabaseInfo \
    WorldServerPort Console.Enable Ra.Enable Ra.IP Ra.Port > "$E/mangosd.conf.dist"
printf '%s = x\n' LoginDatabaseInfo LogsDir RealmServerPort > "$E/realmd.conf.dist"
printf 'AiPlayerbot.%s = x\n' MinRandomBots MaxRandomBots RandomBotAccountCount DisableActivityPriorities \
    DisableBotOptimizations RandomBotAutoJoinBG LLMEnabled RandomBotGuildCount > "$E/aiplayerbot.conf.dist"
printf 'AuctionHouseBot.Seller.Enabled = 0\n' > "$E/ahbot.conf.dist"
run configure
chk "configure writes them"                      '[[ $rc -eq 0 && -f "$W/etc/mangosd.conf" ]] && grep -q "$(cat "$W/secrets/mangos.pw")" "$W/etc/mangosd.conf"'
all_private() { local f; for f in mangosd realmd aiplayerbot ahbot; do [[ "$(stat -c %a "$W/etc/$f.conf")" == 600 ]] || return 1; done; }
chk "  each 0600"                                'all_private'
chmod 644 "$W/etc/mangosd.conf"
run configure --force
chk "  and --force makes an open one private again" '[[ $rc -eq 0 && "$(stat -c %a "$W/etc/mangosd.conf")" == 600 ]]'

hdr "rootful docker: the build image's containers run as the user (Kamino 225)"
# Each container that writes into WORK_DIR: build, extract, the database
# installer, the realm and world servers. Under rootful docker they run as the
# user, so what they write is the user's; never under rootless docker or
# podman, whose container root already is the user.
# Trees the shipped patches apply to - playerbots and the core: each file
# holds what their hunks expect to find (CRLF kept), so 'build' gets past
# _patch.
for tree in playerbots mangos-classic; do
python3 -I - "$W/src/$tree" "${TEST_DIR}/../templates/patches/$tree"/*.patch <<'PY'
import os, sys
root = sys.argv[1]
for p in sys.argv[2:]:
    cur, hunk = None, False
    for line in open(p, newline=""):
        if line.startswith("--- a/"):
            cur = os.path.join(root, line[6:].strip()); os.makedirs(os.path.dirname(cur), exist_ok=True)
            open(cur, "a").close(); hunk = False
        elif line.startswith(("+++ ", "diff ")):
            hunk = False
        elif line.startswith("@@"):
            hunk = True
        elif hunk and line[:1] in (" ", "-"):
            with open(cur, "a", newline="") as f:
                f.write(line[1:])
PY
done
mkdir -p "$W/install/bin/tools" "$T/client/Data"; : > "$W/install/bin/tools/ExtractResources.sh"
printf '#!/bin/sh\n' > "$W/install/bin/realmd"; chmod +x "$W/install/bin/realmd"
ME="--user $(id -u):$(id -g) -e HOME=/tmp"
# containers <rt> — every 'run --rm' and 'create' the commands below make.
containers() {
    scenario; export STUB_RUNNING=teldrassil-db STUB_SCHEMAS="$ALL"
    run build;                       out_build="$out"
    run extract --client "$T/client" --force
    run db-init --yes
    run create
    grep -E "^$1 (run --rm|create) " "$T/podman.log" > "$T/containers"
}
# as_user <0|1> — each of the five carries the user (1), or none does (0).
as_user() {
    local w n; n=0
    for w in ":/build:z" "ExtractResources.sh" "InstallFullDB.sh" "./realmd" "./mangosd"; do
        grep -qF -- "$w" "$T/containers" || return 1
        grep -F -- "$w" "$T/containers" | grep -qF -- "$ME" && n=$((n+1))
    done
    if (( $1 )); then (( n == 5 )); else (( n == 0 )) && ! grep -q -- "--user" "$T/containers"; fi
}
run set PODMAN docker
unset STUB_SECURITY
containers docker
chk "rootful docker: build, extract, db install, realmd and mangosd run as $(id -u):$(id -g)" 'as_user 1'
chk "  the build got past the patches to its container" '[[ "$out_build" == *"Patch playerbots/0001"* && "$out_build" == *"Patch mangos-classic/0001"* ]] && grep -qF ":/build:z" "$T/containers"'
export STUB_SECURITY="[name=seccomp,profile=builtin name=rootless name=cgroupns]"
containers docker
chk "rootless docker: none of them gets --user"   'as_user 0'
export STUB_SECURITY=fail
containers docker
chk "docker that cannot say (podman's docker shim): none gets --user" 'as_user 0'
unset STUB_SECURITY
run set PODMAN podman
containers podman
chk "podman: none of them gets --user"            'as_user 0'
export STUB_PODMAN_INFO="[name=seccomp]"
containers podman
chk "  not even a podman whose 'info' answered as rootful docker would" 'as_user 0'
unset STUB_PODMAN_INFO

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
