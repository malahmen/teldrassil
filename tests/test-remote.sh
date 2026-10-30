#!/usr/bin/env bash
# Profiles, and a server elsewhere: SSH_HOST and SERVER_KIND=kube. ssh, kubectl
# and podman are stubbed (tests/stubs); the stub ssh runs its command here
# after a second shell parse, as a real host would.
# shellcheck disable=SC2034  # out/rc are read by the assertions chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${TELDRASSIL:-${TEST_DIR}/../teldrassil.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${TEST_DIR}/stubs:$PATH" XDG_CONFIG_HOME="$T/config" STUB_LOG="$T/calls.log"
unset TELDRASSIL_PROFILE
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }
run(){ out="$("$ENG" "$@" 2>&1)"; rc=$?; }

hdr "profiles"
run set DB_CONTAINER base-db
run --profile far set DB_CONTAINER far-db;  chk "set creates the profile"       '[[ $rc -eq 0 && -f "$T/config/teldrassil/profiles/far.conf" ]]'
chk "  private"                                                                  '[[ "$(stat -c %a "$T/config/teldrassil/profiles/far.conf")" == 600 ]]'
run --profile far get DB_CONTAINER;         chk "the profile wins"              '[[ "$out" == far-db ]]'
run --profile far get RA_PORT;              chk "unset keys fall through"       '[[ "$out" == 3443 ]]'
run get DB_CONTAINER;                       chk "the base is untouched"         '[[ "$out" == base-db ]]'
TELDRASSIL_PROFILE=far run get DB_CONTAINER; chk "\$TELDRASSIL_PROFILE picks it" '[[ "$out" == far-db ]]'
TELDRASSIL_PROFILE=far run --no-profile get DB_CONTAINER; chk "--no-profile ignores it" '[[ "$out" == base-db ]]'
run --profile nope status;                  chk "a missing profile is refused"  '[[ $rc -ne 0 && "$out" == *"No such profile"* ]]'
run --profile "../x" set DB_USER a;         chk "a path is not a profile name"  '[[ $rc -ne 0 && "$out" == *"invalid name"* ]]'
run --profile far profiles;                 chk "profiles marks the active one" '[[ "$out" == *"* far"* ]]'
run --profile far config;                   chk "config marks the profile's keys" '[[ "$out" == *"P DB_CONTAINER"* ]]'
run --profile far set SERVER_KIND docker;   chk "SERVER_KIND is podman or kube" '[[ $rc -ne 0 ]]'

hdr "editing and removing profiles"
run --profile tmp set DB_USER bob; run --profile tmp set DB_CONTAINER tmp-db
run --profile tmp unset DB_USER;            chk "unset drops a key"             '[[ $rc -eq 0 && "$out" == *"now '"'"'root'"'"'"* ]]'
run --profile tmp get DB_CONTAINER;         chk "  and keeps the rest"          '[[ "$out" == tmp-db ]]'
run --profile tmp unset NOPE;               chk "unset refuses an unknown key"  '[[ $rc -ne 0 ]]'
printf 'password: x\n' > "$T/config/teldrassil/console-tmp.txt"
run --profile tmp set RA_PASS_FILE "$T/config/teldrassil/console-tmp.txt"
run profile-rename tmp tmp2;                chk "rename"                        '[[ $rc -eq 0 && -f "$T/config/teldrassil/profiles/tmp2.conf" && ! -e "$T/config/teldrassil/profiles/tmp.conf" ]]'
chk "  moves its console file"              '[[ -f "$T/config/teldrassil/console-tmp2.txt" && ! -e "$T/config/teldrassil/console-tmp.txt" ]]'
run --profile tmp2 get RA_PASS_FILE;        chk "  and points the setting at it" '[[ "$out" == *console-tmp2.txt ]]'
run profile-rename tmp2 far;                chk "rename onto an existing one is refused" '[[ $rc -ne 0 && "$out" == *"already exists"* ]]'
run profile-delete tmp2;                    chk "delete needs --yes"            '[[ $rc -ne 0 && -f "$T/config/teldrassil/profiles/tmp2.conf" ]]'
run profile-delete tmp2 --yes;              chk "delete"                        '[[ $rc -eq 0 && ! -e "$T/config/teldrassil/profiles/tmp2.conf" ]]'
chk "  keeps the console password file, and says where" '[[ -f "$T/config/teldrassil/console-tmp2.txt" && "$out" == *console-tmp2.txt* ]]'
run profile-delete nope --yes;              chk "deleting a missing profile fails" '[[ $rc -ne 0 && "$out" == *"No such profile"* ]]'
run profile-delete "../teldrassil" --yes;   chk "a path is refused"             '[[ $rc -ne 0 && -f "$T/config/teldrassil/teldrassil.conf" ]]'

hdr "over ssh"
for kv in "SSH_HOST box" "DB_CONTAINER db" "DB_PASS_ENV MARIADB_ROOT_PASSWORD"; do run --profile box set $kv; done
: > "$T/calls.log"
export STUB_RUNNING="db" STUB_SQL_IN="$T/sql.in"
run --profile box list-accounts
chk "list-accounts runs"                                  '[[ $rc -eq 0 ]]'
chk "  podman ran through ssh"                            'grep -q "^ssh box .podman. .exec. .-i. .db." "$T/calls.log"'
chk "  the password is read inside, from the variable"   'grep -q "printenv" "$T/calls.log" && grep -q "MARIADB_ROOT_PASSWORD" "$T/calls.log"'
chk "  the SQL went in on stdin"                          'grep -q "FROM classicrealmd.account" "$T/sql.in"'
run --profile box install --yes
chk "provisioning is refused over ssh"                    '[[ $rc -ne 0 && "$out" == *"provisions a server on this host"* ]]'
run --profile box apply-sql --file "$TEST_DIR/../README.md" --db "x'; rm -rf /tmp/nothing; '"
chk "a hostile database name is refused before ssh"       '[[ $rc -ne 0 ]]'

hdr "a world server in a cluster (SERVER_KIND=kube)"
mkdir -p "$T/secret"
printf 'AiPlayerbot.LLMEnabled = 0\n# AiPlayerbot.LLMApiEndpoint = x\n# AiPlayerbot.LLMApiJson = x\n# AiPlayerbot.LLMResponseStartPattern = x\n# AiPlayerbot.LLMBotToBotChatChance = 0\n' > "$T/secret/aiplayerbot.conf"
for kv in "SERVER_KIND kube" "SERVER_CONTAINER world"; do run --profile box set $kv; done
run --profile box status
chk "kube needs a namespace"                              '[[ $rc -ne 0 && "$out" == *"KUBE_NAMESPACE"* ]]'
for kv in "KUBE_NAMESPACE game" "BOT_SECRET bots"; do run --profile box set $kv; done
export STUB_SECRET_DIR="$T/secret" STUB_KUBE_APPLIED="$T/applied.yaml" STUB_KUBE_PODS="world-1"
: > "$T/calls.log"
run --profile box status
chk "status shows the deployment"                         '[[ $rc -eq 0 && "$out" == *"deployment world in game"* && "$out" == *"1 of 1 ready"* ]]'
chk "  kubectl ran through ssh, in its namespace"         'grep -q "^ssh box .kubectl. .--namespace. .game." "$T/calls.log"'
chk "  the LLM state came from the Secret"                '[[ "$out" == *"LLM chat off"* ]]'
chk "  nothing was written back"                          '[[ ! -e "$T/applied.yaml" ]]'
run --profile box llm on --endpoint http://127.0.0.1:9/v1/chat/completions --model m
chk "llm on edits the Secret's copy"                      '[[ $rc -eq 0 && "$out" == *"written to the Secret bots"* ]]'
chk "  and applies it server-side"                        'grep -q "kubectl.*apply.*--server-side" "$T/calls.log"'
chk "  as a Secret named bots, in game"                   'grep -q "^  name: bots" "$T/applied.yaml" && grep -q "^  namespace: game" "$T/applied.yaml"'
chk "  carrying the edited conf"                          'grep "aiplayerbot.conf:" "$T/applied.yaml" | sed "s/.*: //" | base64 -d | grep -qx "AiPlayerbot.LLMEnabled = 2"'
rm -f "$T/applied.yaml"
run --profile box llm status
chk "llm status changes nothing"                          '[[ $rc -eq 0 && ! -e "$T/applied.yaml" ]]'
STUB_KUBE_PODS="" STUB_LOG_LINE="World initialized" run --profile box start
chk "start: no pods, so it scales up and waits for the log" '[[ $rc -eq 0 && "$out" == *"World server is up"* ]] && grep -q "scale deployment world --replicas=1" "$T/calls.log"'
: > "$T/calls.log"
STUB_KUBE_PODS="" run --profile box stop
chk "stop when no pod exists: nothing to do"              '[[ $rc -eq 0 && "$out" == *"not running"* ]] && ! grep -q "scale" "$T/calls.log"'
run --profile box restore --file "$TEST_DIR/../README.md" --yes
chk "restore refuses while the pod exists"                '[[ $rc -ne 0 && "$out" == *"Stop the world server first"* ]]'
run --profile box console "rndbot c Bob x"
chk "console refusals still hold"                         '[[ $rc -ne 0 && "$out" == *"Refused"* ]]'

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
