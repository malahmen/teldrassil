-- kalimdor: High Priestess Jeklik (Zul'Gurub) swoops again (Kamino 304).
--
-- Her phase-1 spell list (1451701, set by boss_jeklik.cpp) has a row named
-- "Swoop" whose spell is 24210 - Mark of Arlokk, a mark for Arlokk's
-- panthers - so she never swooped. Her script names Swoop 23919
-- (boss_jeklik.cpp SPELL_SWOOP); spell_template has 23919 "Swoop" and 24210
-- "Mark of Arlokk". Her phase-2 row 23952 is only labelled "Ravage": it is
-- her Shadow Word: Pain, as the script says, and is relabelled.
--
-- It can run again: it sets the rows to what they should be.
UPDATE `creature_spell_list` SET `SpellId` = 23919
  WHERE `Id` = 1451701 AND `Position` = 1 AND `SpellId` IN (24210, 23919);
UPDATE `creature_spell_list` SET `Comments` = 'High Priestess Jeklik Phase 2 - Shadow Word: Pain on Current'
  WHERE `Id` = 1451702 AND `Position` = 0 AND `SpellId` = 23952;
