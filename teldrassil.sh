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
# It builds the server from pinned sources, extracts the client's data,
# installs the databases and runs it all in containers; then it manages the
# running server - the console, accounts, search, administration - and the
# roster: the bots shaped on purpose, their guilds, character cards, the LLM
# and population settings, and their raid attunements.
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
source "${SCRIPT_DIR}/lib/target.sh"
source "${SCRIPT_DIR}/lib/runtime.sh"
source "${SCRIPT_DIR}/lib/accounts.sh"
source "${SCRIPT_DIR}/lib/roster.sh"
source "${SCRIPT_DIR}/lib/search.sh"
source "${SCRIPT_DIR}/lib/admin.sh"
source "${SCRIPT_DIR}/lib/attune.sh"
source "${SCRIPT_DIR}/lib/provision.sh"
source "${SCRIPT_DIR}/lib/llm.sh"

usage() {
    cat >&2 <<'EOF'
teldrassil — cmangos-classic + playerbots server engine (1.12.1)

Usage: teldrassil.sh [--profile NAME | --no-profile] <command> [flags]

Provision (from nothing to a running server; files under WORK_DIR):
  install [--client PATH] --yes run every step below that is not done yet, then start.
                                A database that exists (its container or volume)
                                is kept, never initialised: install starts it,
                                and stops if one of the four databases is missing
  source [--update]             check out cmangos-classic, playerbots and classic-db
                                at the pinned commits (MANGOS_REF, ...)
  build-image                   the build, tools and server image
  build [--jobs N] [--clean]    apply teldrassil's playerbots patches, compile
  extract [--client PATH] [--force]
                                maps, vmaps, mmaps and dbc from the 1.12.1 client
  db-init --yes                 the database container and the four databases
                                (REPLACES existing ones, after dumping them to
                                the dumps folder), the realm's name and
                                address, the console account; removes cmangos'
                                default accounts
  configure [--force]           the server's config files from their templates;
                                an existing one is kept unless --force
  create [--force]              the realm and world server containers
  remove --yes [--database]     delete the server's containers; --database also
                                the database container and volume (everything)

Provisioning builds and runs the server here, in podman; the commands below
also manage one elsewhere (see Profiles).

Server:
  start | stop                  stop saves the world first, then disconnects everyone
  restart [--graceful [SECS]]   stop and start here; --graceful asks mangosd to
                                warn players, save and exit in SECS (default 60);
                                the container's restart policy, or this, starts
                                it again
  status                        containers, ports, who is online, the LLM endpoint,
                                and a warning while cmangos' default accounts exist
  save                          save every character now
  console COMMAND...            remote-console commands, one per argument (an
                                argument with a line break is refused).
                                Refuses 'rndbot c' and 'rndbot do': a bot chat
                                command from the console gets no answer and has
                                crashed the server - send those in game.
  console-account [--file F]    create teldrassil's console account (TELDRASSIL,
                                level 3) with a new random password kept in F
                                (default ~/.config/teldrassil/console-PROFILE.txt),
                                and point RA_USER/RA_PASS_FILE at it. Replaces
                                an existing TELDRASSIL account's password.

Accounts:
  create-account --name N (--pass-file F | --pass-stdin) [--level 0-3]
                                not a name starting with BOT_ACCOUNT_PREFIX
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
  dump --all | --db NAME [--tables "a b c"] [--out PATH [--force]] [--no-gzip]
                                gzipped, 0600, to ~/.config/teldrassil/dumps by
                                default. Carries CREATE DATABASE, except --tables.
                                An existing file is replaced only with --force;
                                a dump that fails leaves no file
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
                                Without --yes it only shows the plan. If a step
                                fails after the stop, the server is started
                                again (attune apply too).
                                --fresh-population first replaces EVERY random
                                bot (and every guild a bot leads) with a new
                                population at the roster's counts. Interrupted
                                after starting a server that was stopped, it
                                stops it again once the deletion is over (up to
                                FRESH_STOP_WAIT s), or leaves it running and
                                says so.
                                A roster guild takes over an existing guild only
                                if all of it is bots of its faction; once applied
                                it is bound to that guild's id

Bots:
  attune plan|apply [--file ROSTER] [--yes]
                                give bots the raid attunements they cannot earn
                                (Molten Core, Blackwing Lair, Naxxramas), by the
                                roster's "attunements" rules or the defaults:
                                level, and for Naxxramas Honored with the Argent
                                Dawn. Bots only. apply stops the server.
  llm status | off | on --endpoint URL --model NAME [--max-tokens N]
         [--reasoning-effort LEVEL] [--bot-to-bot PERCENT] [--api-key-file FILE]
                                bots' chat through a language model (an OpenAI-
                                style endpoint: LM Studio, llama.cpp, a hosted
                                API). Optional and off by default; without it
                                bots answer with playerbots' own lines. Takes
                                effect at the next restart.
  commands [--any] [--search TEXT] [--verbose]
                                playerbots' chat commands, and who may use each:
                                'anyone' or only the bot's master (the player
                                whose party it is in). Plain words go to the
                                LLM, which only talks; only commands make a
                                bot act.

Config:
  set KEY VALUE | get KEY | config | profiles

Profiles (one per server): --profile NAME before the command, or
$TELDRASSIL_PROFILE. A profile is ~/.config/teldrassil/profiles/NAME.conf,
layered over teldrassil.conf: what it sets wins, the rest falls through.
'set' writes to the active profile and creates it; any other command refuses
a profile that does not exist. --no-profile ignores $TELDRASSIL_PROFILE.

  A server elsewhere: SSH_HOST runs podman, kubectl and the console's
  connection there (an ssh destination, e.g. a ~/.ssh/config alias; key-based,
  no prompts). SERVER_KIND=kube runs the world server as a Deployment: stop
  and start scale it to 0 and 1 (its replica count must not be reverted by
  whatever deploys it), and BOT_SECRET names the Secret that holds
  aiplayerbot.conf and the card file, which roster and llm edit. Example, a
  cluster's server reached over ssh:
    --profile meksha set SSH_HOST meksha
    --profile meksha set SERVER_KIND kube
    --profile meksha set KUBE_NAMESPACE kalimdor
    --profile meksha set SERVER_CONTAINER kalimdor-world
    --profile meksha set BOT_SECRET kalimdor-bots
    --profile meksha set DB_CONTAINER mariadb
    --profile meksha set DB_PASS_ENV MARIADB_ROOT_PASSWORD
    --profile meksha set WORLD_PORT 8086
    --profile meksha set CARDS_FILE_IN_SERVER /opt/kalimdor/etc/llm_character_card.txt
    --profile meksha console-account

  help | -h | --help
EOF
}

main() {
    [[ -n "$PROFILE" ]] && _profile_activate "$PROFILE"
    while [[ $# -gt 0 ]]; do case "$1" in
        --profile) _need_value "$@"; _profile_activate "$2"; shift 2 ;;
        --no-profile) _profile_deactivate; shift ;;
        -h|--help) usage; return 0 ;;
        -*) error_exit "Unknown global flag: $1" ;;
        *) break ;;
    esac; done
    [[ $# -gt 0 ]] || { usage; exit 2; }
    local subcmd="$1"; shift
    _profile_require "$subcmd"
    case "$subcmd" in
        help) usage; return 0 ;;
        set|get|config|profiles) ;;
        *) _settings; _check_target "$subcmd" ;;
    esac
    case "$subcmd" in
        start)              cmd_start "$@" ;;
        stop)               cmd_stop "$@" ;;
        restart)            cmd_restart "$@" ;;
        status)             cmd_status "$@" ;;
        save)               cmd_save "$@" ;;
        console)            cmd_console "$@" ;;
        console-account)    cmd_console_account "$@" ;;
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
        llm)                cmd_llm "$@" ;;
        install)            cmd_install "$@" ;;
        source)             cmd_source "$@" ;;
        build-image)        cmd_build_image "$@" ;;
        build)              cmd_build "$@" ;;
        extract)            cmd_extract "$@" ;;
        db-init)            cmd_db_init "$@" ;;
        configure)          cmd_configure "$@" ;;
        create)             cmd_create "$@" ;;
        remove)             cmd_remove "$@" ;;
        commands)           cmd_commands "$@" ;;
        set)                cmd_set "$@" ;;
        get)                cmd_get "$@" ;;
        config)             cmd_config "$@" ;;
        profiles)           cmd_profiles "$@" ;;
        *) error_exit "Unknown command: $subcmd (run with --help for usage)" ;;
    esac
}

main "$@"
