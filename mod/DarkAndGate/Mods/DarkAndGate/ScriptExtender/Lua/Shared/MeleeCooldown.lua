-- SPDX-License-Identifier: GPL-3.0-or-later
-- Melee cooldown (DECISIONS 2026-10-13): one swing per cooldown, counted
-- from swing start to swing start, so LMB spam can't out-swing a fight.
-- The client gates LMB with it (Client/Combat/Swing.lua); the server
-- rejects hits from a swing that started sooner than it allows
-- (Server/Combat/HitValidator.lua).
--
-- Seconds(weapon, uuid) = base (data/combat.lua melee.cooldown_s, or the
-- live !dag_melee_cooldown value) x the weapon's cooldown_mult x the
-- character's DEX curve (Meta-Points attack_cooldown), floored at
-- min_action_interval. Other scaling (weapon families, perks, encumbrance)
-- plugs in here; the options are listed in docs/DESIGN.md "Melee cooldown".
--
-- SwingRate (decision 2026-10-15): once the cooldown is shorter than the
-- swing itself (windup + active + recovery), the swing and its clip play
-- that much faster, so DEX keeps mattering (at most melee.max_swing_rate).

local combat = Ext.Require("data/combat.lua")
local MetaPoints = Ext.Require("Shared/MetaPoints.lua")

local M = {}

-- HitClaim.weapon names -> weapon data.
local weapons = {
    longsword = Ext.Require("data/weapons/longsword.lua"),
}

local override = nil   -- seconds, !dag_melee_cooldown

function M.Base() return override or combat.melee.cooldown_s end

-- weapon: a weapon data table or its name (HitClaim.weapon); uuid: the
-- swinging character (nil = no Meta-Points).
function M.Seconds(weapon, uuid)
    if type(weapon) == "string" then weapon = weapons[weapon] end
    local mult = type(weapon) == "table" and tonumber(weapon.cooldown_mult) or 1.0
    local s = math.max(0, M.Base() * mult)
    if uuid then s = MetaPoints.Floor(s * MetaPoints.Mult(uuid, "attack_cooldown")) end
    return s
end

-- How much faster a swing of swingMs plays under a cooldown of cooldownS.
function M.SwingRate(cooldownS, swingMs)
    swingMs = tonumber(swingMs) or 0
    local cd = (tonumber(cooldownS) or 0) * 1000
    if swingMs <= 0 or cd >= swingMs then return 1.0 end
    local maxRate = tonumber(combat.melee.max_swing_rate) or 4.0
    if cd <= 0 then return maxRate end
    return math.min(maxRate, swingMs / cd)
end

-- A click this close to the end of the cooldown waits and swings on time.
function M.Buffer() return combat.melee.buffer_s or 0 end

-- Server: a new swing's first hit may arrive this much sooner than the
-- cooldown (windup and hit-timing differences between swings, lag). With a
-- cooldown given, at most server_slack_frac of it, so the check still means
-- something for a fast (high DEX) swing.
function M.ServerSlack(cooldownS)
    local s = combat.melee.server_slack_s or 0
    if cooldownS then s = math.min(s, cooldownS * (combat.melee.server_slack_frac or 0.5)) end
    return s
end

-- Live tuning. The client command runs this on both sides
-- (ConsoleForward.Local + the forward to the server).
function M.Set(s)
    s = tonumber(s)
    if s and s >= 0 then override = s end
    return M.Base()
end

return M
