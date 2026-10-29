# teldrassil

> nordrassil's sister tree: a cmangos-classic world where the bots live.

A **gum-free, flag-driven** engine for a
[cmangos-classic](https://github.com/cmangos/mangos-classic) server
(**vanilla WoW 1.12.1 / client build 5875**) built with
[playerbots](https://github.com/cmangos/playerbots), and for shaping the bots
that live in it. Where [nordrassil](https://github.com/malahmen/nordrassil)
runs a VMaNGOS server, teldrassil runs the cmangos one.

It has **no interactive prompts**: every command takes flags and a flat
`key=value` config, so it works from a shell, a Makefile, CI or cron. A
[scomp-link](https://github.com/malahmen/scomp-link) front-end
(`wow-cmangos-teldrassil`) can own the interactivity and drive this by flags.

## What it does

It **builds and runs** the server - from pinned sources to running
containers - and then **manages** it and its bots.

### From nothing to a running server

```sh
./teldrassil.sh install --client ~/wow/1.12.1 --yes
```

runs every step not done yet, in order, then starts the server. It never
replaces a database: where the database container or its volume exists -
stopped after a reboot, still starting, or its container removed - it starts
it, waits for it (`DB_TIMEOUT`, 120 s), and keeps the four databases; if one
of them is missing (or `DB_WORLD` and the like name others), it stops and says
which. Only `db-init --yes`, run by hand, replaces them.

| Step | What it does |
| --- | --- |
| `source` | checks out cmangos-classic, playerbots and classic-db at pinned commits (`MANGOS_REF`, `PLAYERBOTS_REF`, `CLASSICDB_REF`; `source --update` moves to new pins) - or, with `SOURCE_REPO` set, clones one repository holding all three (and `zlib/`), such as kalimdor, at `SOURCE_REF` |
| `build-image` | the one image for building, tools and running (Ubuntu 24.04) |
| `build` | applies teldrassil's playerbots patches (`templates/patches/playerbots/`; already-applied ones are recognised, in a subfolder too), then compiles with playerbots and the extractors. Sources with their own `zlib/` build with no network at all; otherwise zlib is fetched from GitHub |
| `extract` | dbc, maps, vmaps and mmaps from the 1.12.1 client (~20 minutes on many cores, ~2.4 GB) |
| `db-init --yes` | a MariaDB container on 127.0.0.1 only, the four databases from classic-db with playerbots' tables (replacing any that exist, after dumping them to `~/.config/teldrassil/dumps/before-db-init-*.sql.gz`; if the dump fails, nothing is replaced), the realm's name and address, a console account for teldrassil; it removes cmangos' default accounts |
| `configure` | `mangosd.conf`, `realmd.conf`, `aiplayerbot.conf` and `ahbot.conf` from their templates: the database, ports, the remote console on 127.0.0.1, the bot count. An existing file is kept unless `--force`, since `roster apply` edits them |
| `create` | the realm and world server containers, restarted by podman if they crash |

Everything lives under `WORK_DIR` (default `~/.local/share/teldrassil`):
`src/`, `build/`, `install/`, `data/`, `etc/`, `logs/` and `secrets/`
(owner-only: the database passwords and the console account). `remove --yes`
deletes the server's containers; `--database` also deletes the database and
its volume - every account and character.

### Managing it

- **The server:** `start`, `stop` (saves first), `restart` (or `--graceful`:
  players warned, the world saved, mangosd exits and is started again - by
  its container's restart policy when mangosd exits with a failure code,
  else by teldrassil; the container's start time tells which, so a restart
  that worked is reported as one), `status`, `save`, and the remote console.
- **Accounts:** create one, set its GM level, list them, delete one. A name
  starting with `BOT_ACCOUNT_PREFIX` is refused: its characters would count
  as random bots everywhere.
- **Characters:** rename one (refused while it is online: the world server
  would write the old name back).
- **Search:** items, NPCs, objects (herb and ore nodes, chests, doors, with
  spawn counts and maps), quests and teleports in the world database;
  characters and bots - by zone, class, race, level range, guild, online,
  roster or random - and guilds (leader, members online, ranks, tabard).
  Zone names come from the client's `AreaTable.dbc` (`set DBC_DIR`).
- **Administration:** `apply-sql` (a file runs once, tracked by its content
  hash), `dump` (all four databases, one, or some tables; gzipped, 0600;
  an existing file is replaced only with `--force`, and a dump that fails
  or comes out empty leaves no file behind - it is written under a temporary
  name and moved into place once whole) and `restore` (with the world server
  stopped).
- **The roster:** one JSON file that says which bots are shaped on purpose and
  how - name, race, class, gender, professions, priorities, guild and rank,
  farm order, character card, preferred guild size - plus the guilds
  themselves (ranks, tabards), the LLM chat settings and the population's
  size. `roster plan` shows what applying it would change; `roster apply
  --yes` makes the server match it.
- **Attunements:** `attune plan|apply` gives bots the raid attunements they
  cannot earn. Molten Core, Blackwing Lair and Naxxramas check a completed
  quest at the door, and bots never pursue those chains (their dungeon steps
  need a group bots do not form). A rule says what a bot must reach instead -
  by default level 58 for Molten Core, 60 for Blackwing Lair, and 60 plus
  Honored with the Argent Dawn for Naxxramas - and the roster's
  `"attunements"` list can replace them:
  `[{"name": "Naxxramas", "quest": 9378, "level": 60, "reputation":
  {"faction": "argent dawn", "at_least": "honored"}}]`. Bots only; written
  with the world server stopped, since a quest log lives in its memory.
- **playerbots' commands:** the chat commands bots obey, from the server's own
  help texts, marked by who may use each.

## Install / usage

`teldrassil.sh` is a Bash script (bash 4+) with its code in `lib/`, including
one Python 3 helper (`lib/teldrassil.py`, standard library only) for the parts
bash is a poor fit for: JSON, the roster plan, SRP6 and the console protocol.
It runs from its checkout:

```sh
./teldrassil.sh help
```

| File | What is in it |
| ---- | ------------- |
| `teldrassil.sh` | the entry point: usage and command dispatch |
| `lib/common.sh` | logging, the helper call, temporary files |
| `lib/config.sh` | the config store, its keys and defaults; `set`, `get`, `config` |
| `lib/runtime.sh` | the database, the containers and the console; `start`, `stop`, `status`, `save`, `console` |
| `lib/accounts.sh` | the account commands |
| `lib/roster.sh` | the roster commands and `commands` |
| `lib/search.sh` | `search` |
| `lib/admin.sh` | `rename-character`, `apply-sql`, `dump`, `restore`, the graceful restart |
| `lib/attune.sh` | `attune` |
| `lib/provision.sh` | `install`, `source`, `build-image`, `build`, `extract`, `db-init`, `configure`, `create`, `remove` |
| `templates/Containerfile` | the build, tools and server image |
| `templates/patches/playerbots/` | teldrassil's changes to playerbots, applied before every build |
| `lib/teldrassil.py` | the helper |
| `examples/roster.example.json` | a roster to start from |

### Pointing it at a server

Settings live in `~/.config/teldrassil/teldrassil.conf` (mode 0600). `config`
lists every key with its default and what it is for. A typical setup:

```sh
./teldrassil.sh set DB_CONTAINER my-mariadb
./teldrassil.sh set SERVER_CONTAINER my-mangosd
./teldrassil.sh set REALM_CONTAINER my-realmd
./teldrassil.sh set ETC_DIR ~/wow/etc               # holds aiplayerbot.conf
./teldrassil.sh set RA_PASS_FILE ~/wow/console.txt  # the console account's password
./teldrassil.sh set ROSTER_FILE ~/wow/roster.json
./teldrassil.sh status
```

`set` checks what it can: numbers are numbers, and the database names
(`DB_WORLD`, `DB_CHARACTERS`, `DB_REALMD`, `DB_LOGS`) and `BOT_ACCOUNT_PREFIX`
are plain names, since they go into SQL; a config file edited by hand gets the
same checks before any command runs. `PODMAN` may be `docker`: teldrassil
asks only what both answer (`image inspect`, `volume ls`; docker has no
`image exists` or `volume exists`). Under rootful docker, the containers that
write into `WORK_DIR` - the build, the extractors, the database installer and
the realm and world servers (their logs) - run as you (`--user UID:GID`, with
`HOME=/tmp`), so what they write is yours and `build --clean` can remove it;
under rootless docker (`docker info` lists `rootless`) and podman, a
container's root already is you, and nothing is added. Files a rootful docker
wrote before this need `sudo chown -R "$(id -u):$(id -g)" WORK_DIR` once, and
the server containers `create --force` (stopped first) to run as you.

**Secrets never reach a command line.** SQL goes to the database container on
stdin, and the database password is read *inside* that container from
`DB_PASS_FILE`, or from the variable `DB_PASS_ENV` names. The console password
is read from `RA_PASS_FILE`, and an account's password from `--pass-file` or
`--pass-stdin`.

### Profiles, and a server elsewhere

One profile per server: `--profile NAME` before the command, or
`$TELDRASSIL_PROFILE`. A profile is `~/.config/teldrassil/profiles/NAME.conf`,
layered over `teldrassil.conf`: what it sets wins, the rest falls through, so
the roster and other shared settings stay in one place. `set` writes to the
active profile and creates it; every other command refuses a profile that does
not exist, so a typo never acts on another server. `profiles` lists them.

A profile can point at a server on another machine, and at one run in
Kubernetes:

- `SSH_HOST` runs podman, kubectl and the console's connection on that host,
  over ssh (key-based, no prompts; a `~/.ssh/config` alias works). The console
  is reached through `ssh -W`, so it can stay on the host's 127.0.0.1.
- `SERVER_KIND=kube` runs the world server as the Deployment `SERVER_CONTAINER`
  names, in `KUBE_NAMESPACE`. `stop` saves, scales it to 0 and waits until its
  pod is gone - only then is the database written - and `start` scales it to 1
  and waits for the log. Whatever deploys it must leave its replica count
  alone (Argo CD: `ignoreDifferences` on `/spec/replicas`). The login server
  is not teldrassil's to start there.
- `BOT_SECRET` names the Secret holding `aiplayerbot.conf` and the card file.
  `roster` and `llm` edit a copy and write the Secret back when it changed:
  before the server starts, and when the command ends.

kalimdor on meksha's cluster:

```sh
P="./teldrassil.sh --profile meksha"
$P set SSH_HOST meksha
$P set SERVER_KIND kube
$P set KUBE_NAMESPACE kalimdor
$P set SERVER_CONTAINER kalimdor-world
$P set BOT_SECRET kalimdor-bots
$P set DB_CONTAINER mariadb
$P set DB_PASS_ENV MARIADB_ROOT_PASSWORD
$P set WORLD_PORT 8086
$P set CARDS_FILE_IN_SERVER /opt/kalimdor/etc/llm_character_card.txt
$P console-account          # TELDRASSIL, level 3, password in ~/.config/teldrassil
$P status
```

Provisioning (`install` and its steps) builds and runs a server on this host
only, and is refused in such a profile.

## The roster

See `examples/roster.example.json`. The rules it enforces:

- **Only 1.12.1's race/class pairs,** two different professions or none, names
  of 2-12 letters, a guild of the bot's own faction, 5 to 10 guild ranks
  (cmangos resets a guild with fewer to its defaults), ranks the guild has, a
  leader who is a roster bot at the guild's top rank.
- **A roster bot is bound by name.** If no character has the name yet,
  `apply` takes over a free random bot of the same race and class - one in no
  guild, or else one in playerbots' own random guilds, never a guild's leader
  - and renames it. It never touches a player's character.
- **A roster guild never takes over a players' guild.** The first `apply`
  creates it, or takes over an existing guild of its name only when that
  guild's leader and every member are bots (`BOT_ACCOUNT_PREFIX` accounts) of
  the roster guild's faction; anything else - a player leading it or in it,
  the other faction, a leader that is no character - is a plan error naming
  the guild and why, and nothing is applied (the server is not stopped).
  Once applied, the roster guild is bound to that guild's id and creation
  date in `~/.config/teldrassil/roster-guilds.json` (`roster-guilds-PROFILE.json`
  in a profile), so a rename cannot point it at another guild; players may
  join it since, but its leader must stay a bot of its faction. A binding
  whose guild is gone or was replaced is dropped.
- **Gender:** changing it resets the appearance to the race's first options,
  the only ones certain to exist for both genders.
- **Professions** are stored for playerbots and applied with `rndbot upgrade`
  after the server starts.
- **Priorities.** playerbots runs all of a bot's strategies at once and ranks
  none of them, so every shaped bot gets the same base (gathering, vendors
  and the auction house, questing), and a priority adds only what changes
  behaviour: `wpvp` adds world PvP, and `quests` first takes every quest.
  Gathering first is a guild **farm order** (`"farm": "Copper Ore 40"`, the
  officer note playerbots reads).
- **Guild members the roster does not name keep their place,** except the top
  rank, which belongs to the leader.
- **A roster bot that leads a guild the roster does not name is not moved.**
  Taking it out would leave that guild with a leader who is not in it; the
  plan says so instead, and the guild needs a new leader in game first.
- **The `llm` section's values are one line each** (they become lines of
  `aiplayerbot.conf`), and `endpoint` is an http(s) URL.
- **Population:** `{"bots": N, "balance": "50/50"}` sets exact class/race
  counts, half per faction, the roster's own pairs first. Counts apply when
  bots are created: `apply --fresh-population --yes` replaces every random bot
  (and every guild a bot leads) to get them.

teldrassil carries two changes to playerbots (`templates/patches/playerbots/`,
applied before every build):

- **0001:** stored strategies are written as `nc+`/`co+` rows that *add to*
  a bot's defaults - upstream, any stored row replaces them - and bots with
  stored rows load them whether or not a player is online.
- **0002:** a fix for a hang. Bots valuing their items looked each one up in
  an item-rarity cache with `operator[]`, which inserts on a miss; the cache
  is never built, so every lookup was a write, from several map threads at
  once, and the corrupted `std::map` looped forever - the world stopped
  ticking, bots stopped logging in, the console stopped answering. The lookup
  is now read-only.

`roster apply` writes the database only while the world server is stopped:
guilds and characters live in its memory, and a change made under it is
overwritten. It saves the world, stops it, writes everything in one
transaction, puts the new `aiplayerbot.conf` and card file in place (keeping
the old ones under `~/.config/teldrassil/backups`), and starts it again.

**A failed step leaves the realm as it found it.** Once `roster apply` or
`attune apply` has stopped a running world server, whatever ends it early -
the state query, the plan, a refused transaction, Ctrl-C - starts the server
again on the way out. `--fresh-population` turns guild deletion on and random
guilds off for its one start; if that start does not get through (it fails,
an error, a signal), both settings go back to what they were and the pending
"delete every random bot" request is withdrawn, so no later start deletes
anything. The roster's population counts stay. If the world server was
stopped before the command and the fresh population had already started it,
it is stopped again (saved, then stopped) once the deletion is over - the
request gone from `ai_playerbot_random_bots` and the count of bot characters
no longer falling - waiting up to `FRESH_STOP_WAIT` (120 s). A deletion that
takes longer is not cut short: the server is left running, and teldrassil
says so and how to stop it (`stop`, a few minutes later). A server that was
running before is left running.

## Things to know about playerbots

- **Talking to a bot is not commanding it.** Plain words go to the LLM, which
  can only answer. A bot acts on commands, typed exactly; most work only from
  its master (the player whose party it is in), ten from anyone - `commands
  --any` lists them, e.g. `/w <bot> guild invite`.
- **Never send a bot a chat command from the remote console.**
  `rndbot c <bot> ...` and `rndbot do ...` get no answer and have crashed the
  world server; `console` refuses them, and any argument with a line break
  (the console would read a second command there).
- **cmangos creates four accounts** (ADMINISTRATOR, GAMEMASTER, MODERATOR,
  PLAYER) whose passwords are well known. `status` warns while they exist.

## Tests

```sh
tests/run-all.sh
```

No network, no database, no containers: the helper's roster logic is tested as
plain functions, `tests/stubs/` stands in for podman, ssh and kubectl, and
`tests/fake_ra.py` for the remote console, on a free port of 127.0.0.1. The
ssh stub runs its command here after a second shell parse, as a real host
would, so a quoting mistake fails a test rather than a server.

## License

MIT - see [LICENSE](LICENSE).
