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
    realTime = true,

    mana = { max = 60, current = 60, regen = 1.0 },

    -- Slots 1..10. Values are spell ids (from data/spells.lua .spells
    -- keys) or nil.
    hotbar = {},

    -- Cooldowns by spell id -> ms-at-ready.
    cooldownUntil = {},

    -- Current swing data (set by Swing.lua while a chain is live).
    currentSwing = nil,
    swingNonceCounter = 0,
}

function M.NextSwingNonce()
    M.swingNonceCounter = (M.swingNonceCounter + 1) % 1e9
    return M.swingNonceCounter
end

function M.IsCombatActive()
    -- Combat gameplay = POV on AND real-time combat enabled AND no modal UI.
    if not M.povOn then return false end
    if not M.realTime then return false end
    -- Modal UI check: Dialog / Cinematic entities exist iff a scene is up.
    for _, c in ipairs({ "Dialog", "Cinematic", "Cutscene" }) do
        local ok, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok and es and #es > 0 then return false end
    end
    return true
end

return M
