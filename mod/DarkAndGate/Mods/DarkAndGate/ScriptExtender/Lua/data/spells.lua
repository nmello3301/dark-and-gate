-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spell tuning: mana cost by level + the three M1b spells.
--
-- Mana pool math (server, from DESIGN.md):
--   max   = 30 + 10*CL + 5*M
--   regen = 0.5 + 0.1*CL + 0.1*M per second
--   cost by spell level: 0, 10, 20, 32, 45, 60, 80
--
-- M = spellcasting modifier (INT for wizards, WIS clerics, CHA warlocks/bards).
-- Resolved at cast time from Osi.GetAbility(caster, "<Ability>").

return {
    -- Channelled casting (2026-10-09): selecting a hotbar spell starts
    -- casting (its prepare animation plays and loops); LMB releases it,
    -- but only once cast_time_s has passed. Held as long as you like.
    -- Per-spell `base_cast_s` overrides this. The effective cast time is
    -- base x the product of Spells.AddCastTimeModifier factors (future
    -- traits); !dag_cast_time <s> overrides the base for the session.
    base_cast_s = 2.0,
    -- The server accepts the client's effective cast time down to this
    -- (modifiers are client-side until traits exist server-side).
    min_cast_s = 0.3,
    -- The server accepts a release this much earlier than cast_time_s
    -- (network latency between the arm and the cast messages).
    cast_time_tolerance_s = 0.25,
    -- While the cast time runs (spell selected, not ready yet) and the
    -- caster is on the ground, movement speed x this (Movement modifier
    -- "casting"). Once the spell is ready to release: full speed.
    casting_speed_mult = 0.7,

    -- Spell ranges in first person (developer 2026-10-12, DECISIONS; BG3's
    -- 18 m felt wrong in first person). Each spell gets the range of its
    -- class (Shared/SpellRange.lua):
    --   shot_range_m   it flies at, or hits, one target: Fire Bolt, Ray of
    --                  Frost, Guiding Bolt, Magic Missile, Sacred Flame, Hold
    --                  Person, Healing Word... and arrows / bolts
    --                  (Client/Combat/Bow.lua, data/projectiles.lua)
    --   area_range_m   it covers an area or several picked targets: Fireball,
    --                  Grease, Fog Cloud, Sleep, Bless, walls...
    --   touch_max_m    a spell whose BG3 range is this or less (touch, melee
    --                  spells) keeps it
    -- The spell's TargetRadius stat is raised to its class range at stats
    -- load, so BG3 casts it that far instead of refusing or walking you into
    -- range; a range is never lowered. Teleports (Misty Step), cones / zones
    -- from the caster and shouts keep BG3's data. NPCs and companions still
    -- walk to BG3's own range before they cast (Server/BrawlAdapter.lua).
    -- Shooting spells (unlimited_range = true, our projectile flight) fly
    -- along the crosshair line up to their range; an area spell lands where
    -- its ring shows (Client/Combat/Targeting.lua), at most area_range_m away.
    shot_range_m = 70,
    area_range_m = 30,
    touch_max_m  = 3,

    -- Spell animations (Client/Combat/SpellAnims.lua): each spell's own
    -- SpellAnimation slots (0 prepare, 4 loop, 2 cast, 3 recover). A slot
    -- the caster can't resolve uses this family (Fire Bolt's, mapping ids,
    -- so every rig resolves its own version).
    spell_anims = {
        fallback = {
            prepare = "3ff87abf-1ea1-4c32-aadf-c822d74c7dc0",
            loop    = "d8925ce4-d6d9-400c-92f5-ad772ef7f178",
            cast    = "38cdb41c-2eec-4e03-bb31-83cff0346c35",
            recover = "85414f5f-b448-4dda-9370-1b6c4b38b561",
            cancel  = "eadedcce-d01b-4fbb-a1ae-d218f13aa5d6",  -- slot 6, played on cancel
        },
        -- Prepare VFX + sounds from the spell's stats (PrepareEffect,
        -- PrepareSound, PrepareLoopSound), played while channelling
        -- (Client/Combat/SpellFx.lua). stop_sounds: at cast / cancel, stop
        -- the sounds on the caster's sound object (also cuts any other
        -- sound playing on it at that instant).
        fx = { effect = true, sounds = true, stop_sounds = true },
        -- Weapon stance on arm, by the spell's Sheathing stat (empty =
        -- "default"). OFF (2026-10-10 playtest): vanilla Fire Bolt does NOT
        -- draw the staff (hand gestures only), so the stance was not why our
        -- prepare looked different.
        -- immediate: no draw animation (it would compete with the prepare).
        -- wait_s: the client holds the prepare event up to this long until
        -- the weapon is out, so the right clip is picked.
        -- Casting animation set like vanilla targeting (Client/Combat/
        -- CastTags.lua): type-1 copies of the character's tags that have an
        -- OverrideType 1 waterfall set. wait_s: the select event waits this
        -- long at most for the set to be in place. *_hold_s: kept after the
        -- release so cast / recover / stow come from the same set.
        -- force_set: also write the override sets into AnimationSet directly
        -- (the engine didn't rebuild it from the Lua-written tag).
        cast_tags = { enabled = true, force_set = true, wait_s = 0.5, cast_hold_s = 3.0, cancel_hold_s = 1.2 },
        unsheath = {
            enabled = false,
            default = "unsheath", Melee = "unsheath", Somatic = "unsheath", WeaponSet = "unsheath",
            Sheathed = "sheath", DontChange = "none", Ranged = "none", Instrument = "none",
            immediate = true, wait_s = 0.4,
        },
        cast_rate = 1.0,           -- play rate of the cast clip (per spell: spells[id].cast_rate)
        fire_point = "cast_start", -- "cast_start" | "cast_event" (text-key, when found)
    },

    -- Cost table by spell level (index 0..6).
    cost_by_level = { [0] = 0, [1] = 10, [2] = 20, [3] = 32, [4] = 45, [5] = 60, [6] = 80 },

    -- Per-spell overrides. Keys are the Osi spell identifier (first arg to
    -- Osi.UseSpell / UseSpellAtPosition). "kind" affects how the client
    -- aims and the server routes:
    --   target: resolve via raycast to a character; else to self
    --   point:  cast at a world point (projectile travels there)
    --   teleport: move caster to a world point
    spells = {
        -- fix3: BG3's Fire Bolt is Projectile_FireBolt. "Target_FireBolt"
        -- does not exist, which is why spike 5 saw nothing happen.
        Projectile_FireBolt = {
            kind       = "target",    -- character under crosshair, else ground point
            unlimited_range = true,
            level      = 0,
            cost       = 0,
            cooldown_ms = 400,
            label      = "Fire Bolt",       -- range: shot_range_m
            icon       = nil,
        },
        Projectile_Fireball = {
            kind       = "point",     -- held-key ground preview; stub this pass
            unlimited_range = true,
            level      = 3,
            cost       = 32,
            cooldown_ms = 1500,
            label      = "Fireball",        -- range: area_range_m
        },
        Target_MistyStep = {
            kind       = "teleport",   -- stub: cast via UseSpell on self for now
            level      = 2,
            cost       = 20,
            cooldown_ms = 1500,
            range_m    = 18,
            label      = "Misty Step",
        },
    },

    -- Default DEV-SAVE hotbar: 10 slots, index 1 == key 1.
    default_hotbar = {
        [1] = "Projectile_FireBolt",
        [2] = "Projectile_Fireball",
        [3] = "Target_MistyStep",
    },
}
