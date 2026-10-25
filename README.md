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

## What it does now

The first slice manages a server that is **already built and running in
containers** (podman or docker): a MariaDB container, a realm server and a
world server. Building, client-data extraction and the database bootstrap are
the next slice.

- **The server:** `start`, `stop` (saves first), `restart`, `status`, `save`,
  and the remote console.
- **Accounts:** create one, set its GM level, list them, delete one.
- **The roster:** one JSON file that says which bots are shaped on purpose and
  how - name, race, class, gender, professions, priorities, guild and rank,
  farm order, character card, preferred guild size - plus the guilds
  themselves (ranks, tabards), the LLM chat settings and the population's
  size. `roster plan` shows what applying it would change; `roster apply
  --yes` makes the server match it.
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

**Secrets never reach a command line.** SQL goes to the database container on
stdin, and the database password is read *inside* that container from
`DB_PASS_FILE`. The console password is read from `RA_PASS_FILE`, and an
account's password from `--pass-file` or `--pass-stdin`.

## The roster

See `examples/roster.example.json`. The rules it enforces:

- **Only 1.12.1's race/class pairs,** two different professions or none, names
  of 2-12 letters, a guild of the bot's own faction, ranks the guild has, a
  leader who is a roster bot at the guild's top rank.
- **A roster bot is bound by name.** If no character has the name yet,
  `apply` takes over a free random bot of the same race and class (one in no
  guild) and renames it. It never touches a player's character.
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
- **Population:** `{"bots": N, "balance": "50/50"}` sets exact class/race
  counts, half per faction, the roster's own pairs first. Counts apply when
  bots are created: `apply --fresh-population --yes` replaces every random bot
  (and every guild a bot leads) to get them.

Two behaviours rely on changes to playerbots (in kalimdor, the source this
server is built from): stored strategies are written as `nc+`/`co+` rows that
*add to* a bot's defaults - upstream, any stored row replaces them - and bots
with stored rows load them whether or not a player is online.

`roster apply` writes the database only while the world server is stopped:
guilds and characters live in its memory, and a change made under it is
overwritten. It saves the world, stops it, writes everything in one
transaction, puts the new `aiplayerbot.conf` and card file in place (keeping
the old ones under `~/.config/teldrassil/backups`), and starts it again.

## Things to know about playerbots

- **Talking to a bot is not commanding it.** Plain words go to the LLM, which
  can only answer. A bot acts on commands, typed exactly; most work only from
  its master (the player whose party it is in), ten from anyone - `commands
  --any` lists them, e.g. `/w <bot> guild invite`.
- **Never send a bot a chat command from the remote console.**
  `rndbot c <bot> ...` and `rndbot do ...` get no answer and have crashed the
  world server; `console` refuses them.
- **cmangos creates four accounts** (ADMINISTRATOR, GAMEMASTER, MODERATOR,
  PLAYER) whose passwords are well known. `status` warns while they exist.

## Tests

```sh
tests/run-all.sh
```

No network, no database, no containers: the helper's roster logic is tested as
plain functions, and `tests/stubs/podman` stands in for the runtime.

## License

MIT - see [LICENSE](LICENSE).
