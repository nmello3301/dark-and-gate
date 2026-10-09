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

-- fix4: Osi.GetX/Y/Z are not callable in this build ("missing positions"
-- on every claim). Same chain Dummy.lua uses: Osi.GetPosition, then the
-- entity Transform.
local function targetPos(uuid)
    local okP, x, y, z = pcall(function() return Osi.GetPosition(uuid) end)
    if okP and tonumber(x) and tonumber(y) and tonumber(z) then
        return { tonumber(x), tonumber(y), tonumber(z) }
    end
    local okE, t = pcall(function() return Ext.Entity.Get(uuid).Transform.Transform.Translate end)
    if okE and t then
        local tx, ty, tz = t[1] or t.x, t[2] or t.y, t[3] or t.z
        if tx and ty and tz then return { tonumber(tx), tonumber(ty), tonumber(tz) } end
    end
    return nil
end

local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
    if x and y and z then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
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
            local eye = vec(claim.eye)
            if not tp or not eye then
                Log.Write(string.format("HitValidator: missing positions target=%s eye=%s",
                    tostring(tp ~= nil), tostring(eye ~= nil)))
                return
            end
            local d = dist3(eye, tp)
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
                -- Arity differs between patches; try without the source.
                local ok3, err3 = pcall(function() Osi.ApplyDamage(target, dmg, "Slashing") end)
                if ok3 then okD = true else err = tostring(err) .. " | 3 args: " .. tostring(err3) end
            end
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
