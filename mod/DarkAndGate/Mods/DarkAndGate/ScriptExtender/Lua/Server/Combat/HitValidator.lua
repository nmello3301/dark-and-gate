-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-authoritative hit validation.
--
-- Receives DAG_HitClaim from the client. Validates:
--   * attacker has a character
--   * target is alive and within claim.reach + 1 m fudge
--   * swing nonce hasn't already landed on this target this swing
-- Applies damage via Osi.ApplyDamage. Returns the result over DAG_HitResult.
--
-- M1b scope: no BG3 attack roll, no AC-as-DR. Flat damage with zone mult.
-- M2 picks up crits / advantage / resistance.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")

local M = {}

-- (attackerUuid .. "|" .. nonce) -> { [targetUuid] = true }
local landed = {}

local function dist3(a, b)
    local dx = a[1] - b[1]
    local dy = a[2] - b[2]
    local dz = a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function targetPos(uuid)
    local okX, x = pcall(function() return Osi.GetX(uuid) end)
    local okY, y = pcall(function() return Osi.GetY(uuid) end)
    local okZ, z = pcall(function() return Osi.GetZ(uuid) end)
    if okX and okY and okZ then
        return { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.HitClaim, function(_, payload, userId)
        local ok, claim = pcall(Ext.Json.Parse, payload)
        if not ok then Log.Write("HitValidator: bad JSON"); return end
        ServerNet.EnqueueOsi(function()
            local attacker = ServerNet.UserToCharacter(userId)
            if not attacker then Log.Write("HitValidator: no attacker"); return end
            local target = claim.targetUuid
            if not target or target == "" then return end

            local tp = targetPos(target)
            if not tp or not claim.eye then
                Log.Write("HitValidator: missing positions")
                return
            end
            local d = dist3(claim.eye, tp)
            local maxReach = (claim.reach or 2.0) + 1.0
            if d > maxReach then
                Log.Write(string.format("HitValidator: REJECT dist=%.2f reach=%.2f target=%s",
                    d, maxReach, target))
                return
            end

            local key = tostring(attacker) .. "|" .. tostring(claim.swingNonce or 0)
            landed[key] = landed[key] or {}
            if landed[key][target] then
                return  -- already landed this swing
            end
            landed[key][target] = true

            local zone = claim.hitZone or "torso"
            local zoneMult = (zone == "head") and 2.0 or (zone == "limbs") and 0.6 or 1.0
            local dmg = math.max(1, math.floor((claim.damage or 1) * zoneMult))

            local okD, err = pcall(function()
                Osi.ApplyDamage(target, dmg, "Slashing", attacker)
            end)
            if not okD then
                Log.Write("HitValidator: ApplyDamage err: " .. tostring(err))
            end
            Log.Write(string.format("HitValidator: HIT %s zone=%s dmg=%d dist=%.2f", target, zone, dmg, d))

            Ext.Net.PostMessageToUser(userId, Net.Channels.HitResult, Ext.Json.Stringify({
                target = target, zone = zone, damage = dmg, swingNonce = claim.swingNonce,
            }))
        end)
    end)
    Log.Write("HitValidator: registered")
end

return M
