#!/usr/bin/env bash
# Passwords stay off every command line, and restoring accounts never wipes
# another server's (Kamino 232): console --stdin, set-account-password
# --pass-stdin, and the accounts-only dump that restore merges.
# podman and ssh are stubbed (tests/stubs), the remote console is
# tests/fake_ra.py, and python3 is wrapped to record its argv: a password
# must not be in any argv the stubs or the wrapper record.
# shellcheck disable=SC2034  # out/rc are read by the assertions chk evaluates
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${TELDRASSIL:-${TEST_DIR}/../teldrassil.sh}"
T="$(mktemp -d)"
RA_PID=""
trap '[[ -z "$RA_PID" ]] || kill "$RA_PID" 2>/dev/null; rm -rf "$T"' EXIT
unset TELDRASSIL_PROFILE
REAL_PY="$(command -v python3)"

# The remote console, started with the real python3.
python3 "$TEST_DIR/fake_ra.py" "$T/ra.port" "$T/ra.log" &
RA_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/ra.port" ]] && break; sleep 0.3; done
[[ -s "$T/ra.port" ]] || { echo "the fake console did not start"; exit 1; }

# python3 that records each argv, then runs the real one.
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nprintf "python3 %%s\\n" "$*" >> %q\nexec %q "$@"\n' "$T/argv.log" "$REAL_PY" > "$T/bin/python3"
chmod +x "$T/bin/python3"
export PATH="$T/bin:${TEST_DIR}/stubs:$PATH" XDG_CONFIG_HOME="$T/config" STUB_LOG="$T/podman.log" STUB_SQL_IN="$T/sql.in"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr(){ printf '\n\033[36m== %s\033[0m\n' "$1"; }
run(){ out="$("$ENG" "$@" 2>&1)"; rc=$?; }
# feed <stdin> <args...> — run with that on stdin.
feed(){ local in="$1"; shift; out="$(printf '%s' "$in" | "$ENG" "$@" 2>&1)"; rc=$?; }
# argv_clean <secret...> — none of them in any argv recorded (podman, ssh, python3).
argv_clean(){ local s; for s in "$@"; do ! grep -qF -- "$s" "$T/podman.log" "$T/argv.log" || return 1; done; }
reset(){ : > "$T/podman.log"; : > "$T/argv.log"; : > "$T/sql.in"; : > "$T/ra.log"; }

printf 'account: TESTER\npassword: secret\n' > "$T/console.txt"
run set RA_PORT "$(cat "$T/ra.port")"
run set RA_PASS_FILE "$T/console.txt"
S="$T/state"; W=teldrassil-mangosd
mkdir -p "$S/exists" "$S/running" "$S/started"; : > "$S/exists/$W"; : > "$S/running/$W"
export STUB_STATE="$S" STUB_RUNNING="teldrassil-db teldrassil-realmd"

hdr "console --stdin"
reset
feed $'saveall\n\n   \nserver info\naccount create Alice S3cretPw\n.ACCOUNT SET PASSWORD Bob N3wPass1 N3wPass1\n' console --stdin
chk "every line is sent, in order; blank lines skipped" '[[ $rc -eq 0 ]] && [[ "$(cat "$T/ra.log")" == $'"'"'saveall\nserver info\naccount create Alice S3cretPw\n.ACCOUNT SET PASSWORD Bob N3wPass1 N3wPass1'"'"' ]]'
chk "  each command's output is shown, as with arguments"  '[[ "$out" == *"> saveall"* && "$out" == *"> server info"* ]]'
chk "  a password command is allowed, and shown masked"    '[[ "$out" == *"> account create Alice ****"* && "$out" == *"> .ACCOUNT SET PASSWORD Bob **** ****"* ]]'
chk "  the passwords are in no output"                     '[[ "$out" != *S3cretPw* && "$out" != *N3wPass1* ]]'
chk "  nor in any argv (podman, ssh, python3)"             'argv_clean S3cretPw N3wPass1 && [[ -s "$T/argv.log" ]]'
reset
feed $'saveall\nbogus thing\nserver info\n' console --stdin
chk "a command the console reports failed: non-zero"       '[[ $rc -ne 0 && "$out" == *"failure for: bogus thing"* ]]'
chk "  the others are still sent"                          'grep -qx "server info" "$T/ra.log"'
reset
feed $'saveall\r\nserver info\n' console --stdin
chk "a line with a carriage return: refused, nothing sent" '[[ $rc -ne 0 && "$out" == *"carriage return"* && ! -s "$T/ra.log" ]]'
feed $'saveall\nrndbot taxtest Bob 1 2\n' console --stdin
chk "a test tool on stdin: refused, nothing sent"   '[[ $rc -ne 0 && "$out" == *"Refused"* && ! -s "$T/ra.log" ]]'
feed $'\n  \n' console --stdin
chk "no command on stdin: an error"                        '[[ $rc -ne 0 && "$out" == *"no command on stdin"* ]]'
feed $'saveall\n' console --stdin saveall
chk "--stdin takes no arguments"                           '[[ $rc -ne 0 && "$out" == *"Usage: console --stdin"* && ! -s "$T/ra.log" ]]'

hdr "console COMMAND...: a password command is refused as an argument"
reset
for c in "account create Alice S3cretPw" ".ACCOUNT SET PASSWORD Bob N3wPass1 N3wPass1" "  account   set  password Bob N3wPass1 N3wPass1"; do
    run console saveall "$c"
    chk "refused, nothing sent: $c" '[[ $rc -ne 0 && "$out" == *"carries a password"* && "$out" == *"console --stdin"* && ! -s "$T/ra.log" ]]'
done
run console "account set gmlevel Bob 1" "account onlinelist"
chk "other account commands are still sent"                '[[ $rc -eq 0 ]] && grep -qx "account set gmlevel Bob 1" "$T/ra.log" && grep -qx "account onlinelist" "$T/ra.log"'
reset
run console "bogus thing"
chk "  and an argument command's exit status is as before" '[[ $rc -eq 0 ]]'

hdr "set-account-password --pass-stdin"
printf '%s\t%s\n' "COUNT\\(\\*\\) FROM classicrealmd.account WHERE username='ALICE'" 1 > "$T/sqlmap"
export STUB_SQL_MAP="$T/sqlmap"
reset
feed $'N3wPass1\nignored\n' set-account-password --name alice --pass-stdin
upd="$(grep "^UPDATE classicrealmd.account SET v=" "$T/sql.in" || true)"
UPD_RE="^UPDATE classicrealmd.account SET v='[0-9A-F]+', s='[0-9A-F]+' WHERE username='ALICE';\$"
chk "an account's verifier and salt are replaced"         '[[ $rc -eq 0 && "$out" == *"password is changed"* ]] && grep -qE "$UPD_RE" "$T/sql.in"'
v="$(sed -E "s/.*v='([0-9A-F]+)'.*/\1/" <<<"$upd")"; s="$(sed -E "s/.*s='([0-9A-F]+)'.*/\1/" <<<"$upd")"
chk "  from the first line of stdin (the verifier checks out)" '[[ -n "$v" && "$("$REAL_PY" -I -c "import sys; sys.path.insert(0, sys.argv[1]); import teldrassil as t; print(t.srp6_verifier(\"ALICE\", \"N3wPass1\", int(sys.argv[2], 16))[0])" "$TEST_DIR/../lib" "$s")" == "$v" ]]'
chk "  the password is in no argv (podman, python3)"      'argv_clean N3wPass1 && [[ -s "$T/podman.log" && -s "$T/argv.log" ]]'
chk "  nor in the SQL, nor the output"                    '! grep -qF N3wPass1 "$T/sql.in" && [[ "$out" != *N3wPass1* ]]'
reset
feed $'N3wPass1\n' set-account-password --name bob --pass-stdin
chk "an account that does not exist: a clear error"       '[[ $rc -ne 0 && "$out" == *"No account BOB"* ]] && ! grep -q "^UPDATE" "$T/sql.in"'
reset
feed $'N3wPass1\n' set-account-password --name RndBot7 --pass-stdin
chk "a bot account (BOT_ACCOUNT_PREFIX) is refused"       '[[ $rc -ne 0 && "$out" == *"starts with BOT_ACCOUNT_PREFIX"* && ! -s "$T/podman.log" ]]'
for p in abc 12345678901234567 ""; do
    feed "$p"$'\n' set-account-password --name alice --pass-stdin
    chk "  a password create-account refuses is refused ('$p')" '[[ $rc -ne 0 && "$out" == *"4-16 characters"* ]] && ! grep -q "^UPDATE" "$T/sql.in"'
done
run set-account-password --name alice
chk "without --pass-stdin: refused"                       '[[ $rc -ne 0 && "$out" == *"never taken as an argument"* ]]'
run set-account-password --name alice --pass N3wPass1
chk "  a password flag does not exist"                    '[[ $rc -ne 0 && "$out" == *"unknown flag --pass"* ]]'
run --profile far set SSH_HOST far
reset
feed $'N3wPass1\n' --profile far set-account-password --name alice --pass-stdin
chk "on SSH_HOST too: changed, and in no argv (ssh's included)" '[[ $rc -eq 0 ]] && grep -q "^ssh far " "$T/podman.log" && argv_clean N3wPass1'
unset STUB_SQL_MAP

hdr "dump: an accounts-only dump"
MARK="-- teldrassil accounts-only dump: restore merges it (Kamino 232)"
reset
run dump --db classicrealmd --tables "account account_banned realmcharacters" --no-gzip --out "$T/acc.sql"
chk "is written, and says it will be merged"              '[[ $rc -eq 0 && "$out" == *"accounts-only dump"* ]]'
chk "  rows only: --no-create-info --replace, no DROP TABLE" 'grep -qE "mariadb-dump .*--no-create-info --replace --complete-insert .* classicrealmd account account_banned realmcharacters$" "$T/podman.log"'
chk "  marked on its first line"                          '[[ "$(head -1 "$T/acc.sql")" == "$MARK" ]] && grep -q "CREATE TABLE t" "$T/acc.sql"'
run dump --db classicrealmd --tables account --out "$T/acc1.sql.gz"
chk "  the account table alone is one too (gzipped)"      '[[ $rc -eq 0 && "$(gzip -dc "$T/acc1.sql.gz" | head -1)" == "$MARK" ]]'
reset
run dump --db classicrealmd --tables "account realmlist" --no-gzip --out "$T/notacc.sql"
chk "other realmd tables with it: a plain --tables dump"  '[[ $rc -eq 0 && "$(head -1 "$T/notacc.sql")" != "$MARK" ]] && ! grep -q -- "--no-create-info" "$T/podman.log"'
run dump --db classiccharacters --tables account --no-gzip --out "$T/notacc2.sql"
chk "  so is a table named account in another database"   '[[ $rc -eq 0 && "$(head -1 "$T/notacc2.sql")" != "$MARK" ]]'
mkdir -p "$T/empty"
STUB_DUMP_FAIL=empty run dump --db classicrealmd --tables account --out "$T/empty/acc.sql.gz"
chk "an empty one leaves no file (the mark is not a dump)" '[[ $rc -ne 0 && "$out" == *"nothing was written"* && -z "$(ls -A "$T/empty")" ]]'

hdr "restore: an accounts-only dump is merged"
{ printf '%s\n' "$MARK"
  printf '%s\n' "LOCK TABLES \`account\` WRITE;" \
    "REPLACE INTO \`account\` (\`id\`, \`username\`, \`gmlevel\`, \`v\`, \`s\`, \`joindate\`, \`locked\`) VALUES (1,'ALICE',0,'AA','BB','2026-01-01 00:00:00',0),(2,'RNDBOT1',0,'CC','DD','2026-01-01 00:00:00',0),(3,'TELDRASSIL',3,'EE','FF','2026-01-01 00:00:00',0);" \
    "UNLOCK TABLES;"; } > "$T/merge.sql"
reset
run restore --file "$T/merge.sql" --yes
chk "with the world server running (a merge, not a replace)" '[[ $rc -eq 0 && "$out" == *"Merged"* ]]'
chk "  into a staging database, made LIKE the target's tables" 'grep -qxF "CREATE TABLE \`teldrassil_import\`.\`account\` LIKE \`classicrealmd\`.\`account\`;" "$T/sql.in" && grep -qxF "USE \`teldrassil_import\`;" "$T/sql.in" && grep -qF "REPLACE INTO \`account\`" "$T/sql.in"'
chk "  the dump never touches the target's tables itself" '! grep -qE "^USE .classicrealmd.|DROP TABLE|DELETE FROM|TRUNCATE" "$T/sql.in"'
chk "  merged by name: a matching account is updated, a new one added" 'grep -qE "^INSERT INTO .classicrealmd.\.account \(username, gmlevel, v, s, joindate, locked\) SELECT .* ON DUPLICATE KEY UPDATE gmlevel=VALUES\(gmlevel\), v=VALUES\(v\), s=VALUES\(s\), locked=VALUES\(locked\);$" "$T/sql.in"'
chk "  bot accounts (BOT_ACCOUNT_PREFIX) are left out"   'grep "^INSERT INTO .classicrealmd.\.account " "$T/sql.in" | grep -qF "LEFT(UPPER(i.username), 6) <> '"'"'RNDBOT'"'"'"'
chk "  and the console account (TELDRASSIL and RA_PASS_FILE's TESTER)" 'grep "^INSERT INTO .classicrealmd.\.account " "$T/sql.in" | grep -qF "UPPER(i.username) NOT IN ('"'"'TELDRASSIL'"'"','"'"'TESTER'"'"')"'
chk "  in every merge statement"                         '[[ "$(grep -cF "LEFT(UPPER(i.username), 6) <> '"'"'RNDBOT'"'"'" "$T/sql.in")" == 4 ]]'
chk "  in one transaction, then the staging database is dropped" 'grep -qx "START TRANSACTION;" "$T/sql.in" && [[ "$(tail -2 "$T/sql.in")" == $'"'"'COMMIT;\nDROP DATABASE `teldrassil_import`;'"'"' ]]'
reset
gzip -c "$T/merge.sql" > "$T/merge.sql.gz"
run restore --file "$T/merge.sql.gz" --db otherrealmd --yes
chk "a gzipped one; --db names the target realmd"        '[[ $rc -eq 0 ]] && grep -qF "INSERT INTO \`otherrealmd\`.account" "$T/sql.in"'
reset
run restore --file "$T/merge.sql"
chk "it still needs --yes"                               '[[ $rc -ne 0 && "$out" == *"merges this accounts-only dump"* && ! -s "$T/podman.log" ]]'
reset
STUB_SQL_FAIL="START TRANSACTION" run restore --file "$T/merge.sql" --yes
chk "a merge that fails says so, and drops the staging database" '[[ $rc -ne 0 && "$out" == *"merge failed"* ]] && [[ "$(tail -1 "$T/sql.in")" == "DROP DATABASE IF EXISTS \`teldrassil_import\`;" ]]'

n="$(wc -c < "$T/merge.sql.gz")"; head -c $((n - 8)) "$T/merge.sql.gz" > "$T/cut.sql.gz"
reset
STUB_SQL_FAIL="teldrassil_the_dump_could_not_be_read_whole" run restore --file "$T/cut.sql.gz" --yes
chk "a dump that cannot be read whole is not merged"     '[[ $rc -ne 0 && "$out" == *"merge failed"* ]]'

hdr "restore: an older whole-table dump works as before"
printf '%s\n' "DROP TABLE IF EXISTS \`account\`;" "CREATE TABLE \`account\` (id INT);" > "$T/old.sql"
reset
run restore --file "$T/old.sql" --db classicrealmd --yes
chk "refused while the world server runs"                '[[ $rc -ne 0 && "$out" == *"Stop the world server first"* && ! -s "$T/sql.in" ]]'
run restore --file "$T/old.sql" --db classicrealmd
chk "  and without --yes (it replaces)"                  '[[ $rc -ne 0 && "$out" == *"REPLACES"* ]]'
rm -f "$S/running/$W"
run restore --file "$T/old.sql" --db classicrealmd --yes
chk "  with it stopped: USE the database, then the dump" '[[ $rc -eq 0 && "$(head -1 "$T/sql.in")" == "USE \`classicrealmd\`;" ]] && grep -qF "DROP TABLE IF EXISTS \`account\`" "$T/sql.in" && ! grep -q teldrassil_import "$T/sql.in"'

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
