#!/usr/bin/env bash
# The command line: usage, the config store, the console's refusals, the
# flags' guards. podman is stubbed (tests/stubs) and the config lives in a
# temporary XDG_CONFIG_HOME, so nothing here touches a server or a real config.
# shellcheck disable=SC2034  # out/rc are read by the assertions chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${TELDRASSIL:-${TEST_DIR}/../teldrassil.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH" XDG_CONFIG_HOME="$T/config" STUB_LOG="$T/podman.log"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }
run(){ out="$("$ENG" "$@" 2>&1)"; rc=$?; }

hdr "usage"
run;              chk "no command: usage, exit 2"        '[[ $rc -eq 2 && "$out" == *"Usage: teldrassil.sh"* ]]'
run help;         chk "help: exit 0"                      '[[ $rc -eq 0 && "$out" == *"roster apply"* ]]'
run frobnicate;   chk "unknown command fails"             '[[ $rc -ne 0 && "$out" == *"Unknown command"* ]]'

hdr "config store"
run set DB_CONTAINER my-db;  chk "set a known key"        '[[ $rc -eq 0 ]]'
run get DB_CONTAINER;        chk "get it back"            '[[ "$out" == "my-db" ]]'
run get RA_PORT;             chk "a default"              '[[ "$out" == "3443" ]]'
run set NOT_A_KEY x;         chk "unknown key refused"    '[[ $rc -ne 0 && "$out" == *"unknown key"* ]]'
run set RA_PORT abc;         chk "a port must be a number" '[[ $rc -ne 0 ]]'
chk "the config file is private" '[[ "$(stat -c %a "$T/config/teldrassil/teldrassil.conf")" == 600 ]]'
run config;                  chk "config marks what is set" '[[ "$out" == *"* DB_CONTAINER"* ]]'

hdr "console refusals (never reach the server)"
: > "$T/podman.log"
for c in "rndbot c Bob talents" "rndbot do Bob stats" ".rndbot c x y" "RNDBOT C x"; do
    run console "$c"
    chk "refused: $c" '[[ $rc -ne 0 && "$out" == *"Refused"* ]]'
done
chk "nothing was sent anywhere" '[[ ! -s "$T/podman.log" ]]'
run console "rndbot upgrade Bob"
chk "rndbot upgrade is not refused (stops at: server not running)" '[[ "$out" != *"Refused"* && "$out" == *"not running"* ]]'

hdr "guards"
run create-account --name Bob --pass-file "$T/none"
chk "missing password file"            '[[ $rc -ne 0 && "$out" == *"Cannot read"* ]]'
run create-account --name Bob
chk "no password given: refused"       '[[ $rc -ne 0 && "$out" == *"never taken as an argument"* ]]'
run create-account --name "b!" --pass-stdin
chk "bad account name"                 '[[ $rc -ne 0 && "$out" == *"3-16 letters"* ]]'
run delete-account --name Bob
chk "delete needs --yes"               '[[ $rc -ne 0 && "$out" == *"--yes"* ]]'
run set-account-level --name Bob --level 9
chk "level 0-3 only"                   '[[ $rc -ne 0 ]]'
run roster plan
chk "roster without a file"            '[[ $rc -ne 0 && "$out" == *"No roster"* ]]'
run status
chk "status with nothing running"      '[[ $rc -eq 0 && "$out" == *"missing"* && "$out" == *"not running"* ]]'
run start
chk "start needs the database"         '[[ $rc -ne 0 && "$out" == *"database container"* ]]'

hdr "roster check through the CLI"
cat > "$T/roster.json" <<'EOF'
{"guilds": [{"name": "Test Guild", "faction": "horde", "leader": "Leadra"}],
 "bots": [{"name": "Leadra", "race": "undead", "class": "priest", "guild": "Test Guild"}]}
EOF
run roster check --file "$T/roster.json"
chk "a valid roster"                   '[[ $rc -eq 0 && "$out" == *"led by Leadra"* ]]'
printf '{"bots": [{"name": "Leadra", "race": "undead", "class": "paladin"}]}' > "$T/bad.json"
run roster check --file "$T/bad.json"
chk "an invalid one names the problem" '[[ $rc -ne 0 && "$out" == *"cannot be a paladin"* ]]'

hdr "dump and restore (podman stubbed; the database my-db "runs", the server does not)"
export STUB_RUNNING="my-db" STUB_SQL_IN="$T/sql.in"
run dump --all
chk "dump --all writes a file (no silent exit)"   '[[ $rc -eq 0 && "$out" == *"Dumped to"* ]]'
chk "it is gzipped and private"                  'f=$(ls "$T"/config/teldrassil/dumps/all-*.sql.gz) && [[ "$(stat -c %a "$f")" == 600 ]] && gzip -t "$f"'
run dump --db classiccharacters --tables "guild guild_rank" --no-gzip --out "$T/t.sql"
chk "dump --tables to a path, uncompressed"       '[[ $rc -eq 0 && -s "$T/t.sql" && "$out" == *"restore it with --db"* ]]'
run dump --tables guild
chk "--tables without --db refused"              '[[ $rc -ne 0 ]]'
run restore --file "$T/t.sql" --yes
chk "a dump with no CREATE DATABASE needs --db (no silent exit)" '[[ $rc -ne 0 && "$out" == *"give --db"* ]]'
: > "$T/sql.in"
run restore --file "$T/t.sql" --db scratch --yes
chk "restore --db sends USE scratch and the dump" '[[ $rc -eq 0 && "$(head -1 "$T/sql.in")" == "USE \`scratch\`;" ]] && grep -q "CREATE TABLE t" "$T/sql.in"'
gzip -c "$T/t.sql" > "$T/t.sql.gz"; : > "$T/sql.in"
run restore --file "$T/t.sql.gz" --db scratch --yes
chk "a gzipped dump is detected by content"      'grep -q "CREATE TABLE t" "$T/sql.in"'

hdr "search guards"
run search --kind spells --term x
chk "unknown kind refused"                        '[[ $rc -ne 0 && "$out" == *"--kind must be"* ]]'
run search --kind items
chk "items need --term"                           '[[ $rc -ne 0 && "$out" == *"--term is required"* ]]'
run search --kind items --term x --zone Durotar
chk "character filters only for characters/bots"  '[[ $rc -ne 0 && "$out" == *"are for characters and bots"* ]]'
: > "$T/sql.in"
run search --kind items --term "50%_off"
want_like="LIKE '%50\\\\%\\\\_off%'"   # in SQL: \\% and \\_ - LIKE then reads \% and \_ as literals
chk "LIKE wildcards in a term are literal"        'grep -qF -- "$want_like" "$T/sql.in"'
unset STUB_RUNNING STUB_SQL_IN

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
