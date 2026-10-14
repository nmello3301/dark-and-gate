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
-- fix3: the modal-UI part (3 entity queries) is cached for 250 ms; it
-- used to run on every input event and every HUD tick.
local MPState = Ext.Require("Shared/MPState.lua")
local modalCache = { at = -1e9, modal = false }
local function modalOpen()
    local now = tonumber(Ext.Timer.MonotonicTime()) or 0
    if now - modalCache.at < 250 then return modalCache.modal end
    modalCache.at = now
    local modal = false
    -- Co-op: another player's dialogue is not ours; the server's per-player
    -- scene message (sceneOn) covers ours (multiplayer MP-3).
    if MPState.Multi() then modalCache.modal = false; return false end
    for _, c in ipairs({ "Dialog", "Cinematic", "Cutscene" }) do
        local ok, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok and es and #es > 0 then modal = true; break end
    end
    modalCache.modal = modal
    return modal
end

-- A dialogue / cutscene the server reported (Server/Scene.lua): our HUD and
-- input stand aside (playtest 2026-10-13: the HUD blocked the opening scene).
M.sceneOn = false
-- The party gave up and BG3's game-over screen is up (Client/Downed.lua):
-- the same, until the next load resets the Lua state.
M.gameOver = false

function M.IsCombatActive()
    if not M.povOn or M.sceneOn or M.gameOver then return false end
    return not modalOpen()
end

-- Is first-person mouse-look currently on (cursor hidden, camera rotating)?
-- The DLL writes "toggled=1|0" into native-pov-status.txt every 500 ms;
-- MMB flips it. When it is off the cursor is visible and Input.lua lets
-- LMB / RMB through to the vanilla UI. Re-read at most every 200 ms.
-- If the status file is missing or unreadable we assume ON (combat mode).
local POV_STATUS_PATH = "DarkAndGate/native-pov-status.txt"
local mlCache = { at = -1e9, on = true }
function M.MouseLookOn()
    local now = tonumber(Ext.Timer.MonotonicTime()) or 0
    if now - mlCache.at > 200 then
        mlCache.at = now
        local ok, s = pcall(Ext.IO.LoadFile, POV_STATUS_PATH)
        if ok and s then
            local t = s:match("toggled=(%d)")
            if t then mlCache.on = (t == "1") end
        end
    end
    return mlCache.on
end

return M
