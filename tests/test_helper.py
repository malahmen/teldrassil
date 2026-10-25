"""Unit tests for lib/teldrassil.py: the roster, the plan, SRP6, the conf
editor. No server, no database: the plan runs over hand-built state."""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import teldrassil as t  # noqa: E402


def roster(**over):
    data = {
        "guilds": [{"name": "Test Guild", "faction": "horde", "leader": "Leadra",
                    "ranks": ["Boss", "Deputy", "Sergeant", "Member", "Recruit"],
                    "tabard": {"symbol": 1, "symbol_color": 2, "border": 3, "border_color": 4, "background": 5}}],
        "bots": [
            {"name": "Leadra", "race": "undead", "class": "priest", "gender": "female",
             "professions": ["tailoring", "enchanting"], "priorities": ["quests", "gather"],
             "guild": "Test Guild", "card": "You are a test."},
            {"name": "Grunt", "race": "orc", "class": "warrior", "professions": ["mining", "blacksmithing"],
             "priorities": ["gather", "wpvp"], "guild": "Test Guild", "rank": "Deputy", "farm": "Copper Ore 40"},
        ],
    }
    data.update(over)
    return data


def char(guid, name, race, cls, gender=0, level=1, bot=True, online=1):
    return {"guid": guid, "name": name, "race": race, "class": cls, "gender": gender,
            "level": level, "bot": bot, "online": online}


def empty_state():
    return t.normalise_state({"characters": [
        char(10, "Randoma", 5, 5, gender=0, level=3),
        char(11, "Randomb", 2, 1),
        char(12, "Randomc", 2, 1, level=5),
        char(20, "Playerone", 8, 3, bot=False),
    ]})


def apply_plan_to_state(rost, state):
    """What the database would hold after the plan, for the idempotence test:
    re-derived from the roster rather than by executing SQL."""
    r = t.load_roster(rost)
    lines, sql, _ = t.plan(r, state, now=1)
    st = copy.deepcopy(state)
    # Renames, in the order the plan made them.
    for line in lines:
        if line.startswith("rename "):
            old = line.split()[1]
            new = line.split()[-1]
            next(c for c in st["characters"] if c["name"] == old)["name"] = new
    by_name = {c["name"]: c for c in st["characters"]}
    st["skills"], st["store"], st["members"] = [], [], []
    gid = 1
    st["guilds"] = [{"id": gid, "name": r["guilds"][0]["name"], "leader": by_name["Leadra"]["guid"],
                     **{col: r["guilds"][0]["tabard"][k] for k, col in t.TABARD_FIELDS}, "info": "", "motd": ""}]
    st["ranks"] = [{"guild": gid, "rid": i, "name": n, "rights": t.RIGHTS_OFFICER if i < 2 else t.RIGHTS_MEMBER}
                   for i, n in enumerate(r["guilds"][0]["ranks"])]
    for b in r["bots"]:
        c = by_name[b["name"]]
        c["gender"] = b["gender"]
        st["skills"] += [{"guid": c["guid"], "event": "firstSkill", "value": b["professions"][0]},
                         {"guid": c["guid"], "event": "secondSkill", "value": b["professions"][1]}]
        nc, co = t.strategies_for(b["priorities"])
        st["store"].append({"guid": c["guid"], "key": "nc+", "value": ",".join("+" + s for s in nc)})
        if co:
            st["store"].append({"guid": c["guid"], "key": "co+", "value": ",".join("+" + s for s in co)})
        st["store"].append({"guid": c["guid"], "key": "value", "value": t.GUILDER_PREFIX + "70"})
        rank = 0 if b["name"] == "Leadra" else r["guilds"][0]["ranks"].index(b["rank"]) if b["rank"] else len(r["guilds"][0]["ranks"]) - 1
        st["members"].append({"guild": gid, "guid": c["guid"], "rank": rank, "pnote": "",
                              "offnote": f"Farm: {b['farm']}" if b["farm"] else ""})
    return st


class LoadRoster(unittest.TestCase):
    def test_valid(self):
        r = t.load_roster(roster())
        self.assertEqual(r["bots"][0]["race"], 5)
        self.assertEqual(r["bots"][0]["gender"], 1)
        self.assertEqual(r["bots"][1]["professions"], [186, 164])
        self.assertEqual(r["bots"][0]["guild_size"], 70)   # medium, by default in a guild

    def test_every_problem_is_reported(self):
        bad = roster()
        bad["bots"][0]["class"] = "paladin"        # undead paladin: not in 1.12.1
        bad["bots"][1]["professions"] = ["mining"]  # one profession
        with self.assertRaises(t.RosterError) as e:
            t.load_roster(bad)
        msg = str(e.exception)
        self.assertIn("cannot be a paladin", msg)
        self.assertIn("two professions", msg)

    def test_faction_and_rank_checks(self):
        bad = roster()
        bad["bots"][1]["race"] = "human"
        with self.assertRaises(t.RosterError) as e:
            t.load_roster(bad)
        self.assertIn("alliance bot cannot join horde", str(e.exception))
        bad = roster()
        bad["bots"][1]["rank"] = "Nobody"
        with self.assertRaises(t.RosterError) as e:
            t.load_roster(bad)
        self.assertIn("not one of Test Guild's ranks", str(e.exception))

    def test_names(self):
        for name in ("lowercase", "A", "Toolongnameforwow", "Mc'Name"):
            bad = roster()
            bad["bots"][1]["name"] = name
            with self.assertRaises(t.RosterError, msg=name):
                t.load_roster(bad)

    def test_at_least_five_ranks(self):
        bad = roster()
        bad["guilds"][0]["ranks"] = ["Boss", "Deputy", "Member"]
        bad["bots"][1]["rank"] = "Deputy"
        with self.assertRaises(t.RosterError) as e:
            t.load_roster(bad)
        self.assertIn("5 to 10 ranks", str(e.exception))

    def test_leader_must_be_in_the_guild(self):
        bad = roster()
        bad["guilds"][0]["leader"] = "Grunt"
        bad["bots"][1]["rank"] = "Deputy"
        with self.assertRaises(t.RosterError) as e:
            t.load_roster(bad)
        self.assertIn("must hold the top rank", str(e.exception))

    def test_card_is_one_line(self):
        bad = roster()
        bad["bots"][0]["card"] = "two\nlines"
        with self.assertRaises(t.RosterError):
            t.load_roster(bad)


class Strategies(unittest.TestCase):
    def test_base_for_everyone(self):
        nc, co = t.strategies_for(["gather", "ah"])
        self.assertEqual(nc, ["gather", "reveal", "rpg vendor", "rpg quest", "quest"])
        self.assertEqual(co, [])

    def test_quests_first_takes_every_quest(self):
        nc, _ = t.strategies_for(["quests", "gather"])
        self.assertIn("accept all quests", nc)
        nc, _ = t.strategies_for(["gather", "quests"])
        self.assertNotIn("accept all quests", nc)

    def test_world_pvp_in_both_states(self):
        nc, co = t.strategies_for(["ah", "wpvp"])
        self.assertIn("pvp", nc)
        self.assertEqual(co, ["pvp"])


class Population(unittest.TestCase):
    def test_half_each_and_legal(self):
        r = t.load_roster(roster())
        counts = t.population_counts(r, 100)
        a = sum(n for (c, race), n in counts.items() if race in t.ALLIANCE)
        h = sum(n for (c, race), n in counts.items() if race in t.HORDE)
        self.assertEqual((a, h), (50, 50))
        for (c, race) in counts:
            self.assertIn(c, t.LEGAL[race])
        self.assertGreaterEqual(counts[(5, 5)], 1)   # the roster's undead priest

    def test_too_many_of_one_faction(self):
        r = t.load_roster(roster())
        with self.assertRaises(t.RosterError):
            t.population_counts(r, 2)


class Plan(unittest.TestCase):
    def test_claims_renames_and_shapes(self):
        r = t.load_roster(roster())
        lines, sql, upgrade = t.plan(r, empty_state(), now=1)
        text = "\n".join(lines)
        self.assertIn("rename Randoma (guid 10) to Leadra", text)
        # The lowest-level free orc warrior is taken.
        self.assertIn("rename Randomb (guid 11) to Grunt", text)
        self.assertIn("Leadra: gender to female", text)
        self.assertIn("create guild Test Guild", text)
        self.assertEqual(sorted(upgrade), ["Grunt", "Leadra"])
        joined = "\n".join(sql)
        self.assertIn("UPDATE characters SET name='Leadra' WHERE guid=10;", joined)
        self.assertIn("'nc+','+gather,+reveal,+rpg vendor,+rpg quest,+quest,+accept all quests'", joined)
        self.assertIn("'co+','+pvp'", joined)
        self.assertIn("'Farm: Copper Ore 40'", joined)
        self.assertIn("(1,10,0,", joined)   # the leader at the top rank
        self.assertIn("(1,11,1,", joined)   # Grunt as Deputy

    def test_takes_a_bot_out_of_a_random_guild_when_needed(self):
        st = empty_state()
        st["guilds"] = [{"id": 7, "name": "Random Bots", "leader": 99, "EmblemStyle": 0, "EmblemColor": 0,
                         "BorderStyle": 0, "BorderColor": 0, "BackgroundColor": 0, "info": "", "motd": ""}]
        st["members"] = [{"guild": 7, "guid": 10, "rank": 3, "pnote": "", "offnote": ""}]
        lines, sql, _ = t.plan(t.load_roster(roster()), st, now=1)
        text = "\n".join(lines)
        self.assertIn("rename Randoma (guid 10) to Leadra", text)
        self.assertIn("Leadra: leaves guild id 7", text)

    def test_prefers_a_guildless_bot(self):
        st = empty_state()
        st["guilds"] = [{"id": 7, "name": "Random Bots", "leader": 99, "EmblemStyle": 0, "EmblemColor": 0,
                         "BorderStyle": 0, "BorderColor": 0, "BackgroundColor": 0, "info": "", "motd": ""}]
        st["members"] = [{"guild": 7, "guid": 11, "rank": 3, "pnote": "", "offnote": ""}]
        lines, _, _ = t.plan(t.load_roster(roster()), st, now=1)
        self.assertIn("rename Randomc (guid 12) to Grunt", "\n".join(lines))   # 11 is in a guild; 12 is not

    def test_never_takes_from_a_roster_guild_or_a_leader(self):
        st = empty_state()
        st["guilds"] = [{"id": 7, "name": "Test Guild", "leader": 12, "EmblemStyle": 0, "EmblemColor": 0,
                         "BorderStyle": 0, "BorderColor": 0, "BackgroundColor": 0, "info": "", "motd": ""}]
        st["members"] = [{"guild": 7, "guid": 11, "rank": 3, "pnote": "", "offnote": ""},
                         {"guild": 7, "guid": 12, "rank": 0, "pnote": "", "offnote": ""}]
        with self.assertRaises(t.RosterError) as e:
            t.plan(t.load_roster(roster()), st, now=1)
        self.assertIn("Grunt: no free bot", str(e.exception))

    def test_never_touches_players(self):
        state = empty_state()
        rost = roster()
        rost["bots"][1]["name"] = "Playerone"
        rost["bots"][1].update(race="troll", **{"class": "hunter"})
        with self.assertRaises(t.RosterError) as e:
            t.plan(t.load_roster(rost), state, now=1)
        self.assertIn("belongs to a player's character", str(e.exception))

    def test_no_free_bot(self):
        state = t.normalise_state({"characters": [char(10, "Randoma", 5, 5)]})
        with self.assertRaises(t.RosterError) as e:
            t.plan(t.load_roster(roster()), state, now=1)
        self.assertIn("no free bot", str(e.exception))

    def test_idempotent(self):
        rost = roster()
        after = apply_plan_to_state(rost, empty_state())
        lines, sql, upgrade = t.plan(t.load_roster(rost), after, now=1)
        self.assertEqual((lines, sql, upgrade), ([], [], []))

    def test_unlisted_members_keep_their_place(self):
        rost = roster()
        after = apply_plan_to_state(rost, empty_state())
        after["characters"].append(char(30, "Stranger", 2, 1))
        after["members"].append({"guild": 1, "guid": 30, "rank": 2, "pnote": "", "offnote": ""})
        lines, sql, _ = t.plan(t.load_roster(rost), after, now=1)
        self.assertEqual(sql, [])

    def test_changed_ranks_are_rewritten(self):
        rost = roster()
        after = apply_plan_to_state(rost, empty_state())
        rost["guilds"][0]["ranks"] = ["Boss", "Deputy", "Sergeant", "Member", "Recruit", "Ensign"]
        lines, sql, _ = t.plan(t.load_roster(rost), after, now=1)
        joined = "\n".join(sql)
        self.assertIn("DELETE FROM guild_rank WHERE guildid=1;", joined)
        self.assertIn("'Ensign'", joined)

    def test_card_removed_deletes_its_row(self):
        rost = roster()
        after = apply_plan_to_state(rost, empty_state())
        leadra = next(c for c in after["characters"] if c["name"] == "Leadra")["guid"]
        after["store"].append({"guid": leadra, "key": "value", "value": t.CARD_PREFIX + "old"})
        del rost["bots"][0]["card"]
        lines, sql, _ = t.plan(t.load_roster(rost), after, now=1)
        self.assertTrue(any("llmdefaultprompt" in s and s.startswith("DELETE") for s in sql))

    def test_quotes_are_escaped(self):
        rost = roster()
        rost["bots"][0]["note"] = "O'Brien \\ test"
        _, sql, _ = t.plan(t.load_roster(rost), empty_state(), now=1)
        self.assertIn("'O\\'Brien \\\\ test'", "\n".join(sql))


class ConfAndCards(unittest.TestCase):
    def test_conf_set_uncomments_and_appends(self):
        text = "# AiPlayerbot.LLMEnabled = 0\nAiPlayerbot.MinRandomBots = 50\n"
        text = t.conf_set(text, "AiPlayerbot.LLMEnabled", "2")
        text = t.conf_set(text, "AiPlayerbot.MinRandomBots", "100")
        text = t.conf_set(text, "AiPlayerbot.New", "x")
        self.assertEqual(text, "AiPlayerbot.LLMEnabled = 2\nAiPlayerbot.MinRandomBots = 100\nAiPlayerbot.New = x\n")

    def test_conf_changes_only_what_differs(self):
        r = t.load_roster(roster(population={"bots": 100}, llm={"enabled": 2, "endpoint": "http://x/v1/chat/completions"}))
        changes = t.conf_changes(r, "AiPlayerbot.LLMEnabled = 2\n", "/install/etc/cards.txt")
        self.assertNotIn("AiPlayerbot.LLMEnabled", changes)
        self.assertEqual(changes["AiPlayerbot.LLMApiEndpoint"], "http://x/v1/chat/completions")
        self.assertEqual(changes["AiPlayerbot.ClassRace.UseFixedClassRaceCounts"], "1")
        self.assertEqual(changes["AiPlayerbot.LLMDefaultPromptsFile"], "/install/etc/cards.txt")

    def test_cards_file(self):
        text = t.cards_text(t.load_roster(roster()))
        self.assertIn("Leadra::You are a test.", text)
        self.assertNotIn("Grunt::", text)


class Misc(unittest.TestCase):
    def test_srp6_is_stable_and_case_blind(self):
        salt = int("F" * 64, 16)
        v1, s1 = t.srp6_verifier("Tester", "Secret", salt)
        v2, _ = t.srp6_verifier("TESTER", "SECRET", salt)
        self.assertEqual(v1, v2)
        self.assertEqual(s1, "F" * 64)
        self.assertNotEqual(v1, t.srp6_verifier("TESTER", "OTHER", salt)[0])
        self.assertLess(int(v1, 16), t.SRP_N)

    def test_srp6_random_salt_is_full_length(self):
        _, s = t.srp6_verifier("A", "B")
        self.assertEqual(len(s), 64)

    def test_chat_commands(self):
        text = "On: [h:trigger|guild invite] do [h:action|guild invite]\nOn: [h:trigger|who] do x"
        self.assertEqual(t.chat_commands(text), ["guild invite", "who"])

    def test_sql_str(self):
        self.assertEqual(t.sql_str("a'b\\c"), "'a\\'b\\\\c'")

    def test_secret_file(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("realm notes\naccount:  ME\npassword: hunter2\n")
        try:
            self.assertEqual(t.read_secret(f.name), "hunter2")
            self.assertEqual(t.read_user(f.name), "ME")
        finally:
            os.unlink(f.name)


class Search(unittest.TestCase):
    ROWS = [
        {"guid": 1, "name": "Bolshemort", "race": 5, "class": 4, "level": 8, "online": 1, "zone": 14, "bot": True, "guild": "Workers"},
        {"guid": 2, "name": "Hugwa", "race": 6, "class": 1, "level": 8, "online": 1, "zone": 17, "bot": True, "guild": None},
        {"guid": 3, "name": "Playerone", "race": 8, "class": 7, "level": 3, "online": 0, "zone": 1637, "bot": False, "guild": "Workers"},
    ]
    ZONES = {14: "Durotar", 17: "The Barrens", 1637: "Orgrimmar"}

    def names(self, **kw):
        return [c["name"] for c in t.filter_characters(self.ROWS, self.ZONES, **kw)]

    def test_filters(self):
        self.assertEqual(self.names(zone="durotar"), ["Bolshemort"])
        self.assertEqual(self.names(zone="14"), ["Bolshemort"])
        self.assertEqual(self.names(cls="warrior"), ["Hugwa"])
        self.assertEqual(self.names(level="3-7"), ["Playerone"])
        self.assertEqual(self.names(kind="bot", guild="work"), ["Bolshemort"])
        self.assertEqual(self.names(online=True, kind="player"), [])
        self.assertEqual(self.names(roster_names={"Hugwa"}, roster_only=True), ["Hugwa"])
        self.assertEqual(self.names(roster_names={"Hugwa"}, roster_only=False), ["Bolshemort", "Playerone"])

    def test_bad_level(self):
        with self.assertRaises(SystemExit):
            t.filter_characters(self.ROWS, {}, level="high")

    def test_area_names_from_a_dbc(self):
        import struct
        import tempfile
        strings = b"\0Durotar\0Mulgore\0"
        recs = [(14, 143 * 0 + 1), (215, 9)]
        nfield = 12
        body = b"".join(struct.pack(f"<{nfield}I", rid, *([0] * 10), off) for rid, off in recs)
        data = struct.pack("<4s4I", b"WDBC", len(recs), nfield, nfield * 4, len(strings)) + body + strings
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "AreaTable.dbc"), "wb") as f:
                f.write(data)
            self.assertEqual(t.area_names(d), {14: "Durotar", 215: "Mulgore"})
        self.assertEqual(t.area_names("/nonexistent"), {})


class Attunements(unittest.TestCase):
    STATE = {
        "bots": [{"guid": 1, "name": "Sixty", "level": 60}, {"guid": 2, "name": "Fiftynine", "level": 59},
                 {"guid": 3, "name": "Honored", "level": 60}, {"guid": 4, "name": "Done", "level": 60}],
        "rewarded": [{"guid": 4, "quest": 9378}],
        "reputation": [{"guid": 3, "faction": 529, "standing": 9000}, {"guid": 1, "faction": 529, "standing": 8999}],
    }

    def test_defaults(self):
        rules = t.load_attunements({})
        self.assertEqual([r["quest"] for r in rules], [7848, 7761, 9378])
        self.assertEqual(rules[2]["faction"], 529)
        self.assertEqual(rules[2]["standing"], 9000)

    def test_reputation_and_level(self):
        rules = t.load_attunements({})
        lines, sql = t.plan_attunements([rules[2]], self.STATE)
        self.assertEqual(sql, ["INSERT INTO character_queststatus (guid, quest, status, rewarded) VALUES "
                               "(3, 9378, 1, 1) ON DUPLICATE KEY UPDATE status = 1, rewarded = 1;"])
        self.assertIn("grant 1, already 1, 1 at the level but short of the reputation", lines[0])

    def test_level_only(self):
        rules = t.load_attunements({"attunements": [{"name": "MC", "quest": 7848, "level": 60}]})
        _, sql = t.plan_attunements(rules, self.STATE)
        self.assertEqual(len(sql), 3)          # every level-60 bot, not the 59
        self.assertFalse(any("(2," in s for s in sql))

    def test_bad_rules(self):
        with self.assertRaises(t.RosterError):
            t.load_attunements({"attunements": [{"quest": 1, "level": 70}]})
        with self.assertRaises(t.RosterError):
            t.load_attunements({"attunements": [{"quest": 1, "reputation": {"faction": "no such", "at_least": "honored"}}]})

    def test_state_query_names_the_rules(self):
        sql = t.attune_sql("chars", "realmd", "RNDBOT", t.load_attunements({}))
        self.assertIn("quest IN (7848,7761,9378)", sql)
        self.assertIn("faction IN (529)", sql)
        self.assertIn("LIKE 'RNDBOT%'", sql)


class ConfCommand(unittest.TestCase):
    def run_conf(self, text, *args):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            src, out, sec = (os.path.join(d, n) for n in ("in.conf", "out.conf", "pw"))
            with open(src, "w") as f:
                f.write(text)
            with open(sec, "w") as f:
                f.write("Sup3rSecret\n")
            import contextlib
            import io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                t.main(["conf", "--conf", src, "--out", out, "--secret-file", sec, *args])
            with open(out) as f:
                return f.read(), buf.getvalue()

    def test_secret_goes_in_the_file_and_not_on_screen(self):
        text, shown = self.run_conf('LoginDatabaseInfo = "x"\n', "--set", 'LoginDatabaseInfo="h;3307;mangos;@SECRET@;realmd"')
        self.assertIn('"h;3307;mangos;Sup3rSecret;realmd"', text)
        self.assertNotIn("Sup3rSecret", shown)
        self.assertIn("****", shown)

    def test_require_refuses_an_unknown_key(self):
        with self.assertRaises(SystemExit):
            self.run_conf("A = 1\n", "--require", "--set", "Renamed=2")

    def test_require_accepts_a_commented_key(self):
        text, _ = self.run_conf("# Ra.Enable = 0\n", "--require", "--set", "Ra.Enable=1")
        self.assertEqual(text, "Ra.Enable = 1\n")


if __name__ == "__main__":
    unittest.main()
