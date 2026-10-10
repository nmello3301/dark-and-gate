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
    -- Per-spell `cast_time_s` overrides this. Later: scale with traits.
    cast_time_s = 2.0,
    -- The server accepts a release this much earlier than cast_time_s
    -- (network latency between the arm and the cast messages).
    cast_time_tolerance_s = 0.25,
    -- While the cast time runs (spell selected, not ready yet) and the
    -- caster is on the ground, movement speed x this (Movement modifier
    -- "casting"). Once the spell is ready to release: full speed.
    casting_speed_mult = 0.7,

    -- Shooting spells (unlimited_range = true) fly toward the crosshair at
    -- any distance: the aim point is up to aim_far_m away along the view,
    -- and the spell's own TargetRadius stat is raised to stat_range_m at
    -- stats load (Shared/SpellRange.lua) so BG3 doesn't refuse or walk
    -- you into range. BG3's 18 m felt wrong in first person.
    aim_far_m    = 100,
    stat_range_m = 100,

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
            range_m    = 36,
            label      = "Fire Bolt",
            icon       = nil,
        },
        Projectile_Fireball = {
            kind       = "point",     -- held-key ground preview; stub this pass
            unlimited_range = true,
            level      = 3,
            cost       = 32,
            cooldown_ms = 1500,
            range_m    = 36,
            label      = "Fireball",
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
