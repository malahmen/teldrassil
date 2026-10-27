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

hdr "dump and restore (podman stubbed; the database my-db runs, the server does not)"
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
run attune grant
chk "attune: only plan or apply"                  '[[ $rc -ne 0 && "$out" == *"attune plan|apply"* ]]'
unset STUB_RUNNING STUB_SQL_IN

hdr "provisioning guards"
run install
chk "install needs --yes"                         '[[ $rc -ne 0 && "$out" == *"add --yes"* ]]'
run db-init
chk "db-init without an image: refused first"     '[[ $rc -ne 0 && "$out" == *"build-image"* ]]'
export STUB_IMAGE=1
run db-init
chk "db-init without sources: refused"            '[[ $rc -ne 0 && "$out" == *"run '"'"'source'"'"' first"* ]]'
mkdir -p "$T/config/teldrassil" "$T/work/src/mangos-classic" "$T/work/src/playerbots" "$T/work/src/classic-db"
run set WORK_DIR "$T/work"
run db-init
chk "db-init with sources but no --yes: refused (it replaces databases)" '[[ $rc -ne 0 && "$out" == *"REPLACES"* ]]'
run extract
chk "extract needs a client"                      '[[ $rc -ne 0 && "$out" == *"Where is the 1.12.1 client"* ]]'
mkdir -p "$T/client"
run extract --client "$T/client"
chk "a folder with no Data/ is not a client"      '[[ $rc -ne 0 && "$out" == *"no Data/ folder"* ]]'
run configure
chk "configure before a build: refused"           '[[ $rc -ne 0 && "$out" == *"run '"'"'build'"'"' first"* ]]'
run create
chk "create before a build: refused"              '[[ $rc -ne 0 && "$out" == *"run '"'"'build'"'"' first"* ]]'
run remove
chk "remove needs --yes"                          '[[ $rc -ne 0 && "$out" == *"add --yes"* ]]'
run build --jobs many
chk "build --jobs must be a number"               '[[ $rc -ne 0 ]]'
unset STUB_IMAGE

hdr "llm (on a copy of a shipped conf)"
printf '# AiPlayerbot.LLMEnabled = 1\n# AiPlayerbot.LLMApiEndpoint = x\n# AiPlayerbot.LLMApiJson = x\n# AiPlayerbot.LLMResponseStartPattern = x\n# AiPlayerbot.LLMBotToBotChatChance = 0\n# AiPlayerbot.LLMApiKey =\n' > "$T/aiplayerbot.conf"
run set BOT_CONF "$T/aiplayerbot.conf"
run llm status
chk "a shipped conf reads as off"                 '[[ "$out" == "LLM chat: off" ]]'
printf 'sk-test-key\n' > "$T/key"
run llm on --endpoint http://127.0.0.1:9/v1/chat/completions --model test-model --reasoning-effort none --api-key-file "$T/key"
chk "llm on succeeds (an unreachable endpoint only warns)" '[[ $rc -eq 0 && "$out" == *"does not answer now"* ]]'
chk "  every bot (LLMEnabled 2)"                  'grep -qx "AiPlayerbot.LLMEnabled = 2" "$T/aiplayerbot.conf"'
chk "  the model and reasoning effort in the request" 'grep -q "\"model\": \"test-model\".*\"reasoning_effort\": \"none\"" "$T/aiplayerbot.conf"'
chk "  the key is in the conf"                    'grep -qx "AiPlayerbot.LLMApiKey = sk-test-key" "$T/aiplayerbot.conf"'
chk "  and in no output"                          '[[ "$out" != *sk-test-key* ]]'
run llm status
chk "status says on, every bot"                   '[[ "$out" == *"on (LLMEnabled 2: every bot)"* ]]'
run llm off
chk "llm off"                                     'grep -qx "AiPlayerbot.LLMEnabled = 0" "$T/aiplayerbot.conf"'
run llm on --endpoint ftp://x --model m
chk "an endpoint must be http(s)"                 '[[ $rc -ne 0 ]]'
run llm on --model m
chk "on needs an endpoint"                        '[[ $rc -ne 0 && "$out" == *"Usage: llm on"* ]]'

hdr "roster apply never takes over a players' guild (Kamino 164)"
# The database's answer to the plan's state query is $STUB_SQL_REPLY: Leadra
# is a bot already, Playerone a player. The world server is stopped, the realm
# server runs, and a start finds the ready line.
state() {   # state <guild rows> <member rows>
    printf '{"characters": [{"guid": 10, "name": "Leadra", "race": 5, "class": 5, "gender": 0, "level": 1, "online": 0, "bot": 1}, {"guid": 13, "name": "Hordebot", "race": 2, "class": 1, "gender": 0, "level": 1, "online": 0, "bot": 1}, {"guid": 20, "name": "Playerone", "race": 8, "class": 3, "gender": 0, "level": 1, "online": 0, "bot": 0}], "guilds": [%s], "members": [%s]}' "$1" "$2"
}
g() { printf '{"id": %s, "name": "%s", "leader": %s, "created": %s, "EmblemStyle": 0, "EmblemColor": 0, "BorderStyle": 0, "BorderColor": 0, "BackgroundColor": 0, "info": "", "motd": ""}' "$@"; }
m() { printf '{"guild": %s, "guid": %s, "rank": %s, "pnote": "", "offnote": ""}' "$@"; }
mkdir -p "$T/stub"
export STUB_RUNNING="my-db teldrassil-realmd" STUB_STOPPED=teldrassil-mangosd STUB_SQL_IN="$T/sql.in" STUB_STATE="$T/stub" STUB_LOG_LINE="World initialized" STUB_SQL_REPLY
run set CARDS_FILE "$T/cards.txt"
BIND="$T/config/teldrassil/roster-guilds.json"
: > "$T/sql.in"; : > "$T/podman.log"
STUB_SQL_REPLY="$(state "$(g 5 "Test Guild" 20 100)" "$(m 5 20 0)")"
run roster apply --file "$T/roster.json" --yes
chk "a guild of the roster's name led by a player: refused" '[[ $rc -ne 0 && "$out" == *"Test Guild"* && "$out" == *"led by Playerone"* ]]'
chk "  no SQL written to any guild"               '! grep -qE "(UPDATE|INSERT INTO|DELETE FROM) guild|START TRANSACTION" "$T/sql.in"'
chk "  the server was not started (nor stopped)"  '! grep -qE "^podman (start|stop) teldrassil-mangosd" "$T/podman.log"'
chk "  no binding recorded"                       '[[ ! -e "$BIND" ]]'
STUB_SQL_REPLY="$(state "$(g 5 "Test Guild" 13 100)" "$(m 5 13 0),$(m 5 20 4)")"
run roster apply --file "$T/roster.json" --yes
chk "a bot guild with a player in it: refused, naming them" '[[ $rc -ne 0 && "$out" == *"players are in it (Playerone)"* ]] && ! grep -qE "(UPDATE|INSERT INTO|DELETE FROM) guild|START TRANSACTION" "$T/sql.in"'
: > "$T/podman.log"
STUB_RUNNING="my-db teldrassil-realmd teldrassil-mangosd" run roster apply --file "$T/roster.json" --yes
chk "  refused before a running world server is stopped" '[[ $rc -ne 0 ]] && ! grep -q "^podman stop" "$T/podman.log"'
STUB_SQL_REPLY="$(state "$(g 5 "Test Guild" 13 100)" "$(m 5 13 0)")"
run roster apply --file "$T/roster.json" --yes
chk "an all-bot guild of the faction: applied"    '[[ $rc -eq 0 ]] && grep -q "UPDATE guild SET leaderguid=10.* WHERE guildid=5;" "$T/sql.in"'
chk "  and bound by id, privately"                'grep -q "\"id\": 5" "$BIND" && [[ "$(stat -c %a "$BIND")" == 600 ]]'
: > "$T/sql.in"
STUB_SQL_REPLY="$(state "$(g 5 "Renamed" 10 100),$(g 9 "Test Guild" 20 200)" "$(m 5 10 0),$(m 5 13 4),$(m 9 20 0)")"
run roster apply --file "$T/roster.json" --yes
chk "renamed since, with a players' guild of the old name: id 5 stays the roster's" '[[ $rc -eq 0 && "$out" == *"bound to guild id 5"* ]] && ! grep -qE "guildid=9|\(9," "$T/sql.in"'
unset STUB_RUNNING STUB_STOPPED STUB_SQL_IN STUB_STATE STUB_LOG_LINE STUB_SQL_REPLY

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
