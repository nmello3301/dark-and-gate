-- SPDX-License-Identifier: GPL-3.0-or-later
-- Projectile system v1 (docs/design/projectiles.md, docs/spikes/projectiles.md).
-- Flight is ours and server-authoritative: per projectile a speed, gravity,
-- drag and a sphere radius; each server tick sweeps the sphere against the
-- world and every character's CURRENT cylinder, so hits land anywhere
-- mid-flight. The look is BG3's own projectile (a "visual" clone of the
-- spell that deals nothing), removed at our hit; the effect is an
-- instant "impact" clone of the spell applied at our hit (Osi.CreateExplosion
-- on the character, or CreateExplosionAtPosition at the point), so BG3 keeps
-- damage dice, saves, statuses and hit VFX. Mana and cast time are unchanged.

return {
    enabled = true,              -- false = old behaviour (BG3 casts the real spell at the point)

    -- Where our flight starts: "eye" = the crosshair line (what you aim at
    -- is what you hit, also in mid-air), offset a little forward / down so
    -- it doesn't start inside the camera.
    origin = "eye",
    origin_fwd_m  = 0.6,
    origin_down_m = 0.25,
    -- The visual clone is cast at a point this far along the aim line, so
    -- BG3's projectile never lands before our hit.
    visual_far_m  = 150,
    -- Our flight starts when BG3's projectile for the cast appears
    -- (OnCreate ServerProjectile, matched by caster); if none is seen
    -- within this long, it starts anyway (logged).
    launch_wait_s = 1.2,
    -- A projectile with no hit is dropped after max_range_m.
    max_range_m   = 120,
    -- Server sim step (s): each tick is split into steps of at most this.
    step_s        = 1 / 60,
    -- Characters are candidates when within this of the flight segment.
    candidate_pad_m = 3.0,
    -- Caster immunity right after launch (s).
    self_grace_s  = 10.0,

    -- Client probe: move the client-side projectile's Visual onto our path
    -- every tick (Lua SetWorldTranslate; the DLL route comes after this probe).
    client_steer  = true,

    -- Per spell. speed_mps = "template" reads InitialSpeed from the spell's
    -- projectile template (Trajectories), falling back to fallback_speed_mps.
    -- impact_mode: "target" = CreateExplosion on the hit character (world
    -- hits use the point), "point" = always CreateExplosionAtPosition.
    -- visual / impact: stats overrides on the clones (BG3 stats syntax).
    spells = {
        Projectile_FireBolt = {
            speed_mps = "template", fallback_speed_mps = 30,
            gravity = 0.0, drag = 0.0, radius_m = 0.15,
            impact_mode = "target",
            visual = {
                SpellRoll = "", SpellSuccess = "", SpellFail = "", SpellProperties = "",
                TargetConditions = "", UseCosts = "", TargetRadius = "200",
            },
            impact = {
                -- Our aim decides the hit (DESIGN: spell attacks are aimed), so
                -- the attack roll goes and the damage is unconditional.
                SpellRoll = "", SpellSuccess = "",
                SpellProperties = "DealDamage(LevelMapValue(D10Cantrip),Fire,Magical);GROUND:SurfaceChange(Ignite);GROUND:SurfaceChange(Melt)",
                TargetConditions = "", UseCosts = "", TargetRadius = "200",
                ExplodeRadius = "0.6", AreaRadius = "0.6",
                add_flags = { "ImmediateCast" },
            },
        },
        Projectile_Fireball = {
            speed_mps = "template", fallback_speed_mps = 22,
            gravity = 0.0, drag = 0.0, radius_m = 0.30,
            impact_mode = "point",
            visual = {
                SpellRoll = "", SpellSuccess = "", SpellFail = "", SpellProperties = "",
                TargetConditions = "", UseCosts = "", TargetRadius = "200",
                ExplodeRadius = "0", AreaRadius = "0",
            },
            impact = {
                -- Saves stay dice (DESIGN): the Dex save, 8d6 / half, 4 m.
                UseCosts = "", TargetRadius = "200",
                add_flags = { "ImmediateCast" },
            },
        },
    },

    -- !dag_spawn_dummy moving: the dummy walks back and forth between two
    -- points this far apart, across the player's view, this far ahead.
    moving_dummy = { ahead_m = 9.0, span_m = 6.0, repath_s = 0.5, arrive_m = 0.6, movement = "Walk" },
}
