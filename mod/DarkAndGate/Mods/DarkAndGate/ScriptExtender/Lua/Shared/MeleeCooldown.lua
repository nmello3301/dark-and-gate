-- SPDX-License-Identifier: GPL-3.0-or-later
-- Melee cooldown (DECISIONS 2026-10-13): one swing per cooldown, counted
-- from swing start to swing start, so LMB spam can't out-swing a fight.
-- The client gates LMB with it (Client/Combat/Swing.lua); the server
-- rejects hits from a swing that started sooner than it allows
-- (Server/Combat/HitValidator.lua).
--
-- Seconds(weapon) = base (data/combat.lua melee.cooldown_s, or the live
-- !dag_melee_cooldown value) x the weapon's cooldown_mult. Future scaling
-- (weapon families, attack-speed stats, perks, encumbrance) plugs in here;
-- the options are listed in docs/DESIGN.md "Melee cooldown".

local combat = Ext.Require("data/combat.lua")

local M = {}

-- HitClaim.weapon names -> weapon data.
local weapons = {
    longsword = Ext.Require("data/weapons/longsword.lua"),
}

local override = nil   -- seconds, !dag_melee_cooldown

function M.Base() return override or combat.melee.cooldown_s end

-- weapon: a weapon data table or its name (HitClaim.weapon).
function M.Seconds(weapon)
    if type(weapon) == "string" then weapon = weapons[weapon] end
    local mult = type(weapon) == "table" and tonumber(weapon.cooldown_mult) or 1.0
    return math.max(0, M.Base() * mult)
end

-- A click this close to the end of the cooldown waits and swings on time.
function M.Buffer() return combat.melee.buffer_s or 0 end

-- Server: a new swing's first hit may arrive this much sooner than the
-- cooldown (windup and hit-timing differences between swings, lag).
function M.ServerSlack() return combat.melee.server_slack_s or 0 end

-- Live tuning. The client command runs this on both sides
-- (ConsoleForward.Local + the forward to the server).
function M.Set(s)
    s = tonumber(s)
    if s and s >= 0 then override = s end
    return M.Base()
end

return M
