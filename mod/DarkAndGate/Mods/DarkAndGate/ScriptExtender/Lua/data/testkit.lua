-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test kit commands (Server/Combat/TestKit.lua): a weapon chest, a goblin
-- squad to fight, god mode. Every GUID below is a vanilla root template
-- (Shared.pak Public/Shared/RootTemplates, checked 2026-10-12); weapons come
-- from each base weapon's stats RootTemplate field, so no item GUID is
-- written here.
return {
    -- !dag_chest: one of every weapon type BG3 has, a shield and a few
    -- stacks of special arrows, in a plain wooden chest ahead of you.
    chest = {
        template = "5f089bb9-1816-43b8-8e44-f2d58804ea23",   -- CONT_GEN_Chest_Wood_A
        ahead_m  = 2.0,
        -- Base weapon stats entries (Weapon.txt "using _BaseWeapon"; BG3 has no
        -- darts or slings in play, so those two are left out).
        weapons = {
            -- simple melee
            "WPN_Club", "WPN_Dagger", "WPN_Greatclub", "WPN_Handaxe", "WPN_Javelin", "WPN_LightHammer",
            "WPN_Mace", "WPN_Quarterstaff", "WPN_Sickle", "WPN_Spear",
            -- simple ranged
            "WPN_LightCrossbow", "WPN_Shortbow",
            -- martial melee
            "WPN_Battleaxe", "WPN_Flail", "WPN_Glaive", "WPN_Greataxe", "WPN_Greatsword", "WPN_Halberd",
            "WPN_Longsword", "WPN_Maul", "WPN_Morningstar", "WPN_Pike", "WPN_Rapier", "WPN_Scimitar",
            "WPN_Shortsword", "WPN_Trident", "WPN_Warhammer", "WPN_WarPick",
            -- martial ranged
            "WPN_HandCrossbow", "WPN_HeavyCrossbow", "WPN_Longbow",
        },
        -- Stats entry -> count. BG3 bows never run out of plain arrows; these
        -- are the special arrows (thrown from the inventory in vanilla).
        extras = {
            { stats = "ARM_Shield",           count = 1 },
            { stats = "OBJ_ArrowOfFire",      count = 10 },
            { stats = "OBJ_ArrowOfIce",       count = 10 },
            { stats = "OBJ_ArrowOfAcid",      count = 10 },
            { stats = "OBJ_ArrowOfLightning", count = 10 },
            { stats = "OBJ_ArrowOfPiercing",  count = 10 },
        },
        -- The chest's own random loot (its treasure table) is removed before
        -- the weapons go in, this long after it spawns.
        fill_delay_ms = 300,
    },

    -- !dag_goblins [kind [count] ...] [idle] | clear | list
    goblins = {
        kinds = {
            melee   = { template = "2db928f2-f1c5-4b5a-8751-168f9f292249", row = "front", note = "scimitar (Goblins_Male_Melee)" },
            brute   = { template = "eb092260-3e6f-4576-b029-83b22ed56c0f", row = "front", note = "greataxe (Goblins_Male_Melee_Tier2)" },
            shield  = { template = "b0f372f0-f74f-4c00-84e6-34ba09117578", row = "front", note = "scimitar + shield (Goblins_Male_Boss)" },
            archer  = { template = "bdf828ab-4335-4626-b159-312b67397011", row = "back",  note = "shortbow (Goblins_Male_Ranger)" },
            caster  = { template = "01fa8d64-f63e-4bb8-9ee4-cba84dad3781", row = "back",  note = "Ray of Sickness, Acid Splash, Grease (Goblins_Male_Caster)" },
            warlock = { template = "bf128eb5-3f9b-4448-839f-2f4e7bd4f7ae", row = "back",  note = "Eldritch Blast, Hex (Goblins_Male_Warlock)" },
            cleric  = { template = "19aafe06-624c-4dd4-9480-60a359fb9c50", row = "back",  note = "mace + shield, Sacred Flame, Bless, Cure Wounds (Goblins_Male_Devout)" },
        },
        aliases = { scimitar = "melee", axe = "brute", greataxe = "brute", boss = "shield", bow = "archer", ranged = "archer",
                    ranger = "archer", mage = "caster", spell = "caster", priest = "cleric" },
        -- No kinds given: two melee goblins (different weapons), an archer
        -- and a caster.
        squad = { "melee", "brute", "archer", "caster" },
        max = 12,
        -- Rows ahead of you (m) and the spacing across the view.
        front_m = 9.0, back_m = 14.0, spacing_m = 2.5,
        -- "Evil NPC" (the faction Brawl's encounters use); applied at once when
        -- you are not in a fight, otherwise once they have joined yours (or
        -- after merge_wait_s), so a running fight doesn't split.
        faction = "64321d50-d516-b1b2-cfac-2eb773de1ff6",
        merge_wait_s = 10,
        -- Anyone still out of the fight this long after the spawn is pulled
        -- in again (a few tries).
        recheck_s = 2.0, recheck_tries = 2,
        -- reach_check_s after the spawn, a goblin with no path to you (in or
        -- behind a wall: playtest 2026-10-12) is moved relocate_m from you
        -- (ranged ones relocate_ranged_m).
        reach_check_s = 3.0, relocate_m = 4.0, relocate_ranged_m = 9.0,
    },
}
