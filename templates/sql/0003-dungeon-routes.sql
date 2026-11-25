-- kalimdor: the route of a group of bots through a dungeon - its bosses in
-- order, and waypoints where the navmesh alone does not take it (owner,
-- 2026-11-15; playerbots values/DungeonRun.h, Kamino 151). A run's leader
-- follows it step by step: a boss dead, or not in this instance (an unchosen
-- rare, optional = 1), is passed; the run clears at its end. A dungeon or
-- wing without a route goes for its nearest living boss. Wings: 0 for a
-- dungeon without any; else DungeonRun::Wing (2 the upper spire, 3-5 Dire
-- Maul, 6-9 Scarlet Monastery, 10-11 Stratholme, 12-14 Maraudon).
--
-- A step is a boss (entry, its spawn found by the leader) or a waypoint
-- (entry 0, x y z on the dungeon's map). The first seven: the usual order
-- in the original game, bosses only - waypoints to be added where a leader
-- is seen not reaching its next step.
--
-- It can run again: the table is filled anew each time.
-- A dungeon's gathering point, where it is not the outermost way in the
-- travel nodes give (values/DungeonRun.h MeetingPoint): set by hand where a
-- group really meets - the Wailing Caverns on the hill above its cave mouth
-- (owner, in game, 2026-11-17).
CREATE TABLE IF NOT EXISTS `kalimdor_dungeon_meet` (
  `map` smallint(5) unsigned NOT NULL,
  `x` float NOT NULL,
  `y` float NOT NULL,
  `z` float NOT NULL,
  `continent` smallint(5) unsigned NOT NULL COMMENT 'the map the point is on',
  `note` varchar(100) NOT NULL DEFAULT '',
  PRIMARY KEY (`map`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='kalimdor: dungeon gathering points for groups of bots (Kamino 151)';

DELETE FROM `kalimdor_dungeon_meet`;
INSERT INTO `kalimdor_dungeon_meet` (`map`, `x`, `y`, `z`, `continent`, `note`) VALUES
(43, -801.9, -2132.0, 92.0, 1, 'Wailing Caverns: on the hill above its cave mouth');

CREATE TABLE IF NOT EXISTS `kalimdor_dungeon_route` (
  `map` smallint(5) unsigned NOT NULL,
  `wing` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `step` tinyint(3) unsigned NOT NULL,
  `entry` mediumint(8) unsigned NOT NULL DEFAULT 0 COMMENT 'a boss; 0 for a waypoint',
  `x` float NOT NULL DEFAULT 0,
  `y` float NOT NULL DEFAULT 0,
  `z` float NOT NULL DEFAULT 0,
  `optional` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT 'a rare: passed when not in the instance',
  `note` varchar(100) NOT NULL DEFAULT '',
  PRIMARY KEY (`map`, `wing`, `step`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='kalimdor: dungeon routes for groups of bots (Kamino 151)';

-- A step's kind (owner, 2026-11-17): walk (by the navmesh), straight (in a
-- line - a bridge, a stretch with things in the way), drop / jump / swim (in a
-- line, the whole group together - off a ledge, across a gap, through water),
-- pull / charge (a boss: pulled to the group, or the tank goes in - casters),
-- wait (for npc to come by, then pull it), quests (each member takes npc's
-- quests for the dungeon), gossip (npc's gift to each member - the Disciple
-- of Naralex's Mark of the Wild). Wing 100: the way in, from the gathering
-- point outside to the portal.
ALTER TABLE `kalimdor_dungeon_route`
  ADD COLUMN IF NOT EXISTS `kind` varchar(10) NOT NULL DEFAULT 'walk' AFTER `optional`,
  ADD COLUMN IF NOT EXISTS `npc` mediumint(8) unsigned NOT NULL DEFAULT 0 AFTER `kind`,
  ADD COLUMN IF NOT EXISTS `leash` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'yards: on the leg to this step, members fighting farther from their leader go back to it; 0 none' AFTER `npc`,
  ADD COLUMN IF NOT EXISTS `hold` tinyint(1) unsigned NOT NULL DEFAULT 0 COMMENT 'fights on the leg to this step: ranged and healer hold where they stand' AFTER `leash`,
  ADD COLUMN IF NOT EXISTS `tank_x` float NOT NULL DEFAULT 0 COMMENT 'a tank spot for fights on this leg (tank_x, tank_y, tank_z); 0 0 0 none' AFTER `hold`,
  ADD COLUMN IF NOT EXISTS `tank_y` float NOT NULL DEFAULT 0 AFTER `tank_x`,
  ADD COLUMN IF NOT EXISTS `tank_z` float NOT NULL DEFAULT 0 AFTER `tank_y`,
  ADD COLUMN IF NOT EXISTS `ranged_x` float NOT NULL DEFAULT 0 COMMENT 'a spot ranged members hold in fights on this leg (ranged_x, ranged_y, ranged_z); 0 0 0 none' AFTER `tank_z`,
  ADD COLUMN IF NOT EXISTS `ranged_y` float NOT NULL DEFAULT 0 AFTER `ranged_x`,
  ADD COLUMN IF NOT EXISTS `ranged_z` float NOT NULL DEFAULT 0 AFTER `ranged_y`;

DELETE FROM `kalimdor_dungeon_route`;
INSERT INTO `kalimdor_dungeon_route` (`map`, `wing`, `step`, `entry`, `optional`, `note`) VALUES
(389, 0, 1, 11517, 0, 'Ragefire Chasm: Oggleflint'),
(389, 0, 2, 11520, 0, 'Ragefire Chasm: Taragaman the Hungerer'),
(389, 0, 3, 11518, 0, 'Ragefire Chasm: Jergosh the Invoker'),
(389, 0, 4, 11519, 0, 'Ragefire Chasm: Bazzalan'),
(36, 0, 1, 644, 0, 'Deadmines: Rhahk''Zor'),
(36, 0, 2, 3586, 1, 'Deadmines: Miner Johnson'),
(36, 0, 3, 642, 0, 'Deadmines: Sneed''s Shredder'),
(36, 0, 4, 1763, 0, 'Deadmines: Gilnid'),
(36, 0, 5, 646, 0, 'Deadmines: Mr. Smite'),
(36, 0, 6, 647, 0, 'Deadmines: Captain Greenskin'),
(36, 0, 7, 639, 0, 'Deadmines: Edwin VanCleef'),
(36, 0, 8, 645, 0, 'Deadmines: Cookie'),
(33, 0, 1, 3914, 0, 'Shadowfang Keep: Rethilgore'),
(33, 0, 2, 3886, 0, 'Shadowfang Keep: Razorclaw the Butcher'),
(33, 0, 3, 3887, 0, 'Shadowfang Keep: Baron Silverlaine'),
(33, 0, 4, 4278, 0, 'Shadowfang Keep: Commander Springvale'),
(33, 0, 5, 4279, 0, 'Shadowfang Keep: Odo the Blindwatcher'),
(33, 0, 6, 3872, 1, 'Shadowfang Keep: Deathsworn Captain'),
(33, 0, 7, 4274, 0, 'Shadowfang Keep: Fenrus the Devourer'),
(33, 0, 8, 3927, 0, 'Shadowfang Keep: Wolf Master Nandos'),
(33, 0, 9, 4275, 0, 'Shadowfang Keep: Archmage Arugal'),
(48, 0, 1, 4887, 0, 'Blackfathom Deeps: Ghamoo-ra'),
(48, 0, 2, 4831, 0, 'Blackfathom Deeps: Lady Sarevess'),
(48, 0, 3, 6243, 0, 'Blackfathom Deeps: Gelihast'),
(48, 0, 4, 4832, 0, 'Blackfathom Deeps: Twilight Lord Kelris'),
(48, 0, 5, 4830, 0, 'Blackfathom Deeps: Old Serra''kis'),
(48, 0, 6, 4829, 0, 'Blackfathom Deeps: Aku''mai'),
(34, 0, 1, 1696, 0, 'Stormwind Stockade: Targorr the Dread'),
(34, 0, 2, 1666, 0, 'Stormwind Stockade: Kam Deepfury'),
(34, 0, 3, 1717, 0, 'Stormwind Stockade: Hamhock'),
(34, 0, 4, 1716, 0, 'Stormwind Stockade: Bazil Thredd'),
(34, 0, 5, 1663, 0, 'Stormwind Stockade: Dextren Ward'),
(34, 0, 6, 1720, 1, 'Stormwind Stockade: Bruegal Ironknuckle'),
(47, 0, 1, 6168, 0, 'Razorfen Kraul: Roogug'),
(47, 0, 2, 4424, 0, 'Razorfen Kraul: Aggem Thorncurse'),
(47, 0, 3, 4428, 0, 'Razorfen Kraul: Death Speaker Jargba'),
(47, 0, 4, 4420, 0, 'Razorfen Kraul: Overlord Ramtusk'),
(47, 0, 5, 4422, 0, 'Razorfen Kraul: Agathelos the Raging'),
(47, 0, 6, 4421, 0, 'Razorfen Kraul: Charlga Razorflank');

-- The Wailing Caverns: walked by the owner in game, a point at each turn,
-- drop, jump and stop (2026-11-17) - the way in from the gathering point on
-- the hill (wing 100), then inside from where the portal lands past every
-- boss and Kresh back to the Disciple of Naralex, where the escort starts.
INSERT INTO `kalimdor_dungeon_route` (`map`, `wing`, `step`, `entry`, `x`, `y`, `z`, `optional`, `kind`, `npc`, `note`) VALUES
(43, 100, 1, 0, -782.2, -2109.7, 111.0, 0, 'walk', 0, 'Wailing Caverns, the way in: from the gathering point, up the hill'),
(43, 100, 2, 0, -744.0, -2140.5, 122.9, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 3, 0, -714.6, -2160.0, 147.3, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 4, 0, -737.9, -2105.4, 142.5, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 5, 0, -751.7, -2072.3, 126.9, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 6, 0, -774.6, -2063.7, 109.2, 0, 'drop', 0, 'Wailing Caverns, the way in: a drop forward - bots circled to avoid it (owner, 2026-11-20)'),
(43, 100, 7, 0, -806.9, -2049.7, 115.6, 0, 'walk', 0, 'Wailing Caverns, the way in: a shorter leg after the drop (owner, 2026-11-20)'),
(43, 100, 8, 0, -814.2, -2044.1, 116.9, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 9, 0, -824.2, -2037.5, 118.1, 0, 'walk', 0, 'Wailing Caverns, the way in: the edge of the first drop'),
(43, 100, 10, 0, -833.5, -2031.6, 108.6, 0, 'drop', 0, 'Wailing Caverns, the way in: landing of the first drop'),
(43, 100, 11, 0, -823.6, -2021.0, 99.9, 0, 'drop', 0, 'Wailing Caverns, the way in: landing of the second drop, the quest cave entrance'),
(43, 100, 12, 0, -801.1, -2035.7, 95.9, 0, 'quests', 5767, 'Wailing Caverns, the way in: the quest givers: Nalpak'),
(43, 100, 13, 0, -801.1, -2035.7, 95.9, 0, 'quests', 5768, 'Wailing Caverns, the way in: the quest givers: Ebru'),
(43, 100, 14, 0, -831.4, -2014.9, 99.6, 0, 'walk', 0, 'Wailing Caverns, the way in: out of the quest cave'),
(43, 100, 15, 0, -853.3, -2025.2, 84.3, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 16, 0, -838.0, -2035.3, 80.2, 0, 'walk', 0, 'Wailing Caverns, the way in: the main cave entrance'),
(43, 100, 17, 0, -815.9, -2030.7, 80.6, 0, 'walk', 0, 'Wailing Caverns, the way in: pull spot: the first Deviate Creeper ahead'),
(43, 100, 18, 0, -790.4, -2026.9, 79.2, 0, 'straight', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 19, 0, -770.2, -2054.5, 75.0, 0, 'walk', 0, 'Wailing Caverns, the way in: among Deviate Creepers and Coilers'),
(43, 100, 20, 0, -754.6, -2061.2, 71.8, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 21, 0, -702.7, -2046.8, 65.5, 0, 'straight', 0, 'Wailing Caverns, the way in: the crossroads inside the cave'),
(43, 100, 22, 0, -667.3, -2044.5, 65.6, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 23, 0, -625.4, -2019.5, 63.8, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 24, 0, -581.6, -2046.8, 57.3, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 25, 0, -573.3, -2088.4, 51.1, 0, 'walk', 0, 'Wailing Caverns, the way in: before the first inner pond'),
(43, 100, 26, 0, -590.2, -2127.8, 50.1, 0, 'swim', 0, 'Wailing Caverns, the way in: across the pond, swimming'),
(43, 100, 27, 0, -608.7, -2156.8, 51.8, 0, 'walk', 0, 'Wailing Caverns, the way in: the Cave of Mists, its turn'),
(43, 100, 28, 0, -605.8, -2181.4, 49.7, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 29, 0, -669.1, -2189.4, 37.4, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 30, 0, -715.7, -2202.2, 22.6, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 31, 0, -725.9, -2237.6, 16.7, 0, 'walk', 0, 'Wailing Caverns, the way in: on the way'),
(43, 100, 32, 0, -738.5, -2217.8, 16.7, 0, 'walk', 0, 'Wailing Caverns, the way in: at the portal'),
(43, 0, 1, 0, -158.4, 131.6, -74.3, 0, 'walk', 0, 'Wailing Caverns: where the portal lands'),
(43, 0, 2, 0, -137.6, 127.5, -78.1, 0, 'gossip', 3678, 'Wailing Caverns: the Disciple of Naralex: his Mark of the Wild'),
(43, 0, 3, 0, -109.8, 153.1, -80.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 4, 0, -107.1, 237.0, -92.2, 0, 'walk', 0, 'Wailing Caverns: the first turn (the escort''s first ambush)'),
(43, 0, 5, 0, -62.3, 207.3, -93.5, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 6, 0, -33.9, 206.4, -96.6, 0, 'straight', 0, 'Wailing Caverns: the ramp crossroads - straight on from step 5 (owner, 2026-11-20)'),
(43, 0, 7, 0, -32.5, 236.8, -93.6, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 8, 0, -53.2, 275.7, -92.8, 0, 'walk', 0, 'Wailing Caverns: Anacondra''s first spawn point (the escort''s second ambush)'),
(43, 0, 9, 0, -46.1, 296.6, -90.8, 0, 'walk', 0, 'Wailing Caverns: before a small bridge'),
(43, 0, 10, 0, -34.6, 310.3, -89.6, 0, 'straight', 0, 'Wailing Caverns: across the bridge'),
(43, 0, 11, 0, -10.0, 309.5, -88.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 12, 0, 8.4, 289.2, -86.5, 0, 'walk', 0, 'Wailing Caverns: Anacondra''s second spawn point'),
(43, 0, 13, 0, 26.1, 264.0, -86.9, 0, 'walk', 0, 'Wailing Caverns: before a small bridge'),
(43, 0, 14, 0, 33.8, 250.2, -87.7, 0, 'straight', 0, 'Wailing Caverns: across the bridge'),
(43, 0, 15, 0, 57.3, 208.5, -90.9, 0, 'walk', 0, 'Wailing Caverns: the sleepers'' cave entrance'),
(43, 0, 16, 0, 39.6, 191.7, -87.9, 0, 'walk', 0, 'Wailing Caverns: by Anacondra''s fourth spawn point'),
(43, 0, 17, 0, 27.8, 155.5, -90.0, 0, 'walk', 0, 'Wailing Caverns: by a Serpentbloom'),
(43, 0, 18, 0, -4.9, 141.0, -88.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 19, 0, -24.8, 105.3, -89.5, 0, 'walk', 0, 'Wailing Caverns: before a bridge'),
(43, 0, 20, 0, -60.9, 122.6, -89.4, 0, 'straight', 0, 'Wailing Caverns: across the bridge, by Anacondra''s third spawn point'),
(43, 0, 21, 3671, 0, 0, 0, 0, 'pull', 0, 'Wailing Caverns: Lady Anacondra'),
(43, 0, 22, 0, -41.9, 155.3, -94.8, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 23, 0, -26.9, 203.5, -97.9, 0, 'walk', 0, 'Wailing Caverns: the foot of the ramp'),
(43, 0, 24, 0, -20.1, 203.0, -98.9, 0, 'walk', 0, 'Wailing Caverns: the access to the top of the ramp (owner, 2026-11-20)'),
(43, 0, 25, 0, -19.1, 229.4, -104.2, 0, 'walk', 0, 'Wailing Caverns: its left entrance, toward Kresh (owner, 2026-11-20)'),
(43, 0, 26, 0, -12.9, 269.6, -106.4, 0, 'wait', 3653, 'Wailing Caverns: Kresh: waited for at the bottom of the ramp, left side'),
(43, 0, 27, 0, -42.9, 304.7, -106.4, 0, 'walk', 0, 'Wailing Caverns: under the first bridge'),
(43, 0, 28, 0, -76.6, 328.1, -106.2, 0, 'walk', 0, 'Wailing Caverns: the Pit of Fangs turn'),
(43, 0, 29, 0, -61.4, 423.4, -106.3, 0, 'walk', 0, 'Wailing Caverns: the foot of the ramp to Cobrahn'),
(43, 0, 30, 0, 5.5, 473.7, -89.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 31, 0, 35.5, 447.9, -85.4, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 32, 0, 0.8, 450.9, -75.9, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 33, 0, -3.8, 418.3, -66.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 34, 0, -28.8, 424.6, -60.2, 0, 'walk', 0, 'Wailing Caverns: the top of the ramp'),
(43, 0, 35, 0, -33.9, 385.1, -59.8, 0, 'walk', 0, 'Wailing Caverns: a small pack'),
(43, 0, 36, 0, -11.8, 381.9, -60.1, 0, 'walk', 0, 'Wailing Caverns: between the small pack and on (owner)'),
(43, 0, 37, 0, 30.2, 388.2, -59.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 38, 0, 70.3, 415.7, -63.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 39, 0, 34.1, 522.2, -57.5, 0, 'walk', 0, 'Wailing Caverns: by a chest spawn point'),
(43, 0, 40, 0, -34.5, 485.1, -53.8, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 41, 0, -71.2, 482.7, -62.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 42, 0, -127.0, 416.2, -72.7, 0, 'walk', 0, 'Wailing Caverns: Cobrahn''s charge point'),
(43, 0, 43, 3669, 0, 0, 0, 0, 'charge', 0, 'Wailing Caverns: Lord Cobrahn'),
(43, 0, 44, 5912, 0, 0, 0, 1, 'pull', 0, 'Wailing Caverns: Deviate Faerie Dragon'),
(43, 0, 45, 0, -108.9, 414.4, -74.2, 0, 'walk', 0, 'Wailing Caverns: the exit ledge'),
(43, 0, 46, 0, -93.4, 410.2, -106.8, 0, 'drop', 0, 'Wailing Caverns: dropped off the ledge'),
(43, 0, 47, 0, -69.3, 363.4, -106.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 48, 0, -76.6, 328.1, -106.2, 0, 'walk', 0, 'Wailing Caverns: the Pit of Fangs turn'),
(43, 0, 49, 0, -36.1, 298.4, -106.4, 0, 'walk', 0, 'Wailing Caverns: the Screaming Gully'),
(43, 0, 50, 0, -5.4, 181.9, -106.2, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 51, 0, -57.5, 93.0, -106.2, 0, 'walk', 0, 'Wailing Caverns: the Screaming Gully crossroads'),
(43, 0, 52, 0, -91.5, 64.1, -106.2, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 53, 0, -140.6, 75.0, -105.2, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 54, 0, -164.0, -3.5, -106.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 55, 0, -319.5, 17.4, -105.7, 0, 'straight', 0, 'Wailing Caverns: straight on'),
(43, 0, 56, 0, -342.6, 51.4, -98.5, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 57, 0, -290.4, 45.1, -91.2, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 58, 0, -269.7, 33.1, -88.0, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 59, 0, -167.0, 88.6, -76.5, 0, 'straight', 0, 'Wailing Caverns: straight on, creatures in the middle'),
(43, 0, 60, 0, -136.0, 30.4, -74.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 61, 0, -171.9, -99.1, -66.5, 0, 'straight', 0, 'Wailing Caverns: the Winding Chasm'),
(43, 0, 62, 0, -119.1, -102.1, -73.4, 0, 'walk', 0, 'Wailing Caverns: the Winding Chasm crossroads'),
(43, 0, 63, 0, -77.2, -49.3, -60.5, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 64, 0, -17.4, -67.3, -67.5, 0, 'walk', 0, 'Wailing Caverns: by a chest spawn point'),
(43, 0, 65, 0, -40.6, -118.9, -71.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 66, 0, 31.2, -160.3, -81.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 67, 0, -16.4, -206.0, -74.8, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 68, 0, 16.7, -239.0, -77.3, 0, 'walk', 0, 'Wailing Caverns: Pythas''s charge point'),
(43, 0, 69, 3670, 0, 0, 0, 0, 'charge', 0, 'Wailing Caverns: Lord Pythas'),
(43, 0, 70, 0, -57.4, -231.9, -68.6, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 71, 0, -130.2, -179.3, -68.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 72, 0, -154.9, -226.3, -71.6, 0, 'walk', 0, 'Wailing Caverns: narrow'),
(43, 0, 73, 0, -197.2, -245.4, -67.9, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 74, 0, -218.2, -301.9, -70.4, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 75, 0, -265.0, -298.9, -68.2, 0, 'walk', 0, 'Wailing Caverns: Skum''s charge point'),
(43, 0, 76, 3674, 0, 0, 0, 0, 'charge', 0, 'Wailing Caverns: Skum'),
(43, 0, 77, 0, -283.6, -310.9, -69.2, 0, 'walk', 0, 'Wailing Caverns: Skum''s spot: the group gathers after the fight'),
(43, 0, 78, 0, -265.0, -298.9, -68.2, 0, 'walk', 0, 'Wailing Caverns: back to the charge point (a fence)'),
(43, 0, 79, 0, -266.5, -261.3, -64.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 80, 0, -277.9, -236.5, -62.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 81, 0, -257.4, -192.3, -58.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 82, 0, -305.5, -137.2, -61.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 83, 0, -296.6, -112.3, -64.0, 0, 'straight', 0, 'Wailing Caverns: on the straight leg - a hard pull held here (owner)'),
(43, 0, 84, 0, -308.3, -78.9, -64.3, 0, 'straight', 0, 'Wailing Caverns: on the straight leg - a hard pull held here (owner)'),
(43, 0, 85, 0, -313.0, -42.9, -63.6, 0, 'straight', 0, 'Wailing Caverns: straight on, things in the way'),
(43, 0, 86, 0, -295.6, -23.2, -60.3, 0, 'walk', 0, 'Wailing Caverns: before the jump'),
(43, 0, 87, 0, -289.99, -3.00, -58.20, 0, 'walk', 0, 'Wailing Caverns: the jump spot'),
(43, 0, 88, 0, -286.7, 1.9, -64.1, 0, 'jump', 0, 'Wailing Caverns: landed after the jump'),
(43, 0, 89, 0, -261.6, 52.2, -54.1, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 90, 0, -212.4, 58.9, -49.9, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 91, 0, -170.4, 56.7, -41.2, 0, 'straight', 0, 'Wailing Caverns: by a ledge on the right'),
(43, 0, 92, 0, -139.9, 29.6, -28.1, 0, 'walk', 0, 'Wailing Caverns: the top'),
(43, 0, 93, 0, -127.4, -6.4, -28.5, 0, 'walk', 0, 'Wailing Caverns: Serpentis''s charge point'),
(43, 0, 94, 3673, 0, 0, 0, 0, 'charge', 0, 'Wailing Caverns: Lord Serpentis'),
(43, 0, 95, 0, -105.2, 17.3, -30.8, 0, 'walk', 0, 'Wailing Caverns: on the way to Verdan'),
(43, 0, 96, 5775, 0, 0, 0, 0, 'charge', 0, 'Wailing Caverns: Verdan the Everliving'),
(43, 0, 97, 0, -53.6, 43.5, -29.8, 0, 'walk', 0, 'Wailing Caverns: the exit: on, dropping'),
(43, 0, 98, 0, -34.1, 40.0, -109.2, 0, 'drop', 0, 'Wailing Caverns: landed in the water'),
(43, 0, 99, 0, -60.6, 56.6, -106.4, 0, 'swim', 0, 'Wailing Caverns: surfaced at the shore'),
(43, 0, 100, 0, -57.5, 93.0, -106.2, 0, 'walk', 0, 'Wailing Caverns: the Screaming Gully crossroads'),
(43, 0, 101, 0, -23.9, 144.0, -106.0, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 102, 0, -21.0, 169.9, -104.5, 0, 'walk', 0, 'Wailing Caverns: its right entrance, from the gully (owner, 2026-11-20)'),
(43, 0, 103, 0, -20.1, 203.0, -98.9, 0, 'walk', 0, 'Wailing Caverns: the access to the top of the ramp (owner, 2026-11-20)'),
(43, 0, 104, 0, -26.9, 203.5, -97.9, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 105, 0, -62.3, 207.3, -93.5, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 106, 0, -107.1, 237.0, -92.2, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 107, 0, -110.7, 163.4, -79.7, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 108, 0, -119.5, 137.4, -79.3, 0, 'walk', 0, 'Wailing Caverns: on the way'),
(43, 0, 109, 0, -137.6, 127.5, -78.1, 0, 'walk', 0, 'Wailing Caverns: back at the Disciple of Naralex');

-- Leashes: legs where a member fighting farther from its leader than this
-- goes back to it - set by spot, not for every fight (owner, 2026-11-20):
-- the Wailing Caverns' way in, its turn in the Cave of Mists.
UPDATE `kalimdor_dungeon_route` SET `leash` = 20 WHERE `map` = 43 AND `wing` = 100 AND `step` IN (27, 28, 29);
-- Fight spots (owner, 2026-11-20): a hard hold - ranged and the healer fight
-- from where a fight finds them - down from the Cobrahn ramp to the druids.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1 WHERE `map` = 43 AND `wing` = 0 AND `step` = 35;
-- Its tank spot: the tank fights from it, back to it after a stray.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -40.8, `tank_y` = 376.5, `tank_z` = -60.1 WHERE `map` = 43 AND `wing` = 0 AND `step` = 35;
-- Cobrahn (step 43): ranged members hold this spot through his fight.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -123.9, `ranged_y` = 422.2, `ranged_z` = -72.7 WHERE `map` = 43 AND `wing` = 0 AND `step` = 43;
-- Cobrahn: tanked where he stands.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -151.1, `tank_y` = 414.4, `tank_z` = -72.6 WHERE `map` = 43 AND `wing` = 0 AND `step` = 43;
-- The Cave of Mists turn (owner, 2026-11-20): a hard hold too - ranged hold
-- this spot through fights on the turn.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -604.2, `ranged_y` = -2161.5, `ranged_z` = 52.1 WHERE `map` = 43 AND `wing` = 100 AND `step` IN (27, 28);
-- Its tank spot on the turn.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -607.5, `tank_y` = -2179.9, `tank_z` = 50.0 WHERE `map` = 43 AND `wing` = 100 AND `step` IN (27, 28);
-- The leg past Skum's pool (owner, 2026-11-22): a hard pull - Lashers and a
-- Dreadfang, two packs woke if let free; ranged hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -270.5, `ranged_y` = -251.6, `ranged_z` = -62.2 WHERE `map` = 43 AND `wing` = 0 AND `step` IN (79, 80);
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -296.1, `tank_y` = -249.3, `tank_z` = -63.8 WHERE `map` = 43 AND `wing` = 0 AND `step` IN (79, 80);
-- On past it, toward step 81 (owner, 2026-11-22): another hard pull; ranged
-- hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -258.6, `ranged_y` = -206.5, `ranged_z` = -61.8 WHERE `map` = 43 AND `wing` = 0 AND `step` = 81;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -263.0, `tank_y` = -188.2, `tank_z` = -59.6 WHERE `map` = 43 AND `wing` = 0 AND `step` = 81;
-- On toward step 82 (owner, 2026-11-22): the area is tricky; ranged hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -301.5, `ranged_y` = -170.7, `ranged_z` = -60.9 WHERE `map` = 43 AND `wing` = 0 AND `step` = 82;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -305.8, `tank_y` = -154.7, `tank_z` = -60.3 WHERE `map` = 43 AND `wing` = 0 AND `step` = 82;
-- Step 83 (owner, 2026-11-22): the straight leg past step 82, tricky too;
-- ranged hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -296.6, `ranged_y` = -112.3, `ranged_z` = -64.0 WHERE `map` = 43 AND `wing` = 0 AND `step` = 83;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -308.3, `tank_y` = -93.1, `tank_z` = -64.6 WHERE `map` = 43 AND `wing` = 0 AND `step` = 83;
-- Step 84 (owner, 2026-11-22): on along the straight leg; ranged hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -308.3, `ranged_y` = -78.9, `ranged_z` = -64.3 WHERE `map` = 43 AND `wing` = 0 AND `step` = 84;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -326.8, `tank_y` = -69.4, `tank_z` = -65.2 WHERE `map` = 43 AND `wing` = 0 AND `step` = 84;

-- Killed first in a fight by the damage dealers - the tank keeps whatever is
-- hostile (owner, 2026-11-22). Every creature that heals its own is already
-- one (its script's "friendly missing health" event; playerbots DungeonRun::
-- KillFirst); these are the rest, or the same named for the record - the
-- Wailing Caverns' Druids of the Fang put a member to sleep (Druid Slumber)
-- and heal their pack.
CREATE TABLE IF NOT EXISTS `kalimdor_dungeon_kill_first` (
  `map` smallint(5) unsigned NOT NULL,
  `entry` int(10) unsigned NOT NULL,
  `note` varchar(100) NOT NULL DEFAULT '',
  PRIMARY KEY (`map`, `entry`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='kalimdor: creatures a dungeon group kills first (Kamino 151)';
DELETE FROM `kalimdor_dungeon_kill_first`;
INSERT INTO `kalimdor_dungeon_kill_first` (`map`, `entry`, `note`) VALUES
(43, 3840, 'Wailing Caverns: Druid of the Fang - sleeps one (Druid Slumber), heals its pack');
-- Step 90 (owner, 2026-11-22): past the jump, a hard pull; ranged hold here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -220.9, `ranged_y` = 57.6, `ranged_z` = -49.1 WHERE `map` = 43 AND `wing` = 0 AND `step` = 90;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -199.6, `tank_y` = 61.9, `tank_z` = -48.7 WHERE `map` = 43 AND `wing` = 0 AND `step` = 90;
-- Lord Serpentis (step 94, owner, 2026-11-22): a hard hold; ranged here.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -133.0, `ranged_y` = 3.5, `ranged_z` = -28.5 WHERE `map` = 43 AND `wing` = 0 AND `step` = 94;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -122.1, `tank_y` = -9.9, `tank_z` = -28.5 WHERE `map` = 43 AND `wing` = 0 AND `step` = 94;
-- Verdan the Everliving (step 96, owner, 2026-11-22): a hard hold; ranged
-- here, 30 yards from him.
UPDATE `kalimdor_dungeon_route` SET `hold` = 1, `ranged_x` = -112.0, `ranged_y` = 16.2, `ranged_z` = -30.4 WHERE `map` = 43 AND `wing` = 0 AND `step` = 96;
-- Its tank spot.
UPDATE `kalimdor_dungeon_route` SET `tank_x` = -96.6, `tank_y` = 25.3, `tank_z` = -31.1 WHERE `map` = 43 AND `wing` = 0 AND `step` = 96;
