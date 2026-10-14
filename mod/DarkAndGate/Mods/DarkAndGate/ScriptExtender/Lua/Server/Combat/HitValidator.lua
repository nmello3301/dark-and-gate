-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-authoritative hit validation.
--
-- Receives DAG_HitClaim from the client. Validates:
--   * attacker has a character
--   * target is alive and within claim.reach + 1 m fudge
--   * swing nonce hasn't already landed on this target this swing
--   * melee cooldown (DECISIONS 2026-10-13): a new swing's first hit comes at
--     least the cooldown (minus server_slack_s) after the last swing's first
--     hit; a swing that came too soon lands nothing
-- Applies damage via Osi.ApplyDamage. Returns the result over DAG_HitResult.
--
-- M1b scope: no BG3 attack roll, no AC-as-DR. Flat damage with zone mult.
-- M2 picks up crits / advantage / resistance.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")
local Shields = Ext.Require("Server/Combat/Shields.lua")
local MeleeCooldown = Ext.Require("Shared/MeleeCooldown.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")

local M = {}

-- (attackerUuid .. "|" .. nonce) -> { [targetUuid] = true }
local landed = {}

-- attackerUuid -> { nonce, at = ms } of the last swing that landed a hit.
local lastSwing = {}

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

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
        local recvAt = nowMs()   -- before the Osi queue: the cooldown check times arrivals
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
            -- Reach is measured to the target's cylinder hitbox (lifted if
            -- the target is mid-jump), not to its feet.
            local cyl = Hitbox.Cylinder(target, tp)
            local d = Hitbox.Distance(cyl, eye)
            local maxReach = (claim.reach or 2.0) + Hitbox.ReachSlack()
            if d > maxReach then
                Log.Write(string.format("HitValidator: REJECT dist=%.2f reach=%.2f target=%s",
                    d, maxReach, target))
                return
            end

            -- Melee cooldown: the first hit of a new swing (new nonce) must
            -- come the cooldown (minus slack) after the last swing's first
            -- hit. More hits of the same swing pass.
            local nonce = claim.swingNonce or 0
            local last = lastSwing[attacker]
            if not last or last.nonce ~= nonce then
                local minGap = (MeleeCooldown.Seconds(claim.weapon) - MeleeCooldown.ServerSlack()) * 1000
                if last and recvAt - last.at < minGap then
                    Log.Write(string.format("HitValidator: REJECT melee cooldown: %d ms after the last swing's hit (min %d) target=%s",
                        math.floor(recvAt - last.at), math.floor(minGap), target))
                    return
                end
                lastSwing[attacker] = { nonce = nonce, at = recvAt }
            end

            local key = tostring(attacker) .. "|" .. tostring(claim.swingNonce or 0)
            landed[key] = landed[key] or {}
            if landed[key][target] then
                return  -- already landed this swing
            end
            landed[key][target] = true

            local zone = claim.hitZone or "torso"
            if zone ~= "head" and zone ~= "torso" and zone ~= "limbs" then zone = "torso" end
            local zoneMult = Hitbox.ZoneMult(zone)
            local dmg = math.max(1, math.floor((claim.damage or 1) * zoneMult))
            -- Passive shield (DECISIONS 2026-10-12): the swing's line from the
            -- eye to the hit point crosses the target's shield disc first.
            local shieldNote = ""
            local hp = vec(claim.hitPoint)
            if hp and Shields.Has(target) and Shields.Blocks(target, eye, hp, 0.05) then
                local kept, r = Shields.Reduce(dmg)
                shieldNote = string.format(" SHIELD -%.0f%% (%d -> %d)", r * 100, dmg, kept)
                dmg = math.max(0, kept)
            end

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
            Log.Write(string.format("HitValidator: HIT %s zone=%s dmg=%d dist=%.2f lift=%.2f%s", target, zone, dmg, d, cyl.lift, shieldNote))

            Ext.Net.PostMessageToUser(userId, Net.Channels.HitResult, Ext.Json.Stringify({
                target = target, zone = zone, damage = dmg, swingNonce = claim.swingNonce,
            }))
        end)
    end)
    ConsoleForward.Server("dag_melee_cooldown", function(_, v)
        MeleeCooldown.Set(v)
        Log.Write(string.format("HitValidator: melee cooldown %.2fs (hits from a swing sooner than %.2fs after the last are rejected)",
            MeleeCooldown.Base(), math.max(0, MeleeCooldown.Seconds("longsword") - MeleeCooldown.ServerSlack())))
    end)
    Log.Write(string.format("HitValidator: registered (melee cooldown %.2fs)", MeleeCooldown.Seconds("longsword")))
end

return M
