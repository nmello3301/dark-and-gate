-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared client-side combat state: whether POV is on, whether we should
-- capture gameplay inputs, mana pool from server, hotbar slot bindings,
-- debug flags.
--
-- POV state is tracked by watching the pov status file the DLL writes
-- (and FullPov.lua) — we don't want a direct reference back into
-- FullPov.lua to avoid a dependency cycle.

local M = {
    povOn = false,
    swingDebug = false,
    -- realTime and inFight are tracked for !dag_combat_status, but
    -- are NOT part of IsCombatActive() — the user wants LMB swing /
    -- RMB block / 1-0 hotbar to work in first person outside combat
    -- too, so training-dummy tests work before the goblin fight.
    realTime = true,
    inFight  = false,

    mana = { max = 60, current = 60, regen = 1.0 },

    -- Slots 1..10. Values are spell ids (from data/spells.lua .spells
    -- keys) or nil.
    hotbar = {},

    -- Cooldowns by spell id -> ms-at-ready.
    cooldownUntil = {},

    -- Current swing data (set by Swing.lua while a chain is live).
    currentSwing = nil,
    swingNonceCounter = 0,

    -- Arm-then-cast (HARD mode): number key -> armedSpell = id.
    -- LMB casts the armed spell (no swing while armed). RMB tap or
    -- re-pressing the same number cancels.
    armedSpell = nil,

    -- RMB block (stub).
    blocking = false,

    -- One-line "last input seen" string for !dag_combat_status, so a
    -- silent input gate is debuggable without a playtest.
    lastInputEvent = "(none)",
}

function M.NextSwingNonce()
    M.swingNonceCounter = (M.swingNonceCounter + 1) % 1e9
    return M.swingNonceCounter
end

-- Input gate: POV on AND no modal UI. Does NOT depend on realTime or
-- inFight (see above — needed for dummy tests before the goblin fight).
function M.IsCombatActive()
    if not M.povOn then return false end
    for _, c in ipairs({ "Dialog", "Cinematic", "Cutscene" }) do
        local ok, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok and es and #es > 0 then return false end
    end
    return true
end

return M
