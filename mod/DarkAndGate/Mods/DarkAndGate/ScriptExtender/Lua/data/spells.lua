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
    -- Cost table by spell level (index 0..6).
    cost_by_level = { [0] = 0, [1] = 10, [2] = 20, [3] = 32, [4] = 45, [5] = 60, [6] = 80 },

    -- Per-spell overrides. Keys are the Osi spell identifier (first arg to
    -- Osi.UseSpell / UseSpellAtPosition). "kind" affects how the client
    -- aims and the server routes:
    --   target: resolve via raycast to a character; else to self
    --   point:  cast at a world point (projectile travels there)
    --   teleport: move caster to a world point
    spells = {
        Target_FireBolt = {
            kind       = "target",
            level      = 0,
            cost       = 0,
            cooldown_ms = 400,
            label      = "Fire Bolt",
            icon       = nil,
        },
        Projectile_Fireball = {
            kind       = "point",     -- held-key ground preview; stub this pass
            level      = 3,
            cost       = 32,
            cooldown_ms = 1500,
            label      = "Fireball",
        },
        Target_MistyStep = {
            kind       = "teleport",   -- stub: cast via UseSpell on self for now
            level      = 2,
            cost       = 20,
            cooldown_ms = 1500,
            label      = "Misty Step",
        },
    },

    -- Default DEV-SAVE hotbar: 10 slots, index 1 == key 1.
    default_hotbar = {
        [1] = "Target_FireBolt",
        [2] = "Projectile_Fireball",
        [3] = "Target_MistyStep",
    },
}
