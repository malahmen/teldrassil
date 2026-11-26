#!/usr/bin/env bash
# _world_sql, pulled out of lib/admin.sh, against a stand-in database: kalimdor's
# world-database files (Kamino 298) run before the world server starts - from
# a kalimdor tree's sql/, else teldrassil's templates/sql/ - each once per
# content, a failing one skipped, and only for a server built and run here.
# shellcheck disable=SC2034,SC2016,SC2015  # globals read by the code under test; chk evaluates its single-quoted checks
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for f in _applied_table _sql_was_applied _sql_record _sql_forget _world_sql; do
    eval "$(sed -n "/^${f}() {/,/^}/p" "$TEST_DIR/../lib/admin.sh")"
    declare -F "$f" >/dev/null || { echo "no $f in lib/admin.sh"; exit 1; }
done
eval "$(grep -E '^_commits_changes\(\) \{' "$TEST_DIR/../lib/provision.sh")"
eval "$(grep -E '^_sql_str\(\) \{' "$TEST_DIR/../lib/runtime.sh")"
declare -F _commits_changes >/dev/null && declare -F _sql_str >/dev/null || { echo "no _commits_changes/_sql_str"; exit 1; }

info() { :; }; success() { echo "ok: $*"; }; warn() { echo "warn: $*"; }

# The stand-in database: the record is a file of "hash db" lines; a script
# run is logged by its marker line; a script holding FAIL fails.
REC="$T/record"; RAN="$T/ran"; : > "$REC"; : > "$RAN"
_db_raw() {
    local sql; sql="$(cat)"
    case "$sql" in
        "CREATE TABLE"*) return 0 ;;
        "REPLACE INTO"*) sed -E "s/.*VALUES \('([0-9a-f]+)', '[^']*', '([^']*)'.*/\1 \2/" <<<"$sql" >> "$REC" ;;
        "DELETE FROM"*)  local d; d="$(sed -E "s/.*IN \('([^']*)'.*/\1/" <<<"$sql")"; grep -v " ${d}\$" "$REC" > "$REC.n"; mv "$REC.n" "$REC" ;;
        *FAIL*) return 1 ;;
        *) grep -oE 'marker [a-z0-9-]+' <<<"$sql" >> "$RAN" ;;
    esac
}
_db_value() { local h; h="$(sed -E "s/.*sha256='([0-9a-f]+)' AND db='([^']*)'.*/\1 \2/" <<<"$1")"; grep -cx "$h" "$REC" || true; }

KUBE=0; _is_kube() { (( KUBE )); }
SCRIPT_DIR="$T/teldrassil"; SOURCE_DIR="$T/src"; WORK_DIR="$T/work"; SSH_HOST=""
DB_REALMD=realmd; DB_WORLD=world
_paths() { SRC_PB="${SOURCE_DIR}/playerbots"; INSTALL="${WORK_DIR}/install"; }
mkdir -p "$SCRIPT_DIR/templates/sql" "$SOURCE_DIR/playerbots" "$WORK_DIR/install/bin"
printf -- '-- marker tpl-one\n' > "$SCRIPT_DIR/templates/sql/0001-one.sql"
printf -- '-- marker tpl-two\n' > "$SCRIPT_DIR/templates/sql/0002-two.sql"
ran() { tr '\n' ' ' < "$RAN"; }

printf '\n== no server built here: nothing runs\n'
_world_sql >/dev/null
chk "without install/bin/mangosd nothing is applied" '[[ ! -s "$RAN" ]]'
touch "$WORK_DIR/install/bin/mangosd"; chmod +x "$WORK_DIR/install/bin/mangosd"
SSH_HOST=box; _world_sql >/dev/null; SSH_HOST=""
chk "on SSH_HOST nothing is applied"            '[[ ! -s "$RAN" ]]'
KUBE=1; _world_sql >/dev/null; KUBE=0
chk "in a cluster nothing is applied"           '[[ ! -s "$RAN" ]]'

printf '\n== the upstream path: templates/sql/\n'
out="$(_world_sql)"
chk "both run, in order"                        '[[ "$(ran)" == "marker tpl-one marker tpl-two " ]]'
chk "  and say so"                              '[[ "$out" == *"0001-one.sql applied"* && "$out" == *"0002-two.sql applied"* ]]'
: > "$RAN"; _world_sql >/dev/null
chk "again: unchanged files are skipped"        '[[ ! -s "$RAN" ]]'
printf -- '-- marker tpl-two-b\n' > "$SCRIPT_DIR/templates/sql/0002-two.sql"
printf -- '-- marker tpl-three\n' > "$SCRIPT_DIR/templates/sql/0003-three.sql"
_world_sql >/dev/null
chk "a changed and a new file run, the rest not" '[[ "$(ran)" == "marker tpl-two-b marker tpl-three " ]]'

printf '\n== a failing file is said and skipped\n'
: > "$RAN"; printf -- '-- FAIL\n' > "$SCRIPT_DIR/templates/sql/0004-bad.sql"
printf -- '-- marker tpl-five\n' > "$SCRIPT_DIR/templates/sql/0005-five.sql"
out="$(_world_sql)"; rc=$?
chk "it warns, and the start goes on (rc 0)"    '[[ $rc -eq 0 && "$out" == *"0004-bad.sql failed"* ]]'
chk "  the files after it still run"            '[[ "$(ran)" == "marker tpl-five " ]]'
chk "  and it is not recorded: it tries again"  '[[ "$(_world_sql)" == *"0004-bad.sql failed"* ]]'
rm "$SCRIPT_DIR/templates/sql/0004-bad.sql"

printf '\n== a restore forgets what ran on that database\n'
: > "$RAN"; _sql_forget world; _world_sql >/dev/null
chk "everything runs again"                     '[[ "$(ran)" == "marker tpl-one marker tpl-two-b marker tpl-three marker tpl-five " ]]'

printf '\n== a kalimdor tree: its own sql/, not the templates\n'
mkdir -p "$SOURCE_DIR/sql"; touch "$SOURCE_DIR/PROVENANCE.md"
printf -- '-- marker kal-routes\n' > "$SOURCE_DIR/sql/0003-dungeon-routes.sql"
: > "$RAN"; _world_sql >/dev/null
chk "only the tree's files run"                 '[[ "$(ran)" == "marker kal-routes " ]]'

printf '\npass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
