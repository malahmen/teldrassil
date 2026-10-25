#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# -----------------------------------------------------------------------------
# teldrassil.sh — the engine for a cmangos-classic server with playerbots.
#
# nordrassil's sister tree: where nordrassil runs a VMaNGOS server, teldrassil
# runs cmangos-classic (1.12.1 / client build 5875) built with playerbots, and
# shapes its bots. It is gum-free and flag-driven, with no interactive
# prompts: every command takes flags and a flat key=value config, so it works
# from a shell, a Makefile, CI or cron. A scomp-link front-end
# (wow-cmangos-teldrassil) can collect values and drive it by flags.
#
# This first slice manages a server that is already built and running in
# containers: start, stop, status, the remote console, accounts, and the
# roster - the bots shaped on purpose, their guilds, character cards, the LLM
# and population settings. Building, client-data extraction and the database
# bootstrap come next.
#
# Config: ~/.config/teldrassil/teldrassil.conf (XDG-style, key=value).
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION})." >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -d "${SCRIPT_DIR}/lib" ]] || { echo "[error] ${SCRIPT_DIR}/lib not found — teldrassil.sh runs from its checkout, next to lib/." >&2; exit 1; }
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/runtime.sh"
source "${SCRIPT_DIR}/lib/accounts.sh"
source "${SCRIPT_DIR}/lib/roster.sh"
source "${SCRIPT_DIR}/lib/search.sh"
source "${SCRIPT_DIR}/lib/admin.sh"
source "${SCRIPT_DIR}/lib/attune.sh"

usage() {
    cat >&2 <<'EOF'
teldrassil — cmangos-classic + playerbots server engine (1.12.1)

Usage: teldrassil.sh <command> [flags]

Server:
  start | stop                  stop saves the world first, then disconnects everyone
  restart [--graceful [SECS]]   stop and start here; --graceful asks mangosd to
                                warn players, save and exit in SECS (default 60),
                                then starts it again
  status                        containers, ports, who is online, the LLM endpoint,
                                and a warning while cmangos' default accounts exist
  save                          save every character now
  console COMMAND...            remote-console commands, one per argument.
                                Refuses 'rndbot c' and 'rndbot do': a bot chat
                                command from the console gets no answer and has
                                crashed the server - send those in game.

Accounts:
  create-account --name N (--pass-file F | --pass-stdin) [--level 0-3]
  set-account-level --name N --level 0-3     takes effect at the next full login
  list-accounts [--bots]
  delete-account --name N --yes              only an account with no characters

Characters:
  rename-character --from OLD --to NEW       refused while it is online

Search (up to --limit rows, default 50):
  search --kind items|npcs|objects|quests|teleports --term TEXT
  search --kind characters|bots [--term TEXT] [--zone NAME] [--class C] [--race R]
         [--level N|MIN-MAX] [--guild TEXT] [--online] [--roster-only|--random-only]
  search --kind guilds [--term TEXT]
                                objects: herb and ore nodes, chests, doors - with
                                their spawn counts and maps. Zone names need DBC_DIR.

Administration:
  apply-sql --file PATH --db NAME [--force] [--no-record]
                                run a .sql file; tracked by content hash, so an
                                unchanged file runs once
  dump --all | --db NAME [--tables "a b c"] [--out PATH] [--no-gzip]
                                gzipped, 0600, to ~/.config/teldrassil/dumps by
                                default. Carries CREATE DATABASE, except --tables.
  restore --file PATH --yes [--db NAME]
                                DESTRUCTIVE: replaces the databases the dump
                                names; with the world server stopped

Roster (one JSON file: shaped bots, guilds, ranks, tabards, cards, LLM, population):
  roster check [--file F]       validate it
  roster plan  [--file F]       what applying it would change; changes nothing
  roster show  [--file F]       the roster's bots as the server has them now
  roster apply [--file F] [--fresh-population] --yes
                                stop, write it all in one transaction, start, and
                                apply changed professions ('rndbot upgrade').
                                Without --yes it only shows the plan.
                                --fresh-population first replaces EVERY random
                                bot (and every guild a bot leads) with a new
                                population at the roster's counts.

Bots:
  attune plan|apply [--file ROSTER] [--yes]
                                give bots the raid attunements they cannot earn
                                (Molten Core, Blackwing Lair, Naxxramas), by the
                                roster's "attunements" rules or the defaults:
                                level, and for Naxxramas Honored with the Argent
                                Dawn. Bots only. apply stops the server.
  commands [--any] [--search TEXT] [--verbose]
                                playerbots' chat commands, and who may use each:
                                'anyone' or only the bot's master (the player
                                whose party it is in). Plain words go to the
                                LLM, which only talks; only commands make a
                                bot act.

Config:
  set KEY VALUE | get KEY | config

  help | -h | --help
EOF
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 2; }
    local subcmd="$1"; shift
    case "$subcmd" in
        -h|--help|help) usage; return 0 ;;
        set|get|config) ;;
        *) _settings ;;
    esac
    case "$subcmd" in
        start)              cmd_start "$@" ;;
        stop)               cmd_stop "$@" ;;
        restart)            cmd_restart "$@" ;;
        status)             cmd_status "$@" ;;
        save)               cmd_save "$@" ;;
        console)            cmd_console "$@" ;;
        create-account)     cmd_create_account "$@" ;;
        set-account-level)  cmd_set_account_level "$@" ;;
        list-accounts)      cmd_list_accounts "$@" ;;
        delete-account)     cmd_delete_account "$@" ;;
        rename-character)   cmd_rename_character "$@" ;;
        search)             cmd_search "$@" ;;
        apply-sql)          cmd_apply_sql "$@" ;;
        dump)               cmd_dump "$@" ;;
        restore)            cmd_restore "$@" ;;
        roster)             cmd_roster "$@" ;;
        attune)             cmd_attune "$@" ;;
        commands)           cmd_commands "$@" ;;
        set)                cmd_set "$@" ;;
        get)                cmd_get "$@" ;;
        config)             cmd_config "$@" ;;
        *) error_exit "Unknown command: $subcmd (run with --help for usage)" ;;
    esac
}

main "$@"
