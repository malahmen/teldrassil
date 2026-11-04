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
| `build` | applies teldrassil's patches (`templates/patches/playerbots/` and `templates/patches/mangos-classic/`; already-applied ones are recognised, in a subfolder too), then compiles with playerbots and the extractors. Sources with their own `zlib/` build with no network at all; otherwise zlib is fetched from GitHub |
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
  that worked is reported as one), `status`, `save`, and the remote console:
  `console COMMAND...` (one command per argument) or `console --stdin` (one
  per line of stdin; blank lines skipped, exits non-zero if the console
  reports a command failed).
- **Accounts:** create one, change its password (`set-account-password
  --name N --pass-stdin`), set its GM level, list them, delete one. A name
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
  stopped). See *Moving accounts between servers* below.
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
| `templates/patches/playerbots/`, `templates/patches/mangos-classic/` | teldrassil's changes to playerbots and to the core, applied before every build |
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
`--pass-stdin` (`create-account`, `set-account-password`). A console command
that carries a password - `account create`, `account set password` - is
refused as an argument of `console`; send it on stdin with `console --stdin`,
which hands the commands to the console on stdin too and prints those masked.

### Moving accounts between servers

```sh
./teldrassil.sh --profile old dump --db classicrealmd \
    --tables "account account_banned realmcharacters" --out accounts.sql.gz
./teldrassil.sh --profile new restore --file accounts.sql.gz --yes
```

`dump --db DB_REALMD --tables` with only those tables (`account` among them)
makes an **accounts-only dump**: rows only (`mariadb-dump --no-create-info
--replace --complete-insert`, no DROP or CREATE TABLE), under a first line
that marks it. `restore` recognises that line and **merges** instead of
replacing: the dump is loaded into a staging database (`teldrassil_import`,
dropped afterwards) and merged by account name in one transaction. An account
the target has gets the dump's password (SRP6 verifier and salt), GM level
and lock, and keeps its id and characters; a new one is added, with a
`realmcharacters` row per realm, and the bans of the accounts merged come
along. The dump's bot accounts (`BOT_ACCOUNT_PREFIX`) and console accounts
(TELDRASSIL, `RA_USER`, the `account:` line of `RA_PASS_FILE`) are left out,
so the target's own are never touched, nor any account the dump does not
have. The world server may run. Any other dump - including an accounts dump
made before this, with DROP TABLE - restores as before: it replaces, with the
world server stopped.

### Profiles, and a server elsewhere

One profile per server: `--profile NAME` before the command, or
`$TELDRASSIL_PROFILE`. A profile is `~/.config/teldrassil/profiles/NAME.conf`,
layered over `teldrassil.conf`: what it sets wins, the rest falls through, so
the roster and other shared settings stay in one place. `set` writes to the
active profile and creates it; every other command refuses a profile that does
not exist, so a typo never acts on another server. `profiles` lists them,
`unset KEY` drops one of a profile's settings (the base config's shows through
again), `profile-rename OLD NEW` renames one, and `profile-delete NAME --yes`
removes one - its settings only; the server it pointed at is untouched.

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
- **Priorities** (for a bot without an archetype; with one, they are not
  read - the archetype's activities do this). playerbots runs all of a bot's
  strategies at once and ranks none of them, so every shaped bot gets the
  same base (gathering, vendors and the auction house, questing), and a
  priority adds only what changes behaviour: `wpvp` adds world PvP, and
  `quests` first takes every quest. An archetype listing `wpvp` adds world
  PvP the same way, and one with `quests` first takes every quest.
  Gathering first is a guild **farm order** (`"farm": "Copper Ore 40"`, the
  officer note playerbots reads).
- **Guild members the roster does not name keep their place,** except the top
  rank, which belongs to the leader.
- **A roster bot that leads a guild the roster does not name is not moved.**
  Taking it out would leave that guild with a leader who is not in it; the
  plan says so instead, and the guild needs a new leader in game first.
- **Archetypes** (`"archetypes": {"quester": {...}}`, and `"archetype":
  "quester"` on a bot) are named once and define how a bot behaves. Each one
  has `activities`, most wanted first, from `quests`, `grind`, `gather`, `ah`,
  `wpvp`, `bosses`, `explore`, `rpg`: what the bot travels to do between its
  upkeep (vendors, repairs, trainers, mail, bank), which stays first. An
  activity not listed is still done, after the listed ones. Quests, wpvp and
  grind are every archetype's fallback - its way to the level cap - added after
  its list when it lacks them (wpvp before quests only if it lists wpvp and
  not quests). Below the level cap, world PvP is hunting where the bot is: once
  it has reached the top of its zone's level range, outside a neutral town,
  while an enemy player is in the zone (patch 0014).
  An archetype listing `pvpi` goes to battlegrounds more often (first for a
  free slot, no cool-down) - not a travel goal: it still levels and quests.
  Random bots - those the roster does not list - each draw one of the
  archetypes, by `share` (default 1 each: equal shares; 0: none), the same
  at every start (patch 0023).
  Instead of (or on top of) the list, `weights` give each activity a number,
  optionally from a level on - `{"quests": 3, "gather": 4, "gather@60": 6}`:
  the highest goes first, ties in the order named, and a weight wins over
  the list's place (the list counts as n, n-1 ... 1). 0 is the last resort,
  not never; a `pvpi` weight above 0 makes the archetype `pvpi` (patch 0027).
  Given weights also set how often each activity is tried - its weight over
  the archetype's average times upstream's chance - and an explore weight
  above 0 lets the bot explore at all (patch 0028). `gather_detour`: how far
  off its way the bot goes for a node it passes, in 40-yard steps (0: any it
  sees; unset: upstream's 15 yards); `gather_needs_gold: true` - only when it
  cannot pay its class training, or at the cap while its profession is not
  maxed (patch 0029).

`keep_stacks` (top level of the roster) - stacks of an item a bot keeps
before the rest is sold, by item id: `{"2770": 1, "2775": 10}` (copper ore
one stack, silver ore ten; patch 0031).
  And `gray_quests`: `drop` (the default), `keep` or `at_cap` - whether a
  quest that gives no XP any more is dropped from the bot's log and refused,
  kept, or kept and taken only at the level cap (log space permitting). It also has `pvp`:
  how much stronger the bot's side must be to start a fight with an enemy
  player (`1.2`, the default; `1` an even fight), or `"always"` (every enemy
  player on sight, guards or not) or `"never"` (none, and it keeps away from
  all of them). `"pvp_from_level": {"60": "always"}` changes it from a level
  on. An archetype listing `wpvp` is not held by the world-PvP gates (10% of
  bots, the first 15 minutes of each hour). They are written to
  `aiplayerbot.conf` (`AiPlayerbot.Archetypes`, `AiPlayerbot.Archetype.<name>`).
  A bot without one behaves as playerbots does upstream. The activities are a
  goal list that falls through (patch 0011, below).
- **Moods:** every bot has two for life, from polite, rude, direct, poetic,
  logical, emotional, evil, saint, seductive and repulsive - a polite evil, a
  saint seductive - which colour what it says. playerbots draws them from the
  bot itself, so they are the same at every start, and never two opposites
  (polite/rude, saint/evil, seductive/repulsive, logical/emotional,
  direct/poetic); `"mood": ["polite", "evil"]` on a roster bot names any two
  instead. A pre-prompt can place them with `<bot mood>` ("polite (courteous,
  ...) and evil (cruel, ...)"); without that, playerbots adds a sentence.
- **The `llm` section's values are one line each** (they become lines of
  `aiplayerbot.conf`), and `endpoint` is an http(s) URL.
- **Population:** `{"bots": N, "balance": "50/50"}` sets exact class/race
  counts, half per faction, the roster's own pairs first. Counts apply when
  bots are created: `apply --fresh-population --yes` replaces every random bot
  (and every guild a bot leads) to get them. `"levels": "from 1"` makes every
  bot - the roster's too - start at level 1 in its race's starting area and
  level by playing, like a server's first day (playerbots'
  `DisableRandomLevels`: no rolled level, gear or spells, no teleport by
  level); `"random"`, the default, rolls them. It too takes a fresh population
  to apply to bots that exist already.

teldrassil carries thirty-one changes to playerbots (`templates/patches/playerbots/`)
and two to the core (`templates/patches/mangos-classic/`), applied before
every build:

- **0001:** stored strategies are written as `nc+`/`co+` rows that *add to*
  a bot's defaults - upstream, any stored row replaces them - and bots with
  stored rows load them whether or not a player is online.
- **0002:** a fix for a hang. Bots valuing their items looked each one up in
  an item-rarity cache with `operator[]`, which inserts on a miss; the cache
  is never built, so every lookup was a write, from several map threads at
  once, and the corrupted `std::map` looped forever - the world stopped
  ticking, bots stopped logging in, the console stopped answering. The lookup
  is now read-only.
- **mangos-classic 0001:** a fix for a crash. A creature in ranged mode with
  no main spell (EventAI: "has ranged mode action but no main spell" - the
  Pyrewood Watcher, 1891) reached `UnitAI::IsMainSpellPrevented` with a null
  spell, which it dereferenced: the world server segfaulted (core dump,
  2026-10-29). No spell now counts as prevented. kalimdor commits the same
  change.
- **playerbots 0003 and mangos-classic 0002, together:** bots avoid the other
  faction's guards and towns below the level cap. `avoid mobs` marked the
  shared navmesh around hostile mobs but skipped anything friendly to either
  faction, and long routes charged for the other faction's creatures only past
  10 levels over the bot - a level-30 bot routed past Southshore died to its
  guards. Now a creature friendly to exactly one side is marked with navmesh
  area 15 (dangerous to Alliance) or 16 (to Horde), the core's pathfinder costs
  those by the bot's team, and below the cap a route past the other faction's
  creatures costs five times as much. The two only work as a pair.
- **playerbots 0004:** bots keep away from the other faction's guards well
  above their level (5+), below the cap. Routes alone do not help a bot whose
  destination is beside the guards, so a trigger ("enemy guard near") and an
  action ("move away from enemy guard") in `avoid mobs` keep it outside their
  aggro range + 10 yards - and get it out if one aggroes - and grind targets
  standing in that range are skipped. Weakened (resurrection sickness, or
  below half health) the margin is 40 yards, so a bot revived at a hostile
  graveyard leaves at once; and a ghost whose corpse lies in that range takes
  the spirit healer rather than going back for it. Bots still roam anywhere.
- **playerbots 0005:** in the other faction's territory, getting to safety is
  the objective when there is no other. A bot (with its group) walks out when it
  has no objective there for 45 s - none, one on another continent, or one it
  gets no nearer to - or when the guards block it. The way out is the shortest
  walking route to ground outside hostile territory or to a neutral town (guards
  friendly to both factions, like Ratchet's); a way out that cannot be walked is
  dropped for the next, and the hearthstone is the last resort. It says so in
  General and the log gives the reason. Killing is tied to an objective (a
  quest's mob, or grinding on purpose); a bot dying three times on the way back
  to its body revives at the nearest safe graveyard; and a herb or ore node that
  cannot be picked in 3 minutes is skipped for 30.
- **playerbots 0006:** NPC conversations say whose line each turn is (it was
  never said, so the NPC echoed the bot), keep the lines of speakers whose name
  ends in "d" (they were left out of what the model saw), and a bot does not go
  back to the same NPC to chat again at once.
- **playerbots 0007:** bots pick their fights. A bot weighs its side (itself,
  its group near, pets) against the enemy's (levels, health, numbers, elites,
  guards near) and starts a fight with an enemy player only when the odds
  favour it; one it should not fight is kept away from. It skips a mob whose
  pack is too much, and rests below half health or mana before pulling. A
  fight already on is never refused; battlegrounds and duels are untouched.
- **playerbots 0008:** archetypes as data. A bot's stored archetype ranks its
  travel activities and sets its fight margin (see the roster's archetypes),
  and world PvP has no level gate (upstream: above 50 only); its share-of-bots
  and minutes-per-hour gates are settings (`AiPlayerbot.WorldPvpShare`,
  `WorldPvpMinutes`), skipped for an archetype that lists `wpvp`. The log says
  once per bot which archetype it travels as, and names a part of a definition
  it could not read.
- **playerbots 0009:** every bot carries two moods for life, which its chat
  replies and NPC conversations are told (see the roster's moods).
- **playerbots 0010:** a fix for a crash. Choosing a safe graveyard for a bot
  that died three times (0005) asked its corpse for its zone through the
  corpse's map, which a corpse need not be on; the world server's assertion
  stopped it. The zone is now read from where the corpse lies.
- **playerbots 0011:** an archetype's activities fall through as goals. One
  reached is skipped for good (grinding to level, at the cap); one that finds
  nothing to do is skipped for 60 minutes; one pursued past its budget (bosses
  30 minutes, the rest 2 hours) is skipped for 60 minutes too, and the bot
  moves to its next. The log says which, why and for how long.
- **playerbots 0012:** a goal is not reachable only after finding nothing 3
  times in a row over at least 5 minutes (one miss is often a moment; a
  level-1 quester with quests in its log lost questing for an hour on one).
  Quests, wpvp and grind are every archetype's fallback, so every bot heads
  for the level cap in the end; below level 20 a bot
  with an archetype earns its money questing, not grinding
  (`AiPlayerbot.MoneyGrindMinLevel`). The safe-graveyard
  rule (3 deaths) holds only in hostile territory - elsewhere upstream's 8
  and 10 deaths (a level-4 dwarf who died thrice in Coldridge revived in
  Goldshire). (meksha, 2026-10-31.)
- **playerbots 0013:** where a bot's hearthstone leads. Every bot is bound to
  its race's starting area below level 20 (Goldshire, Kharanos, Dolanaar,
  Razor Hill, Bloodhoof Village, Brill) and to its race's capital from 20; it
  may bind elsewhere, a neutral town included, only where the spot's level is
  within 5 of its own, never in hostile territory - a bind breaking that goes
  back to the default. A level-2 Alliance bot carried to Ratchet bound itself
  there, and every hearth took it back among the Horde. And the hearthstone,
  a stranded bot's last resort, is tried at most every 10 minutes, each try
  letting it walk its ways out again meanwhile - one that did not go off was
  tried every tick, 91 times in a row. (meksha, 2026-10-31.)
- **playerbots 0014:** world PvP by zone. Below the level cap a bot hunts
  enemy players where it is - once it has reached the top of its zone's level
  range (the classic ranges: Elwynn 1-10, the Barrens 10-25, Stranglethorn
  30-45, ...), outside a neutral town, while an enemy player is in the zone;
  with no one to hunt, it quests. Only at the cap is it sent to the world-PvP
  spots. This replaces 0012's level-55 gate: a level-1 wpvper sent to a spot
  was stranded at Ratchet (meksha, 2026-10-31).
- **playerbots 0015:** bots walk into zones above their level: playerbots'
  shortcut - jumping a bot along its path while no player is near - never
  lands it in a zone whose range starts above its level (a level-5 troll was
  found in the Blasted Lands); flight paths, boats, portals and a GM's
  teleports are untouched. For a bot with an archetype a farm order is its
  `gather` goal, no longer above everything (farmers farmed and never
  quested), and gathering needs a profession it can use: herbalism, mining
  with a Mining Pick, skinning with a Skinning Knife. (meksha, 2026-11-01.)
- **playerbots 0017:** after progress on any quest - a kill, an object, an
  item - a bot chooses its next quest objective again: the nearest doable
  one of any quest. With quests x and y, after killing an x mob a nearer y
  mob goes next; upstream finished one objective before looking past its
  sight, walking past other quests' objectives (Kamino 231, 2026-11-01).
- **playerbots 0018:** a bot stranded in a zone more than 5 levels above it,
  contested or hostile, with no objective there or in a neighbouring zone,
  walks out as from hostile territory - to a zone at its level or its own
  faction's city, the hearthstone home after two failed ways out (a level-5
  troll sat 5 hours in the Swamp of Sorrows; meksha, 2026-11-01). Below the
  level cap, upkeep (vendors, repairs, the auction house, mail, bank,
  trainers) never sends a bot into hostile territory, and the default home
  is known by its innkeeper's position (a bot was rebound once a minute).
- **playerbots 0019:** a fix for a crash. The quest re-choice (0017) emptied
  the travel target while a cached "travelling" still let the move action
  read its missing position; the target is now only expired, and the move
  action skips a target without a position (dev server, 2026-11-02).
- **playerbots 0020:** how bots work their quest log. Quests in the log are
  travelled to wherever they are, other continents included; a finished
  quest is turned in first, as upkeep, unless a quest of the bot's zone is
  unfinished; while a bot has quests of its zone that still give XP, its
  activities stay in that zone; a quest that gives no XP is dropped (per
  archetype, `gray_quests`); and below level 20 a hearthstone bind must be
  on the bot's home continent. (meksha, 2026-11-02.)
- **playerbots 0021:** a due turn-in replaces what the bot is doing (held back,
  it was requested 9 times in 2367); grey quests are not taken by a bot that
  drops them, and `gray_quests: at_cap` keeps them at the level cap only;
  random teleports are off (they threw low-level bots into the other
  faction's starting zones) - reviving still teleports, to a zone of the
  bot's level on its home continent, never hostile, one with its quests
  first; out of combat a cast holds the bot in place (a move used to cancel
  it - the hearthstone never went off); and battleground slots per side and
  level band - 10-19: 10, 20-29: 10, 30-39: 15, 40-59: 15 for `pvpi`
  archetypes only, the cap: 40 - `pvpi` archetypes first, the rest with 45
  minutes between battlegrounds. (2026-11-03.)
- **playerbots 0022:** a fix for a crash. A way out (0005, 0018) is a
  temporary destination, freed by the first travel target to move on - but a
  group member copies its leader's target, so the member freed the leader's
  way out under it (dev server core dump, 2026-11-03). Now the last target
  holding one frees it.
- **playerbots 0023:** every random bot follows an archetype: one the roster
  does not list draws one of the roster's archetypes from its fixed number -
  equal shares unless an archetype sets `share` - the same at every start,
  nothing stored, logged once ("draws the archetype"), with the strategies a
  roster bot's archetype gets (quests first: take every quest). Before, only roster
  bots had one. (Owner, 2026-11-03.)
- **playerbots 0024:** bot commands. Any command but add, always and delete
  on an offline bot answers "not online" - `rndbot gear <offline bot>`
  crashed the server; and on random bots the commands that generate gear,
  spells, consumables, levels or pets are a game master's (the console is
  one) - any player could re-roll any random bot. (Kamino 248, 2026-11-04.)
- **playerbots 0025:** a full quest log. A bot meeting a quest giver with a
  quest worth more XP than the weakest unfinished one in its log drops that
  one and takes the new; a quester at the level cap only takes quests with
  room. Attunement quests (`RandomBotQuestIds` and their chains) are never
  dropped, grey or not, and are taken even when grey. And grey is now the
  game's grey level (or `AiPlayerbot.GrayQuestGap` levels below the bot) -
  "gives no XP" never happened, so no grey quest was ever dropped; class and
  profession quests are never grey. (Kamino 250, 2026-11-04.)
- **playerbots 0026:** a random bot's archetype and every bot's moods stay
  fixed - both changed every minute (playerbots' fixed number cycles by
  default), so random bots travelled as all eight archetypes in turn.
  (2026-11-04.)
- **playerbots 0027:** archetypes as weights: one number per activity, from a
  level on (`"gather@60": 6`); higher goes first, ties in the order named;
  quests, wpvp and grind join at 0 when missing - the last resort, not
  never. The `activities` list means weights n ... 1, so nothing changes
  until weights are set; crossing a level where they change rebuilds the
  bot's strategies. (Kamino 249, 2026-11-04.)
- **playerbots 0028:** weights also set how often: with `weights` given, an
  activity's chance per try (upstream's: explore 9%, bosses 49%, quests
  94%...) is multiplied by its weight over the archetype's average, at most
  every time. And exploring is switched on for archetypes weighing it - no
  bot could explore before. (Kamino 249, 2026-11-04.)
- **playerbots 0030:** exploring waits for class training and for the bot's
  quests - except for an archetype whose first activity is exploring (the
  explorer); and it is reached, skipped for good, once both continents are
  explored. (Kamino 255, 2026-11-04.)
- **playerbots 0031:** class training first - the trip to the trainer cuts
  in on what the bot is doing (and a bug fixed under it: no cut-in rule
  ever matched, due turn-ins included); a bot short of money for training
  sells at the auction house; no auction-house buying while training waits;
  and `keep_stacks` - stacks of an item kept before the rest is sold.
  (Kamino 254, 2026-11-04.)
- **playerbots 0029:** gathering as a detour: a bot steps off its way for a
  node as far as its archetype's `gather_detour` says (in 40-yard steps; 0:
  any it sees; upstream 15 yards for everyone), some only when short of
  training money (`gather_needs_gold`); gathering trips go only to zones at
  or below the bot's level. (Kamino 252, 2026-11-04.)
- **playerbots 0016:** quests have no time budget - questing is every bot's
  way forward, and 2 hours cut it off for an hour; and a way out of hostile
  territory never leads into a zone above the bot's level (a level-5 troll
  pushed out of Elwynn slid on to the Blasted Lands) - with none, the
  hearthstone takes it home. (meksha, 2026-11-01.)

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
  (the console would read a second command there) - on stdin, any line with a
  carriage return.
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
