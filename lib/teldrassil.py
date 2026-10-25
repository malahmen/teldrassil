#!/usr/bin/env python3
"""teldrassil's helper: the parts that are poor fits for bash.

Called by teldrassil.sh, never by hand. Standard library only.

  ra          send commands to mangosd's remote console (RA)
  srp6        an account's SRP6 verifier and salt, password on stdin
  state-sql   the one query that reads what a roster plan needs, as JSON
  check       validate a roster file
  plan        compare a roster with the database state; write the SQL, the
              card file and the new aiplayerbot.conf that would apply it
  commands    playerbots' chat commands from its help texts

The roster logic is pure functions over plain data (load_roster, plan), so
the tests run it without a server or a database.
"""
import argparse
import hashlib
import json
import re
import secrets
import socket
import sys
import time

# ----------------------------------------------------------------------------
# Vanilla (1.12.1) data
# ----------------------------------------------------------------------------

RACES = {"human": 1, "orc": 2, "dwarf": 3, "night elf": 4, "undead": 5,
         "tauren": 6, "gnome": 7, "troll": 8}
ALLIANCE = {1, 3, 4, 7}
HORDE = {2, 5, 6, 8}
CLASSES = {"warrior": 1, "paladin": 2, "hunter": 3, "rogue": 4, "priest": 5,
           "shaman": 7, "mage": 8, "warlock": 9, "druid": 11}
# The race/class pairs a 1.12.1 character can be.
LEGAL = {
    1: {1, 2, 4, 5, 8, 9},     # human
    2: {1, 3, 4, 7, 9},        # orc
    3: {1, 2, 3, 4, 5},        # dwarf
    4: {1, 3, 4, 5, 11},       # night elf
    5: {1, 4, 5, 8, 9},        # undead
    6: {1, 3, 7, 11},          # tauren
    7: {1, 4, 8, 9},           # gnome
    8: {1, 3, 4, 5, 7, 8},     # troll
}
PROFESSIONS = {"alchemy": 171, "blacksmithing": 164, "enchanting": 333,
               "engineering": 202, "herbalism": 182, "leatherworking": 165,
               "mining": 186, "skinning": 393, "tailoring": 197}
GENDERS = {"male": 0, "female": 1}
# playerbots' preferred guild sizes (GuilderType); stored as an override.
GUILD_SIZES = {"solo": 0, "tiny": 30, "small": 50, "medium": 70,
               "large": 120, "massive": 250}

# The priority words a roster may use, and what each adds. playerbots runs
# every strategy a bot has at once and ranks none of them, so every shaped bot
# gets the same base (gathering, vendors and the auction house - repairs and
# mail too - and questing), and a priority only adds what changes behaviour:
# world PvP wherever it is listed, and taking every quest when quests come
# first. Gathering first is expressed by a guild farm order, not a strategy.
BASE_STRATEGIES = ["gather", "reveal", "rpg vendor", "rpg quest", "quest"]
PRIORITY_STRATEGIES = {
    "gather": [],
    "ah": [],
    "quests": [],
    "wpvp": ["pvp"],
    "dungeons": [],
    "raids": [],
    "others": [],
}
TOP_PULL = {"quests": ["accept all quests"]}
# One canonical order, so the same roster always writes the same row.
STRATEGY_ORDER = ["gather", "reveal", "rpg vendor", "rpg quest", "quest",
                  "accept all quests", "pvp"]
COMBAT_STRATEGIES = {"pvp"}

# Guild rank rights as the game writes them: officers get everything,
# everyone else chat, listen and invite-free basics.
RIGHTS_OFFICER = 1044991
RIGHTS_MEMBER = 67

TABARD_FIELDS = [("symbol", "EmblemStyle"), ("symbol_color", "EmblemColor"),
                 ("border", "BorderStyle"), ("border_color", "BorderColor"),
                 ("background", "BackgroundColor")]

CARD_PREFIX = "manual saved string::llmdefaultprompt>"
GUILDER_PREFIX = "manual saved int::guilder override>"

# The commands a bot accepts from any player; every other one only from its
# master (playerbots: PlayerbotAI::IsAllowedCommand).
ANY_PLAYER_COMMANDS = ["who", "where", "wts", "sendmail", "invite", "leave",
                       "join", "lfg", "guild invite", "guild leave"]


class RosterError(Exception):
    pass


# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

def sql_str(s):
    """A MariaDB string literal (default sql_mode: backslash escapes)."""
    s = str(s).replace("\x00", "")
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def faction_of(race):
    return "alliance" if race in ALLIANCE else "horde"


def read_secret(path):
    """A password from a file: a 'password:' line if there is one, else the
    first non-empty line. Never echoed."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"^\s*password:\s*(\S+)", text, re.M)
    if m:
        return m.group(1)
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    raise SystemExit(f"no password in {path}")


def read_user(path):
    with open(path, encoding="utf-8") as f:
        m = re.search(r"^\s*account:\s*(\S+)", f.read(), re.M)
    return m.group(1) if m else None


# ----------------------------------------------------------------------------
# SRP6 (cmangos: SRP6::CalculateVerifier)
# ----------------------------------------------------------------------------

SRP_N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
SRP_G = 7


def srp6_verifier(user, password, salt=None):
    """(v, s) as the realm stores them: upper-case hex, no padding.

    The byte order is cmangos': the salt is used little-endian, and the
    SHA-1 of salt + H(USER:PASS) is read back little-endian. Account names
    and passwords are upper-cased first, as the server does."""
    user, password = user.upper(), password.upper()
    if salt is None:
        while True:
            salt = int.from_bytes(secrets.token_bytes(32), "big")
            if salt >> 252:          # a full 32 bytes, no leading zero
                break
    digest = hashlib.sha1(f"{user}:{password}".encode()).digest()
    s_le = salt.to_bytes(32, "big")[::-1]
    x = int.from_bytes(hashlib.sha1(s_le + digest).digest(), "little")
    return f"{pow(SRP_G, x, SRP_N):X}", f"{salt:X}"


# ----------------------------------------------------------------------------
# Remote console
# ----------------------------------------------------------------------------

def ra_send(host, port, user, password, commands, wait=1.5):
    s = socket.create_connection((host, port), timeout=10)

    def read(pause=0.8):
        time.sleep(pause)
        s.settimeout(0.5)
        out = b""
        try:
            while True:
                d = s.recv(65536)
                if not d:
                    break
                out += d
        except socket.timeout:
            pass
        return out.decode("utf-8", "replace")

    read()
    s.sendall(user.encode() + b"\r\n")
    read()
    s.sendall(password.encode() + b"\r\n")
    login = read(1.2)
    if "Logged in" not in login and "+" not in login:
        s.close()
        raise SystemExit("remote console login failed: " + login.strip()[-200:])
    results = []
    for cmd in commands:
        s.sendall(cmd.encode() + b"\r\n")
        out = read(wait)
        out = "\n".join(l for l in out.splitlines()
                        if l.strip() and l.strip() not in ("mangos>", ">"))
        out = re.sub(r"^mangos>\s*", "", out, flags=re.M)
        results.append((cmd, out.strip()))
    s.close()
    return results


# ----------------------------------------------------------------------------
# The roster
# ----------------------------------------------------------------------------

def _lookup(table, value, what, where):
    key = str(value).strip().lower()
    if key not in table:
        raise RosterError(f"{where}: unknown {what} '{value}' (one of: {', '.join(sorted(table))})")
    return table[key]


def load_roster(data):
    """Validate a roster (parsed JSON) and return it normalised: IDs instead
    of words, defaults filled in. Raises RosterError listing every problem."""
    errors = []
    out = {"guilds": [], "bots": [], "population": None, "llm": None}

    guild_names = {}
    for i, g in enumerate(data.get("guilds", [])):
        where = f"guilds[{i}]"
        try:
            name = g["name"]
            if not re.fullmatch(r"[A-Za-z][A-Za-z ']{1,23}", name):
                raise RosterError(f"{where}: guild name '{name}' must be 2-24 letters, spaces or apostrophes")
            if name.lower() in guild_names:
                raise RosterError(f"{where}: guild '{name}' is listed twice")
            faction = str(g.get("faction", "")).lower()
            if faction not in ("alliance", "horde"):
                raise RosterError(f"{where}: faction must be alliance or horde")
            ranks = g.get("ranks") or ["Guild Master", "Officer", "Veteran", "Member", "Initiate"]
            if not 2 <= len(ranks) <= 10:
                raise RosterError(f"{where}: a guild has 2 to 10 ranks")
            for r in ranks:
                if not 1 <= len(r) <= 15:
                    raise RosterError(f"{where}: rank name '{r}' must be 1-15 characters")
            officers = int(g.get("officer_ranks", 2))
            tabard = None
            if "tabard" in g:
                t = g["tabard"]
                tabard = {}
                for k, _col in TABARD_FIELDS:
                    if k not in t:
                        raise RosterError(f"{where}: tabard needs {', '.join(k for k, _ in TABARD_FIELDS)}")
                    tabard[k] = int(t[k])
            guild_names[name.lower()] = len(out["guilds"])
            out["guilds"].append({"name": name, "faction": faction, "leader": g.get("leader"),
                                  "ranks": list(ranks), "officers": officers, "tabard": tabard,
                                  "info": g.get("info", ""), "motd": g.get("motd", "")})
        except (RosterError, KeyError, ValueError, TypeError) as e:
            errors.append(str(e) if isinstance(e, RosterError) else f"{where}: {e!r}")

    names = set()
    for i, b in enumerate(data.get("bots", [])):
        where = f"bots[{i}]"
        try:
            name = b["name"]
            where = f"bot {name}"
            if not re.fullmatch(r"[A-Z][a-z]{1,11}", name):
                raise RosterError(f"{where}: a name is 2-12 letters, capital first, the rest lower-case")
            if name in names:
                raise RosterError(f"{where}: listed twice")
            names.add(name)
            race = _lookup(RACES, b["race"], "race", where)
            cls = _lookup(CLASSES, b["class"], "class", where)
            if cls not in LEGAL[race]:
                raise RosterError(f"{where}: a {b['race']} cannot be a {b['class']} in 1.12.1")
            gender = _lookup(GENDERS, b.get("gender", "male"), "gender", where)
            profs = [_lookup(PROFESSIONS, p, "profession", where) for p in b.get("professions", [])]
            if len(profs) not in (0, 2):
                raise RosterError(f"{where}: give two professions, or none (playerbots picks)")
            if len(profs) == 2 and profs[0] == profs[1]:
                raise RosterError(f"{where}: the two professions must differ")
            prios = [str(p).lower() for p in b.get("priorities", [])]
            for p in prios:
                if p not in PRIORITY_STRATEGIES:
                    raise RosterError(f"{where}: unknown priority '{p}' (one of: {', '.join(PRIORITY_STRATEGIES)})")
            guild = b.get("guild")
            rank = b.get("rank")
            if guild is not None:
                gi = guild_names.get(guild.lower())
                if gi is None:
                    raise RosterError(f"{where}: guild '{guild}' is not in the roster's guilds")
                gd = out["guilds"][gi]
                if gd["faction"] != faction_of(race):
                    raise RosterError(f"{where}: a {faction_of(race)} bot cannot join {gd['faction']} guild '{guild}'")
                guild = gd["name"]
                if rank is not None and rank not in gd["ranks"]:
                    raise RosterError(f"{where}: rank '{rank}' is not one of {guild}'s ranks")
            elif rank is not None:
                raise RosterError(f"{where}: a rank needs a guild")
            size = b.get("guild_size", "medium" if guild else None)
            if size is not None:
                size = _lookup(GUILD_SIZES, size, "guild size", where)
            card = b.get("card")
            if card is not None and ("\n" in card or "::" in card):
                raise RosterError(f"{where}: a card is one line, without '::'")
            out["bots"].append({"name": name, "race": race, "class": cls, "gender": gender,
                                "professions": profs, "priorities": prios, "guild": guild,
                                "rank": rank, "farm": b.get("farm"), "note": b.get("note", ""),
                                "card": card, "guild_size": size,
                                "spec": b.get("spec"), "goal": b.get("goal")})
        except (RosterError, KeyError, ValueError, TypeError) as e:
            errors.append(str(e) if isinstance(e, RosterError) else f"{where}: missing {e}")

    for g in out["guilds"]:
        if g["leader"] is None:
            errors.append(f"guild {g['name']}: no leader")
            continue
        lead = next((b for b in out["bots"] if b["name"] == g["leader"]), None)
        if lead is None or lead["guild"] != g["name"]:
            errors.append(f"guild {g['name']}: leader {g['leader']} must be a bot of the roster in that guild")
        elif lead["rank"] not in (None, g["ranks"][0]):
            errors.append(f"guild {g['name']}: leader {g['leader']} must hold the top rank, {g['ranks'][0]}")

    if "population" in data:
        p = data["population"]
        try:
            bots = int(p["bots"])
            if bots < len(out["bots"]):
                raise RosterError("population: fewer bots than the roster names")
            if p.get("balance", "50/50") != "50/50":
                raise RosterError("population: only balance 50/50 is supported")
            out["population"] = {"bots": bots}
        except (RosterError, KeyError, ValueError, TypeError) as e:
            errors.append(str(e) if isinstance(e, RosterError) else f"population: {e!r}")
    if "llm" in data:
        out["llm"] = dict(data["llm"])

    if errors:
        raise RosterError("\n".join(errors))
    return out


def strategies_for(prios):
    """(non-combat, combat) strategy names for a priority list."""
    wanted = set(BASE_STRATEGIES)
    for p in prios:
        wanted.update(PRIORITY_STRATEGIES[p])
    if prios:
        wanted.update(TOP_PULL.get(prios[0], []))
    nc = [s for s in STRATEGY_ORDER if s in wanted]
    co = [s for s in STRATEGY_ORDER if s in wanted and s in COMBAT_STRATEGIES]
    return nc, co


def population_counts(roster, total):
    """Exact class/race head-counts: half per faction, the roster's own pairs
    first, then the rest spread round-robin over every legal pair."""
    counts = {}
    for b in roster["bots"]:
        k = (b["class"], b["race"])
        counts[k] = counts.get(k, 0) + 1
    for races in (sorted(ALLIANCE), sorted(HORDE)):
        target = total // 2
        pairs = [(c, r) for r in races for c in sorted(LEGAL[r])]
        have = sum(n for (c, r), n in counts.items() if r in races)
        if have > target:
            raise RosterError(f"population: the roster has {have} bots of one faction, more than half of {total}")
        i = 0
        while have < target:
            k = pairs[i % len(pairs)]
            counts[k] = counts.get(k, 0) + 1
            have += 1
            i += 1
    return counts


def conf_set(text, key, value):
    """Set 'key = value' in a mangos-style conf, uncommenting it if needed."""
    pat = re.compile(rf"^#?\s*{re.escape(key)}\s*=.*$", re.M)
    line = f"{key} = {value}"
    if pat.search(text):
        return pat.sub(lambda m: line, text, count=1)
    return text.rstrip("\n") + f"\n{line}\n"


def conf_get(text, key):
    m = re.search(rf"^{re.escape(key)}\s*=\s*(.*)$", text, re.M)
    return m.group(1).strip() if m else None


def conf_changes(roster, conf_text, cards_in_server):
    """{key: value} the roster wants in aiplayerbot.conf."""
    want = {}
    pop = roster["population"]
    if pop:
        counts = population_counts(roster, pop["bots"])
        want["AiPlayerbot.ClassRace.UseFixedClassRaceCounts"] = "1"
        want["AiPlayerbot.MinRandomBots"] = str(pop["bots"])
        want["AiPlayerbot.MaxRandomBots"] = str(pop["bots"])
        for r in sorted(LEGAL):
            for c in sorted(LEGAL[r]):
                want[f"AiPlayerbot.ClassRaceProb.{c}.{r}"] = str(counts.get((c, r), 0))
        # Pairs the conf has that cannot exist: zero, so a fixed count never
        # asks for them.
        for c, r in re.findall(r"^AiPlayerbot\.ClassRaceProb\.(\d+)\.(\d+)\s*=", conf_text, re.M):
            k = f"AiPlayerbot.ClassRaceProb.{c}.{r}"
            want.setdefault(k, "0")
    llm = roster["llm"]
    if llm:
        want["AiPlayerbot.LLMEnabled"] = str(llm.get("enabled", 2))
        if "endpoint" in llm:
            want["AiPlayerbot.LLMApiEndpoint"] = llm["endpoint"]
        if "model" in llm:
            body = {"model": llm["model"],
                    "messages": [{"role": "system", "content": "<pre prompt> <context>"},
                                 {"role": "user", "content": "<prompt>"}],
                    "max_tokens": int(llm.get("max_tokens", 80))}
            if "reasoning_effort" in llm:
                body["reasoning_effort"] = llm["reasoning_effort"]
            want["AiPlayerbot.LLMApiJson"] = json.dumps(body)
            want["AiPlayerbot.LLMResponseStartPattern"] = '("content":\\s*")'
        if "pre_prompt" in llm:
            want["AiPlayerbot.LLMPrePrompt"] = llm["pre_prompt"]
        want["AiPlayerbot.LLMBotToBotChatChance"] = str(llm.get("bot_to_bot_chance", 0))
    if any(b["card"] for b in roster["bots"]):
        want["AiPlayerbot.LLMDefaultPromptsFile"] = cards_in_server
    return {k: v for k, v in want.items() if conf_get(conf_text, k) != v}


def cards_text(roster):
    lines = ["# Written by teldrassil from the roster: Name::card. Edit the roster, not this file."]
    lines += [f"{b['name']}::{b['card']}" for b in roster["bots"] if b["card"]]
    return "\n".join(lines) + "\n"


STATE_SQL = """SELECT JSON_OBJECT(
 'characters', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', c.guid, 'name', c.name, 'race', c.race,
     'class', c.class, 'gender', c.gender, 'level', c.level, 'online', c.online,
     'bot', a.username LIKE '{prefix}%'))
   FROM {chars}.characters c LEFT JOIN {realmd}.account a ON a.id = c.account),
 'skills', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', bot, 'event', event, 'value', value))
   FROM {chars}.ai_playerbot_random_bots WHERE owner = 0 AND event IN ('firstSkill', 'secondSkill')),
 'store', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', guid, 'key', `key`, 'value', value))
   FROM {chars}.ai_playerbot_db_store WHERE preset = ''),
 'guilds', (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', guildid, 'name', name, 'leader', leaderguid,
     'EmblemStyle', EmblemStyle, 'EmblemColor', EmblemColor, 'BorderStyle', BorderStyle,
     'BorderColor', BorderColor, 'BackgroundColor', BackgroundColor, 'info', info, 'motd', motd))
   FROM {chars}.guild),
 'ranks', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guild', guildid, 'rid', rid, 'name', rname, 'rights', rights))
   FROM {chars}.guild_rank),
 'members', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guild', guildid, 'guid', guid, 'rank', `rank`,
     'pnote', pnote, 'offnote', offnote))
   FROM {chars}.guild_member)
);"""


# JSON_ARRAYAGG is cut off at group_concat_max_len (1 MB by default) - silently,
# mid-string. A large population's state, and the help texts, are bigger.
LONG_JSON = "SET SESSION group_concat_max_len = 268435456;"


def state_sql(chars, realmd, prefix):
    return LONG_JSON + " " + STATE_SQL.format(chars=chars, realmd=realmd, prefix=prefix).replace("\n", " ")


def normalise_state(raw):
    st = {k: (raw.get(k) or []) for k in ("characters", "skills", "store", "guilds", "ranks", "members")}
    for c in st["characters"]:
        c["bot"] = bool(c["bot"])
    return st


def plan(roster, state, now=None):
    """What applying the roster would change.

    Returns (lines, sql, upgrade): human-readable lines, the SQL statements
    (empty when nothing changes), and the bots whose professions changed and
    need 'rndbot upgrade' after the server starts."""
    now = int(now if now is not None else time.time())
    lines, sql, upgrade = [], [], []
    chars = state["characters"]
    by_name = {c["name"]: c for c in chars}
    guilds_by_name = {g["name"].lower(): g for g in state["guilds"]}
    leaders = {g["leader"] for g in state["guilds"]}
    member_of = {m["guid"]: m for m in state["members"]}
    skills = {}
    for s in state["skills"]:
        skills.setdefault(s["guid"], {})[s["event"]] = int(s["value"])
    store = {}
    for s in state["store"]:
        store.setdefault(s["guid"], []).append((s["key"], s["value"]))
    roster_names = {b["name"] for b in roster["bots"]}
    taken = set()
    errors = []
    failed = set()

    # 1. Bind each roster bot to a character: its name if it exists, else a
    #    free random bot of the same race and class (not rostered, in no
    #    guild, leading none).
    bound = {}
    for b in roster["bots"]:
        c = by_name.get(b["name"])
        if c is not None:
            if not c["bot"]:
                errors.append(f"{b['name']}: that name belongs to a player's character, not a bot")
                failed.add(b["name"])
                continue
            if (c["race"], c["class"]) != (b["race"], b["class"]):
                errors.append(f"{b['name']}: exists as race {c['race']} class {c['class']}, not as the roster says; "
                              "rename it away or change the roster")
                failed.add(b["name"])
                continue
            bound[b["name"]] = c
            taken.add(c["guid"])
    for b in roster["bots"]:
        if b["name"] in bound or b["name"] in failed:
            continue
        free = [c for c in chars
                if c["bot"] and c["guid"] not in taken and c["name"] not in roster_names
                and (c["race"], c["class"]) == (b["race"], b["class"])
                and c["guid"] not in member_of and c["guid"] not in leaders]
        if not free:
            errors.append(f"{b['name']}: no free bot of race {b['race']} class {b['class']} to take over; "
                          "apply with --fresh-population, or raise that pair's count")
            continue
        c = min(free, key=lambda x: (x["level"], x["guid"]))
        taken.add(c["guid"])
        bound[b["name"]] = dict(c)
        lines.append(f"rename {c['name']} (guid {c['guid']}) to {b['name']}")
        sql.append(f"UPDATE characters SET name={sql_str(b['name'])} WHERE guid={c['guid']};")
    if errors:
        raise RosterError("\n".join(errors))

    # 2. Per bot: gender, professions, strategies, guild size, card row.
    for b in roster["bots"]:
        c = bound[b["name"]]
        g = c["guid"]
        n = b["name"]
        if c["gender"] != b["gender"]:
            lines.append(f"{n}: gender to {'female' if b['gender'] else 'male'} (appearance reset to the race's first options)")
            sql.append(f"UPDATE characters SET gender={b['gender']}, playerBytes=0, playerBytes2=playerBytes2 & ~255 WHERE guid={g};")
        if b["professions"]:
            have = skills.get(g, {})
            want = {"firstSkill": b["professions"][0], "secondSkill": b["professions"][1]}
            if any(have.get(k) != v for k, v in want.items()):
                lines.append(f"{n}: professions {want['firstSkill']}, {want['secondSkill']} (applied by 'rndbot upgrade')")
                for k, v in want.items():
                    sql.append(f"DELETE FROM ai_playerbot_random_bots WHERE owner=0 AND bot={g} AND event='{k}';")
                    sql.append("INSERT INTO ai_playerbot_random_bots (owner,bot,`time`,validIn,event,`value`) "
                               f"VALUES (0,{g},{now},{10 * 365 * 24 * 3600},'{k}',{v});")
                upgrade.append(n)
        rows = store.get(g, [])
        full = [k for k, _ in rows if k in ("co", "nc", "dead", "react")]
        if full:
            lines.append(f"{n}: WARNING has full strategy lists ({', '.join(full)}), which replace its defaults; "
                         "they are left alone")
        nc, co = strategies_for(b["priorities"])
        for key, strat in (("nc+", nc), ("co+", co)):
            value = ",".join("+" + s for s in strat)
            have = [v for k, v in rows if k == key]
            if (have != [value]) if value else have:
                lines.append(f"{n}: {key} {value or '(none)'}")
                sql.append(f"DELETE FROM ai_playerbot_db_store WHERE guid={g} AND preset='' AND `key`='{key}';")
                if value:
                    sql.append(f"INSERT INTO ai_playerbot_db_store (guid,preset,`key`,`value`) VALUES ({g},'','{key}',{sql_str(value)});")
        have = [v for k, v in rows if k == "value" and v.startswith(GUILDER_PREFIX)]
        want = [f"{GUILDER_PREFIX}{b['guild_size']}"] if b["guild_size"] is not None else []
        if have != want:
            lines.append(f"{n}: guild size override {b['guild_size'] if want else '(none)'}")
            sql.append(f"DELETE FROM ai_playerbot_db_store WHERE guid={g} AND preset='' AND `key`='value' "
                       f"AND `value` LIKE {sql_str(GUILDER_PREFIX + '%')};")
            if want:
                sql.append(f"INSERT INTO ai_playerbot_db_store (guid,preset,`key`,`value`) VALUES ({g},'','value',{sql_str(want[0])});")
        if not b["card"] and any(k == "value" and v.startswith(CARD_PREFIX) for k, v in rows):
            lines.append(f"{n}: remove its old card")
            sql.append(f"DELETE FROM ai_playerbot_db_store WHERE guid={g} AND `key`='value' AND `value` LIKE {sql_str(CARD_PREFIX + '%')};")

    # 3. Guilds: create or update, ranks, members.
    next_id = max([gd["id"] for gd in state["guilds"]] + [0]) + 1
    for gd in roster["guilds"]:
        cur = guilds_by_name.get(gd["name"].lower())
        leader = bound[gd["leader"]]["guid"]
        tab = gd["tabard"] or {k: 0 for k, _ in TABARD_FIELDS}
        if cur is None:
            gid = next_id
            next_id += 1
            lines.append(f"create guild {gd['name']} (id {gid}), led by {gd['leader']}")
            cols = ",".join(col for _, col in TABARD_FIELDS)
            vals = ",".join(str(tab[k]) for k, _ in TABARD_FIELDS)
            sql.append(f"INSERT INTO guild (guildid,name,leaderguid,{cols},info,motd,createdate) VALUES "
                       f"({gid},{sql_str(gd['name'])},{leader},{vals},{sql_str(gd['info'])},{sql_str(gd['motd'])},{now});")
            cur_ranks, cur_members = [], []
        else:
            gid = cur["id"]
            sets = []
            if cur["leader"] != leader:
                lines.append(f"{gd['name']}: leader to {gd['leader']}")
                sets.append(f"leaderguid={leader}")
            if gd["tabard"] and any(int(cur[col]) != tab[k] for k, col in TABARD_FIELDS):
                lines.append(f"{gd['name']}: tabard {', '.join(str(tab[k]) for k, _ in TABARD_FIELDS)}")
                sets += [f"{col}={tab[k]}" for k, col in TABARD_FIELDS]
            for field in ("info", "motd"):
                if gd[field] and cur.get(field) != gd[field]:
                    lines.append(f"{gd['name']}: {field} updated")
                    sets.append(f"{field}={sql_str(gd[field])}")
            if sets:
                sql.append(f"UPDATE guild SET {', '.join(sets)} WHERE guildid={gid};")
            cur_ranks = sorted((r for r in state["ranks"] if r["guild"] == gid), key=lambda r: r["rid"])
            cur_members = [m for m in state["members"] if m["guild"] == gid]

        want_ranks = [(i, name, RIGHTS_OFFICER if i < gd["officers"] else RIGHTS_MEMBER)
                      for i, name in enumerate(gd["ranks"])]
        if [(r["rid"], r["name"], int(r["rights"])) for r in cur_ranks] != want_ranks:
            lines.append(f"{gd['name']}: ranks {', '.join(gd['ranks'])}")
            sql.append(f"DELETE FROM guild_rank WHERE guildid={gid};")
            for rid, name, rights in want_ranks:
                sql.append(f"INSERT INTO guild_rank (guildid,rid,rname,rights) VALUES ({gid},{rid},{sql_str(name)},{rights});")
            lowest = len(gd["ranks"]) - 1
            if any(m["rank"] > lowest for m in cur_members):
                sql.append(f"UPDATE guild_member SET `rank`={lowest} WHERE guildid={gid} AND `rank`>{lowest};")

        rank_index = {name: i for i, name in enumerate(gd["ranks"])}
        default_rank = len(gd["ranks"]) - 1
        roster_guids = set()
        for b in roster["bots"]:
            if b["guild"] != gd["name"]:
                continue
            g = bound[b["name"]]["guid"]
            roster_guids.add(g)
            rank = 0 if b["name"] == gd["leader"] else rank_index.get(b["rank"], None)
            m = member_of.get(g)
            if rank is None:
                rank = m["rank"] if m and m["guild"] == gid and 0 < m["rank"] <= default_rank else default_rank
            offnote = f"Farm: {b['farm']}" if b["farm"] else ""
            if m and m["guild"] == gid:
                sets = []
                if m["rank"] != rank:
                    sets.append(f"`rank`={rank}")
                if (m.get("offnote") or "") != offnote:
                    sets.append(f"offnote={sql_str(offnote)}")
                if b["note"] and (m.get("pnote") or "") != b["note"]:
                    sets.append(f"pnote={sql_str(b['note'])}")
                if sets:
                    lines.append(f"{gd['name']}: {b['name']} {', '.join(sets).replace('`', '')}")
                    sql.append(f"UPDATE guild_member SET {', '.join(sets)} WHERE guildid={gid} AND guid={g};")
            else:
                if m:
                    lines.append(f"{b['name']}: leaves guild id {m['guild']}")
                lines.append(f"{gd['name']}: {b['name']} joins as {gd['ranks'][rank]}")
                sql.append(f"DELETE FROM guild_member WHERE guid={g};")
                sql.append(f"INSERT INTO guild_member (guildid,guid,`rank`,pnote,offnote) VALUES "
                           f"({gid},{g},{rank},{sql_str(b['note'])},{sql_str(offnote)});")
        # Members the roster does not name keep their place - except the top
        # rank, which belongs to the leader alone.
        for m in cur_members:
            if m["guid"] not in roster_guids and m["rank"] == 0:
                lines.append(f"{gd['name']}: guid {m['guid']} steps down from the top rank")
                sql.append(f"UPDATE guild_member SET `rank`=1 WHERE guildid={gid} AND guid={m['guid']};")

    # Bots the roster takes out of every guild.
    for b in roster["bots"]:
        g = bound[b["name"]]["guid"]
        if b["guild"] is None and g in member_of:
            if g in leaders:
                raise RosterError(f"{b['name']}: leads a guild the roster does not name; give it a guild or a new leader")
            lines.append(f"{b['name']}: leaves guild id {member_of[g]['guild']}")
            sql.append(f"DELETE FROM guild_member WHERE guid={g};")

    return lines, sql, upgrade


# ----------------------------------------------------------------------------
# Command line
# ----------------------------------------------------------------------------

def _read_roster(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"cannot read roster {path}: {e}")
    try:
        return load_roster(data)
    except RosterError as e:
        raise SystemExit("roster problems:\n  " + str(e).replace("\n", "\n  "))


def cmd_check(a):
    r = _read_roster(a.roster)
    for side in ("alliance", "horde"):
        n = sum(1 for b in r["bots"] if faction_of(b["race"]) == side)
        print(f"{side}: {n} bots")
    for g in r["guilds"]:
        n = sum(1 for b in r["bots"] if b["guild"] == g["name"])
        print(f"guild {g['name']} ({g['faction']}): {n} members, led by {g['leader']}")
    if r["population"]:
        print(f"population: {r['population']['bots']} bots, 50/50")
    print(f"cards: {sum(1 for b in r['bots'] if b['card'])}")
    with open(a.roster, encoding="utf-8") as f:
        rules = load_attunements(json.load(f))
    print("attunements: " + ", ".join(f"{x['name']} at {x['level']}" + (" + reputation" if x["faction"] else "") for x in rules))


def cmd_plan(a):
    r = _read_roster(a.roster)
    with open(a.state, encoding="utf-8") as f:
        raw = f.read().strip()
    state = normalise_state(json.loads(raw) if raw else {})
    with open(a.conf, encoding="utf-8") as f:
        conf_text = f.read()
    try:
        lines, sql, upgrade = plan(r, state)
        changes = conf_changes(r, conf_text, a.cards_in_server)
    except RosterError as e:
        raise SystemExit("cannot plan:\n  " + str(e).replace("\n", "\n  "))
    new_cards = cards_text(r)
    try:
        with open(a.cards, encoding="utf-8") as f:
            old_cards = f.read()
    except OSError:
        old_cards = None
    for k, v in changes.items():
        shown = v if len(v) < 90 else v[:87] + "..."
        lines.append(f"aiplayerbot.conf: {k} = {shown}")
    if any(b["card"] for b in r["bots"]) and old_cards != new_cards:
        lines.append(f"card file: {sum(1 for b in r['bots'] if b['card'])} cards")
    for line in lines:
        print(line)
    if not lines:
        print("nothing to change")
    if a.out_sql:
        with open(a.out_sql, "w", encoding="utf-8") as f:
            if sql:
                f.write("START TRANSACTION;\n" + "\n".join(sql) + "\nCOMMIT;\n")
    if a.out_conf:
        new = conf_text
        for k, v in changes.items():
            new = conf_set(new, k, v)
        with open(a.out_conf, "w", encoding="utf-8") as f:
            f.write(new if changes else "")
    if a.out_cards:
        with open(a.out_cards, "w", encoding="utf-8") as f:
            f.write(new_cards if any(b["card"] for b in r["bots"]) and old_cards != new_cards else "")
    if a.out_upgrade:
        with open(a.out_upgrade, "w", encoding="utf-8") as f:
            f.write("".join(n + "\n" for n in upgrade))


def cmd_show(a):
    r = _read_roster(a.roster)
    with open(a.state, encoding="utf-8") as f:
        raw = f.read().strip()
    st = normalise_state(json.loads(raw) if raw else {})
    by_name = {c["name"]: c for c in st["characters"]}
    member = {m["guid"]: m for m in st["members"]}
    gname = {g["id"]: g["name"] for g in st["guilds"]}
    rname = {(x["guild"], x["rid"]): x["name"] for x in st["ranks"]}
    print(f"{'name':<13} {'lvl':>3} {'on':<3} {'guild':<26} rank")
    for b in r["bots"]:
        c = by_name.get(b["name"])
        if not c:
            print(f"{b['name']:<13} {'-':>3} {'-':<3} (not created yet)")
            continue
        m = member.get(c["guid"])
        guild = gname.get(m["guild"], "?") if m else "(none)"
        rank = rname.get((m["guild"], m["rank"]), str(m["rank"])) if m else ""
        flag = "  <- roster says " + b["guild"] if b["guild"] and guild != b["guild"] else ""
        print(f"{b['name']:<13} {c['level']:>3} {'yes' if c['online'] else 'no':<3} {guild:<26} {rank}{flag}")


def cmd_srp6(a):
    password = sys.stdin.readline().rstrip("\n")
    if not password:
        raise SystemExit("no password on stdin")
    v, s = srp6_verifier(a.user, password)
    print(v, s)


def cmd_ra(a):
    password = read_secret(a.pass_file)
    user = a.user or read_user(a.pass_file)
    if not user:
        raise SystemExit("no console user: set RA_USER, or put an 'account:' line in the password file")
    for cmd, out in ra_send(a.host, a.port, user, password, a.command, a.wait):
        if a.quiet:
            print(out)
        else:
            print(f"> {cmd}\n{out}")


def chat_commands(chat_help):
    """The chat commands, from the help text of the 'chat' strategy."""
    return sorted(set(re.findall(r"\[h:trigger\|([^\]|]+)\]", chat_help)))


def cmd_commands(a):
    with open(a.help, encoding="utf-8") as f:
        raw = f.read().strip()
    texts = dict(json.loads(raw)) if raw else {}
    cmds = chat_commands(texts.get("strategy:chat", ""))
    if not cmds:
        raise SystemExit("no chat commands found in the help texts (is the world database loaded?)")
    for c in cmds:
        who = "anyone" if c in ANY_PLAYER_COMMANDS else "master"
        if a.any and who != "anyone":
            continue
        if a.search and a.search.lower() not in c.lower():
            continue
        line = f"{c:<28} {who}"
        if a.verbose:
            text = texts.get(f"action:{c}") or texts.get(f"trigger:{c}") or ""
            first = text.split("\n", 1)[0].strip()
            line += f"   {first}" if first else ""
        print(line)


# ----------------------------------------------------------------------------
# Attunements: grant raid entry to bots by rule
# ----------------------------------------------------------------------------

# Factions an attunement rule may name, and the standing each rank starts at.
# character_reputation keeps the standing EARNED; these factions start everyone
# at 0 (neutral), so the thresholds compare with it directly.
FACTIONS = {"argent dawn": 529, "brood of nozdormu": 910, "cenarion circle": 609,
            "hydraxian waterlords": 749, "zandalar tribe": 270, "timbermaw hold": 576}
STANDINGS = {"neutral": 0, "friendly": 3000, "honored": 9000, "revered": 21000, "exalted": 42000}

# The raids whose entrance checks a completed quest (areatrigger_teleport.
# required_quest_done in classic-db): what a bot needs to follow players in.
# Each rule asks for what bots CAN earn - level, and for Naxxramas the
# reputation - and waives what they cannot, the dungeon steps.
DEFAULT_ATTUNEMENTS = [
    {"name": "Molten Core", "quest": 7848, "level": 58},
    {"name": "Blackwing Lair", "quest": 7761, "level": 60},
    {"name": "Naxxramas", "quest": 9378, "level": 60, "reputation": {"faction": "argent dawn", "at_least": "honored"}},
]


def load_attunements(data):
    """The roster's 'attunements' rules (or the defaults), validated."""
    rules = data.get("attunements", DEFAULT_ATTUNEMENTS)
    out, errors = [], []
    for i, r in enumerate(rules):
        where = f"attunements[{i}]"
        try:
            rule = {"name": str(r.get("name") or f"quest {r['quest']}"), "quest": int(r["quest"]),
                    "level": int(r.get("level", 60)), "faction": None, "standing": 0}
            if not 1 <= rule["level"] <= 60:
                raise RosterError(f"{where}: level is 1-60")
            rep = r.get("reputation")
            if rep:
                f = rep["faction"]
                rule["faction"] = int(f) if str(f).isdigit() else _lookup(FACTIONS, f, "faction", where)
                a = rep["at_least"]
                rule["standing"] = int(a) if str(a).lstrip("-").isdigit() else _lookup(STANDINGS, a, "standing", where)
            out.append(rule)
        except (RosterError, KeyError, ValueError, TypeError) as e:
            errors.append(str(e) if isinstance(e, RosterError) else f"{where}: missing {e}")
    if errors:
        raise RosterError("\n".join(errors))
    return out


ATTUNE_SQL = """SELECT JSON_OBJECT(
 'bots', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', c.guid, 'name', c.name, 'level', c.level))
   FROM {chars}.characters c JOIN {realmd}.account a ON a.id = c.account WHERE a.username LIKE '{prefix}%'),
 'rewarded', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', guid, 'quest', quest))
   FROM {chars}.character_queststatus WHERE rewarded = 1 AND quest IN ({quests})),
 'reputation', (SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', guid, 'faction', faction, 'standing', standing))
   FROM {chars}.character_reputation WHERE faction IN ({factions}))
);"""


def attune_sql(chars, realmd, prefix, rules):
    quests = ",".join(str(r["quest"]) for r in rules) or "0"
    factions = ",".join(sorted({str(r["faction"]) for r in rules if r["faction"]})) or "0"
    return LONG_JSON + " " + ATTUNE_SQL.format(chars=chars, realmd=realmd, prefix=prefix,
                                               quests=quests, factions=factions).replace("\n", " ")


def plan_attunements(rules, state):
    """(per-rule summary lines, SQL): which bots meet a rule and lack its quest."""
    have = {(r["guid"], r["quest"]) for r in state.get("rewarded") or []}
    rep = {(r["guid"], r["faction"]): int(r["standing"]) for r in state.get("reputation") or []}
    lines, sql = [], []
    for rule in rules:
        granted, already, short = [], 0, 0
        for b in state.get("bots") or []:
            if (b["guid"], rule["quest"]) in have:
                already += 1
                continue
            if b["level"] < rule["level"]:
                continue
            if rule["faction"] and rep.get((b["guid"], rule["faction"]), 0) < rule["standing"]:
                short += 1
                continue
            granted.append(b)
        need = f"level {rule['level']}" + (f", standing {rule['standing']} with faction {rule['faction']}" if rule["faction"] else "")
        lines.append(f"{rule['name']} (quest {rule['quest']}; {need}): grant {len(granted)}, "
                     f"already {already}" + (f", {short} at the level but short of the reputation" if rule["faction"] else ""))
        for b in sorted(granted, key=lambda x: x["name"]):
            sql.append(f"INSERT INTO character_queststatus (guid, quest, status, rewarded) VALUES "
                       f"({b['guid']}, {rule['quest']}, 1, 1) ON DUPLICATE KEY UPDATE status = 1, rewarded = 1;")
    return lines, sql


def _read_rules(path):
    data = {}
    if path:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise SystemExit(f"cannot read roster {path}: {e}")
    try:
        return load_attunements(data)
    except RosterError as e:
        raise SystemExit("attunement rules:\n  " + str(e).replace("\n", "\n  "))


def cmd_attune_sql(a):
    print(attune_sql(a.chars, a.realmd, a.prefix, _read_rules(a.roster)))


def cmd_attune_plan(a):
    rules = _read_rules(a.roster)
    with open(a.state, encoding="utf-8") as f:
        raw = f.read().strip()
    lines, sql = plan_attunements(rules, json.loads(raw) if raw and raw != "NULL" else {})
    for line in lines:
        print(line)
    if a.out_sql:
        with open(a.out_sql, "w", encoding="utf-8") as f:
            if sql:
                f.write("START TRANSACTION;\n" + "\n".join(sql) + "\nCOMMIT;\n")


# ----------------------------------------------------------------------------
# Search: characters and bots
# ----------------------------------------------------------------------------

RACE_NAMES = {v: k for k, v in RACES.items()}
CLASS_NAMES = {v: k for k, v in CLASSES.items()}


def area_names(dbc_dir):
    """{area id: name} from the client's AreaTable.dbc (1.12.1: id in field 0,
    the English name's string offset in field 11). Empty without the file."""
    import os
    import struct
    path = os.path.join(dbc_dir or "", "AreaTable.dbc")
    try:
        with open(path, "rb") as f:
            b = f.read()
    except OSError:
        return {}
    magic, nrec, nfield, rsize, ssize = struct.unpack("<4s4I", b[:20])
    if magic != b"WDBC" or nfield < 12:
        return {}
    strings = b[20 + nrec * rsize:]
    names = {}
    for i in range(nrec):
        rec = struct.unpack_from(f"<{nfield}I", b, 20 + i * rsize)
        off = rec[11]
        if off < ssize:
            end = strings.find(b"\0", off)
            names[rec[0]] = strings[off:end].decode("utf-8", "replace")
    return names


def _level_range(text):
    m = re.fullmatch(r"(\d+)(?:-(\d+))?", str(text).strip())
    if not m:
        raise SystemExit(f"--level wants N or MIN-MAX, got '{text}'")
    lo = int(m.group(1))
    return lo, int(m.group(2) or lo)


def filter_characters(rows, zones, term=None, zone=None, cls=None, race=None, level=None,
                      guild=None, online=False, kind="all", roster_names=None, roster_only=None):
    """The characters that match every filter given."""
    out = []
    zone_ids = None
    if zone:
        z = zone.lower()
        zone_ids = {i for i, n in zones.items() if z in n.lower()}
        if zone.isdigit():
            zone_ids.add(int(zone))
    cls_id = _lookup(CLASSES, cls, "class", "--class") if cls else None
    race_id = _lookup(RACES, race, "race", "--race") if race else None
    lo_hi = _level_range(level) if level else None
    for c in rows:
        if term and term.lower() not in c["name"].lower():
            continue
        if kind == "bot" and not c["bot"] or kind == "player" and c["bot"]:
            continue
        if zone_ids is not None and c["zone"] not in zone_ids:
            continue
        if cls_id and c["class"] != cls_id or race_id and c["race"] != race_id:
            continue
        if lo_hi and not lo_hi[0] <= c["level"] <= lo_hi[1]:
            continue
        if guild and guild.lower() not in (c.get("guild") or "").lower():
            continue
        if online and not c["online"]:
            continue
        if roster_only is True and c["name"] not in roster_names:
            continue
        if roster_only is False and c["name"] in roster_names:
            continue
        out.append(c)
    return sorted(out, key=lambda c: (c["name"]))


def cmd_chars(a):
    with open(a.rows, encoding="utf-8") as f:
        raw = f.read().strip()
    rows = json.loads(raw) if raw and raw != "NULL" else []
    rows = rows or []
    for c in rows:
        c["bot"] = bool(c["bot"])
    zones = area_names(a.dbc)
    names = set()
    if a.roster:
        names = {b["name"] for b in _read_roster(a.roster)["bots"]}
    roster_only = True if a.roster_only else False if a.random_only else None
    if roster_only is not None and not a.roster:
        raise SystemExit("--roster-only and --random-only need a roster (--file, or ROSTER_FILE)")
    found = filter_characters(rows, zones, a.term, a.zone, a.cls, a.race, a.level, a.guild,
                              a.online, a.kind, names, roster_only)
    shown = found[:a.limit]
    print(f"{'name':<13} {'kind':<7} {'lvl':>3} {'race/class':<17} {'on':<3} {'zone':<22} guild")
    for c in shown:
        kind = ("roster" if c["name"] in names else "bot") if c["bot"] else "player"
        rc = f"{RACE_NAMES.get(c['race'], c['race'])} {CLASS_NAMES.get(c['class'], c['class'])}"
        zone = zones.get(c["zone"], str(c["zone"]))
        guild = c.get("guild") or ""
        if guild and c.get("rank"):
            guild += f" ({c['rank']})"
        print(f"{c['name']:<13} {kind:<7} {c['level']:>3} {rc:<17} {'yes' if c['online'] else 'no':<3} {zone[:22]:<22} {guild}")
    more = len(found) - len(shown)
    print(f"\n{len(found)} found" + (f", {more} not shown (raise --limit)" if more > 0 else ""))


def cmd_names(a):
    for b in _read_roster(a.roster)["bots"]:
        print(b["name"])


def cmd_conf(a):
    """Write the roster's aiplayerbot.conf settings (and any KEY=VALUE given)
    to --out, without reading the database. For a fresh population, whose
    counts must be in place before the bots are created."""
    with open(a.conf, encoding="utf-8") as f:
        text = f.read()
    changes = {}
    if a.roster:
        try:
            changes = conf_changes(_read_roster(a.roster), text, a.cards_in_server)
        except RosterError as e:
            raise SystemExit(str(e))
    for kv in a.set:
        k, sep, v = kv.partition("=")
        if not sep or not k.strip():
            raise SystemExit(f"--set wants KEY=VALUE, got '{kv}'")
        if conf_get(text, k.strip()) != v.strip():
            changes[k.strip()] = v.strip()
    for k, v in changes.items():
        text = conf_set(text, k, v)
        print(f"{k} = {v if len(v) < 90 else v[:87] + '...'}")
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)


def main(argv=None):
    p = argparse.ArgumentParser(prog="teldrassil.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ra")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=3443)
    s.add_argument("--user", default="")
    s.add_argument("--pass-file", required=True)
    s.add_argument("--wait", type=float, default=1.5)
    s.add_argument("--quiet", action="store_true")
    s.add_argument("command", nargs="+")
    s.set_defaults(fn=cmd_ra)

    s = sub.add_parser("srp6")
    s.add_argument("--user", required=True)
    s.set_defaults(fn=cmd_srp6)

    s = sub.add_parser("state-sql")
    s.add_argument("--chars", required=True)
    s.add_argument("--realmd", required=True)
    s.add_argument("--prefix", default="RNDBOT")
    s.set_defaults(fn=lambda a: print(state_sql(a.chars, a.realmd, a.prefix)))

    s = sub.add_parser("check")
    s.add_argument("roster")
    s.set_defaults(fn=cmd_check)

    s = sub.add_parser("plan")
    s.add_argument("roster")
    s.add_argument("--state", required=True)
    s.add_argument("--conf", required=True)
    s.add_argument("--cards", required=True, help="the card file as it is now (host path)")
    s.add_argument("--cards-in-server", required=True, help="the card file's path inside the server")
    s.add_argument("--out-sql")
    s.add_argument("--out-conf")
    s.add_argument("--out-cards")
    s.add_argument("--out-upgrade")
    s.set_defaults(fn=cmd_plan)

    s = sub.add_parser("show")
    s.add_argument("roster")
    s.add_argument("--state", required=True)
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("attune-sql")
    s.add_argument("--roster")
    s.add_argument("--chars", required=True)
    s.add_argument("--realmd", required=True)
    s.add_argument("--prefix", default="RNDBOT")
    s.set_defaults(fn=cmd_attune_sql)

    s = sub.add_parser("attune-plan")
    s.add_argument("--roster")
    s.add_argument("--state", required=True)
    s.add_argument("--out-sql")
    s.set_defaults(fn=cmd_attune_plan)

    s = sub.add_parser("chars")
    s.add_argument("--rows", required=True)
    s.add_argument("--dbc", default="")
    s.add_argument("--roster")
    s.add_argument("--term")
    s.add_argument("--zone")
    s.add_argument("--class", dest="cls")
    s.add_argument("--race")
    s.add_argument("--level")
    s.add_argument("--guild")
    s.add_argument("--online", action="store_true")
    s.add_argument("--kind", choices=["all", "bot", "player"], default="all")
    s.add_argument("--roster-only", action="store_true")
    s.add_argument("--random-only", action="store_true")
    s.add_argument("--limit", type=int, default=50)
    s.set_defaults(fn=cmd_chars)

    s = sub.add_parser("names")
    s.add_argument("roster")
    s.set_defaults(fn=cmd_names)

    s = sub.add_parser("conf")
    s.add_argument("--conf", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--roster")
    s.add_argument("--cards-in-server", default="")
    s.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    s.set_defaults(fn=cmd_conf)

    s = sub.add_parser("commands")
    s.add_argument("--help-json", dest="help", required=True)
    s.add_argument("--any", action="store_true")
    s.add_argument("--search")
    s.add_argument("--verbose", action="store_true")
    s.set_defaults(fn=cmd_commands)

    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
