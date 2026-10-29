#!/usr/bin/env bash
# A failed admin step leaves the realm as it found it (Kamino 169): the
# graceful restart reports a restart that worked, whoever made it; attune and
# roster apply start a server they stopped again, whatever fails after the
# stop; a fresh population that does not finish puts aiplayerbot.conf's guild
# settings back, and stops a server it started once its deletion is over.
# podman is stubbed (tests/stubs/podman) and the remote console
# is tests/fake_ra.py, on a free port of 127.0.0.1.
# shellcheck disable=SC2034  # out/rc are read by the assertions chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${TELDRASSIL:-${TEST_DIR}/../teldrassil.sh}"
T="$(mktemp -d)"
RA_PID=""
trap '[[ -z "$RA_PID" ]] || kill "$RA_PID" 2>/dev/null; rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH" XDG_CONFIG_HOME="$T/config" STUB_LOG="$T/podman.log" STUB_SQL_IN="$T/sql.in"
unset TELDRASSIL_PROFILE
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }
run(){ out="$("$ENG" "$@" 2>&1)"; rc=$?; }

# The remote console: what 'server restart' does next is $T/on-restart.sh.
python3 "$TEST_DIR/fake_ra.py" "$T/ra.port" "$T/ra.log" "bash $T/on-restart.sh" &
RA_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/ra.port" ]] && break; sleep 0.3; done
[[ -s "$T/ra.port" ]] || { echo "the fake console did not start"; exit 1; }
printf 'account: TESTER\npassword: secret\n' > "$T/console.txt"
run set RA_PORT "$(cat "$T/ra.port")"
run set RA_PASS_FILE "$T/console.txt"
run set STOP_TIMEOUT 6
run set START_TIMEOUT 20
run set FRESH_STOP_WAIT 4

S="$T/state"
W=teldrassil-mangosd
# scenario <running|stopped> — the database and the realm server run; the
# world server exists, running or not; a start finds the ready line.
scenario() {
    rm -rf "$S"; mkdir -p "$S/exists" "$S/running" "$S/started"
    : > "$S/exists/$W"; echo 1 > "$S/started/$W"
    [[ "$1" == running ]] && : > "$S/running/$W"
    export STUB_STATE="$S" STUB_RUNNING="teldrassil-db teldrassil-realmd" STUB_LOG_LINE="World initialized"
    unset STUB_SQL_FAIL STUB_DB_NEEDS STUB_SQL_REPLY
    : > "$T/podman.log"; : > "$T/sql.in"
}
# started_again — the world server was started after it was stopped.
started_again() { grep -A1000 "^podman stop .*$W" "$T/podman.log" | grep -q "^podman start $W"; }

hdr "restart --graceful: podman's restart policy brings it back"
scenario running
printf 'echo 2 > %q\n' "$S/started/$W" > "$T/on-restart.sh"     # mangosd exits non-zero; podman restarts it
run restart --graceful 0
chk "a restart that worked is reported as one"    '[[ $rc -eq 0 && "$out" == *"restart policy started it again"* && "$out" == *"World server is up"* ]]'
chk "  and this did not start it as well"         '! grep -q "^podman start $W" "$T/podman.log"'
chk "  the console got 'server restart 0'"        'grep -qx "server restart 0" "$T/ra.log"'

hdr "restart --graceful: mangosd exits cleanly and stays stopped"
scenario running
printf 'rm -f %q\n' "$S/running/$W" > "$T/on-restart.sh"
run restart --graceful 0
chk "it is started here, after the grace period"  '[[ $rc -eq 0 && "$out" == *"Starting it again"* && "$out" == *"World server is up"* ]]'
chk "  once"                                      '[[ "$(grep -c "^podman start $W" "$T/podman.log")" == 1 ]]'

hdr "restart --graceful: the policy restarts it a few seconds after it exits"
scenario running
printf 'rm -f %q; sleep 3; echo 2 > %q; : > %q\n' "$S/running/$W" "$S/started/$W" "$S/running/$W" > "$T/on-restart.sh"
run restart --graceful 0
chk "no race: this waits, and does not start it too" '[[ $rc -eq 0 && "$out" == *"restart policy started it again"* ]] && ! grep -q "^podman start $W" "$T/podman.log"'

hdr "restart --graceful: mangosd never exits"
scenario running
: > "$T/on-restart.sh"
run restart --graceful 0
chk "an error, after STOP_TIMEOUT"                '[[ $rc -ne 0 && "$out" == *"did not exit within 6s"* ]]'

hdr "attune apply: the state query fails after the stop"
scenario running; export STUB_DB_NEEDS=$W
run attune apply --yes
chk "the command fails"                           '[[ $rc -ne 0 ]]'
chk "  and the server it stopped is started again" 'started_again && [[ "$out" == *"starting it again"* && "$out" == *"World server is up"* ]]'
scenario stopped; export STUB_DB_NEEDS=$W
run attune apply --yes
chk "a server that was stopped stays stopped"     '[[ $rc -ne 0 ]] && ! grep -q "^podman start $W" "$T/podman.log"'
scenario running; export STUB_SQL_FAIL="INSERT INTO character_queststatus"
export STUB_SQL_REPLY='{"bots": [{"guid": 1, "name": "Sixty", "level": 60}], "rewarded": null, "reputation": null}'
run attune apply --yes
chk "the database refuses the grants: started again" '[[ $rc -ne 0 && "$out" == *"refused the grants"* ]] && started_again'
scenario running
export STUB_SQL_REPLY='{"bots": [{"guid": 1, "name": "Sixty", "level": 60}], "rewarded": null, "reputation": null}'
run attune apply --yes
chk "a grant that works: started once, by the command" '[[ $rc -eq 0 && "$(grep -c "^podman start $W" "$T/podman.log")" == 1 && "$out" != *"starting it again"* ]]'

hdr "roster apply: something fails after the stop"
cat > "$T/roster.json" <<'EOF'
{"guilds": [{"name": "Test Guild", "faction": "horde", "leader": "Leadra"}],
 "bots": [{"name": "Leadra", "race": "undead", "class": "priest", "guild": "Test Guild"}]}
EOF
printf 'AiPlayerbot.RandomBotGuildCount = 7\nAiPlayerbot.DeleteRandomBotGuilds = 0\n' > "$T/aiplayerbot.conf"
run set BOT_CONF "$T/aiplayerbot.conf"
run set CARDS_FILE "$T/cards.txt"
STATE='{"characters": [{"guid": 10, "name": "Leadra", "race": 5, "class": 5, "gender": 0, "level": 1, "online": 0, "bot": 1}], "guilds": [], "members": []}'
scenario running; export STUB_SQL_REPLY="$STATE" STUB_DB_NEEDS=$W
run roster apply --file "$T/roster.json" --yes
chk "the state query: the command fails"          '[[ $rc -ne 0 ]]'
chk "  and the server is started again"           'started_again && [[ "$out" == *"World server is up"* ]]'
scenario running; export STUB_SQL_REPLY="$STATE" STUB_SQL_FAIL="START TRANSACTION"
run roster apply --file "$T/roster.json" --yes
chk "the plan's transaction is refused: started again" '[[ $rc -ne 0 && "$out" == *"refused the plan"* ]] && started_again'
scenario stopped; export STUB_SQL_REPLY="$STATE" STUB_SQL_FAIL="START TRANSACTION"
run roster apply --file "$T/roster.json" --yes
chk "  one that was stopped stays stopped"        '[[ $rc -ne 0 ]] && ! grep -q "^podman start $W" "$T/podman.log"'

hdr "roster apply --fresh-population: the start fails"
cat > "$T/fresh.json" <<'EOF'
{"population": {"bots": 10},
 "bots": [{"name": "Leadra", "race": "undead", "class": "priest"}]}
EOF
scenario stopped; export STUB_SQL_REPLY="$STATE" STUB_LOG_LINE="Segmentation fault"
run roster apply --file "$T/fresh.json" --fresh-population --yes
chk "the command fails"                           '[[ $rc -ne 0 && "$out" == *"stopped while starting"* ]]'
chk "  guild deletion is off again"               'grep -qx "AiPlayerbot.DeleteRandomBotGuilds = 0" "$T/aiplayerbot.conf"'
chk "  random guilds are back, at their old count" 'grep -qx "AiPlayerbot.RandomBotGuildCount = 7" "$T/aiplayerbot.conf"'
chk "  the deletion request is withdrawn"         '[[ "$(grep "bot_delete" "$T/sql.in" | tail -1)" == "DELETE FROM"*"event='"'"'bot_delete'"'"';" ]]'
chk "  the roster's counts stay (they were asked for)" 'grep -qx "AiPlayerbot.MinRandomBots = 10" "$T/aiplayerbot.conf"'

hdr "roster apply --fresh-population: interrupted while the bots are made"
printf 'AiPlayerbot.RandomBotGuildCount = 7\nAiPlayerbot.DeleteRandomBotGuilds = 0\n' > "$T/aiplayerbot.conf"
run set BOTS_TIMEOUT 600
scenario stopped; export STUB_SQL_REPLY=0
"$ENG" roster apply --file "$T/fresh.json" --fresh-population --yes > "$T/fresh.out" 2>&1 &
pid=$!
for _ in $(seq 1 40); do grep -q "Waiting for 10 bot characters" "$T/fresh.out" && break; sleep 0.5; done
chk "it is waiting for the new bots, with deletion on" 'grep -qx "AiPlayerbot.DeleteRandomBotGuilds = 1" "$T/aiplayerbot.conf"'
kill -TERM "$pid"; wait "$pid"; rc=$?
chk "a signal ends it"                            '[[ $rc -ne 0 ]] && grep -q "Interrupted" "$T/fresh.out"'
chk "  and the guild settings are put back"       'grep -qx "AiPlayerbot.DeleteRandomBotGuilds = 0" "$T/aiplayerbot.conf" && grep -qx "AiPlayerbot.RandomBotGuildCount = 7" "$T/aiplayerbot.conf"'

# An interrupted fresh population that started a server stopped before the
# command (Kamino 226): it is stopped again once the deletion is over - the
# 'bot_delete' request gone and the bot count no longer falling - or, if the
# deletion outlasts FRESH_STOP_WAIT, left running with how to stop it. (A
# signal lands once the 5 s poll's sleep ends, hence the 8 s below.) One
# that was running before is left running, as it was found. The database's
# answers come from $T/sqlmap; the bot count stays 3 of the 10 asked for, so
# the run waits for the new bots until it is interrupted.
# sqlmap <pending> [bots] — written whole, then moved into place: the stub
# never reads half a file.
sqlmap() { printf "COUNT.*event='bot_delete'\t%s\nCOUNT.*JOIN\t%s\n" "$1" "${2:-3}" > "$T/sqlmap.new"; mv -f "$T/sqlmap.new" "$T/sqlmap"; }
# fresh_interrupted [script] — start one, kill it once it waits for the bots,
# and run [script] alongside what follows the kill: the database's answers
# changing as playerbots works. Sets out, rc, took and after (what podman was
# asked after the kill).
fresh_interrupted() {
    printf 'AiPlayerbot.RandomBotGuildCount = 7\nAiPlayerbot.DeleteRandomBotGuilds = 0\n' > "$T/aiplayerbot.conf"
    export STUB_SQL_REPLY=0 STUB_SQL_MAP="$T/sqlmap"; : > "$T/ra.log"
    "$ENG" roster apply --file "$T/fresh.json" --fresh-population --yes > "$T/fresh.out" 2>&1 &
    local pid=$! n t0 later=""
    for _ in $(seq 1 40); do grep -q "Waiting for 10 bot characters" "$T/fresh.out" && break; sleep 0.5; done
    n="$(wc -l < "$T/podman.log")"; t0=$SECONDS
    if [[ -n "${1:-}" ]]; then ( eval "$1" ) & later=$!; fi
    kill -TERM "$pid"; wait "$pid"; rc=$?
    took=$((SECONDS - t0)); out="$(cat "$T/fresh.out")"
    after="$(tail -n +"$((n + 1))" "$T/podman.log")"
    [[ -z "$later" ]] || wait "$later"
}
stopped_after() { grep -qE "^podman stop .*$W\$" <<<"$after" && [[ ! -e "$S/running/$W" ]]; }

hdr "--fresh-population interrupted, the server stopped before: the deletion finishes"
run set FRESH_STOP_WAIT 20
scenario stopped; sqlmap 1
fresh_interrupted 'sleep 8; sqlmap 0'
chk "it waits for the deletion"                   '[[ $rc -ne 0 && "$out" == *"waiting up to 20s for the random-bot deletion"* ]] && (( took >= 8 ))'
chk "  then stops the server, saved first"        'stopped_after && [[ "$out" == *"deletion is over"* ]] && grep -qx saveall "$T/ra.log"'
chk "  and the guild settings are back"           'grep -qx "AiPlayerbot.DeleteRandomBotGuilds = 0" "$T/aiplayerbot.conf" && grep -qx "AiPlayerbot.RandomBotGuildCount = 7" "$T/aiplayerbot.conf"'
chk "  not left-running"                          '[[ "$out" != *"still RUNNING"* ]]'

hdr "--fresh-population interrupted, the server stopped before: the deletion outlasts FRESH_STOP_WAIT"
run set FRESH_STOP_WAIT 8
scenario stopped; sqlmap 1
fresh_interrupted
chk "the server is left running"                  '[[ $rc -ne 0 && -e "$S/running/$W" ]] && ! grep -q "^podman stop" <<<"$after"'
chk "  after the wait"                            '(( took >= 8 ))'
chk "  and it says so, and how to stop it"        '[[ "$out" == *"still RUNNING"* && "$out" == *"after 8s"* && "$out" == *"teldrassil.sh stop"* ]]'
chk "  the deletion request is withdrawn"         '[[ "$(grep "bot_delete" "$T/sql.in" | tail -1)" == "DELETE FROM"*"event='"'"'bot_delete'"'"';" ]]'

hdr "--fresh-population interrupted: the request is gone, but the bots are still being deleted"
run set FRESH_STOP_WAIT 6
scenario stopped; sqlmap 1
fresh_interrupted 'for i in $(seq 1 12); do sqlmap 0 $((100 - i)); sleep 1; done'
chk "a falling bot count is a deletion not over: left running" '[[ $rc -ne 0 && -e "$S/running/$W" && "$out" == *"still RUNNING"* ]] && ! grep -q "^podman stop" <<<"$after"'

hdr "--fresh-population interrupted, the server running before: it stays running"
scenario running; sqlmap 0
fresh_interrupted
chk "it is not stopped, nor waited on"            '[[ $rc -ne 0 && -e "$S/running/$W" ]] && ! grep -q "^podman stop" <<<"$after" && [[ "$out" != *"waiting up to"* && "$out" != *"still RUNNING"* ]]'

hdr "FRESH_STOP_WAIT is a number of seconds above 0"
for v in 0 -1 abc 1.5; do
    run set FRESH_STOP_WAIT "$v"
    chk "  '$v' is refused"                       '[[ $rc -ne 0 && "$out" == *"FRESH_STOP_WAIT must be"* ]]'
done
run set FRESH_STOP_WAIT 1
chk "  1 is taken"                                '[[ $rc -eq 0 ]]'

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
