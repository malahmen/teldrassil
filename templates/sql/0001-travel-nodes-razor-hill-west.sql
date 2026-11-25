-- kalimdor: two travel-graph nodes west of Razor Hill (Kamino 210).
--
-- From Tiragarde Keep every route out of Durotar - to Ratchet, the neutral
-- town an Alliance bot walks out to - led to the Razor Hill spirit healer,
-- 43 yards from a grunt: inside the reach bots keep from guards well above
-- them, so they bounced there and never left. These give the graph a way
-- around the town's edge: Tiragarde Keep -> west of Razor Hill -> clear of
-- the grunts -> Razormane Grounds -> across the Southfury River -> Ratchet.
-- The second point was picked in game (owner, 2026-10-30), 81 yards from the
-- nearest grunt; the first is 241 yards from one.
--
-- Nodes only, with linked = 0: playerbots walks the ground from each to its
-- neighbours within 2000 yards at the world server's next start, saves the
-- links and paths, and marks them linked. It also renumbers node ids when it
-- saves, so a node is matched by its name - running this again adds nothing.
--
-- The image applies it before every start of the world server (deploy/
-- kalimdor.sh, world_sql). Elsewhere, apply it to the world database and
-- restart the world server, for example:
--   teldrassil.sh [--profile P] apply-sql --file sql/0001-travel-nodes-razor-hill-west.sql --db classicmangos

INSERT INTO ai_playerbot_travelnode (id, name, map_id, x, y, z, linked)
SELECT (SELECT MAX(id) + 1 FROM ai_playerbot_travelnode), 'kalimdor: Durotar west of Razor Hill', 1, 8.5, -4853.8, 21.3, 0
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM ai_playerbot_travelnode WHERE name = 'kalimdor: Durotar west of Razor Hill');

INSERT INTO ai_playerbot_travelnode (id, name, map_id, x, y, z, linked)
SELECT (SELECT MAX(id) + 1 FROM ai_playerbot_travelnode), 'kalimdor: Razor Hill west, clear of the grunts', 1, 137.28, -4648.18, 23.95, 0
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM ai_playerbot_travelnode WHERE name = 'kalimdor: Razor Hill west, clear of the grunts');
