-- Spike 7: freeze a single character's animation for a few frames (hit stop).
--
-- Design calls for 2-4 frames of per-character freeze on heavy hits. Three
-- Lua levers we try, in order of likelihood:
--   1. Set the character's animation playback speed to 0 for N ms via
--      AnimationSet.PlaySpeed (same lever spike 4 probes).
--   2. Apply a short-lived status (e.g. STUNNED for 100ms) and see if the
--      engine honors fractional seconds on status durations.
--   3. Direct write of a `TimescaleOverride` component if one exists.
--
-- If none work, the native plugin picks up a `FreezeCharacter(entity, ms)`
-- call that pokes the animation subsystem directly.

local Log = Ext.Require("Shared/Log.lua")
local MCM = Ext.Require("Shared/MCM.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

local function enabled() return MCM.Get("spike7") == true end

-- Same component/field matrix as Spike4; see its header for the 2026-10-08
-- finding that AnimationSetComponent has no PlaySpeed. We still probe in
-- case another component in the matrix accepts a timescale write.
local SPEED_FIELD_CANDIDATES = { "PlaySpeed", "Speed", "Rate", "TimeScale", "PlaybackRate" }
local ANIM_COMPONENT_NAMES   = { "AnimationSet", "AnimationBlueprint", "Animation", "ActiveAnimationSlots" }

local function freezeLocal(durationMs)
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ClientControl") or {}
    Log.Write("Spike7: ClientControl entities found=" .. #ents)
    for ei, ent in ipairs(ents) do
        for _, compName in ipairs(ANIM_COMPONENT_NAMES) do
            local okComp, comp = pcall(function() return ent[compName] end)
            Log.Write(string.format("Spike7: ent[%d].%s present=%s",
                ei, compName, tostring(okComp and comp ~= nil)))
            if okComp and comp then
                for _, field in ipairs(SPEED_FIELD_CANDIDATES) do
                    local okR, before = pcall(function() return comp[field] end)
                    if okR then
                        local okW = pcall(function() comp[field] = 0 end)
                        Log.Write(string.format(
                            "Spike7: %s.%s before=%s wrote=0 ok=%s",
                            compName, field, tostring(before), tostring(okW)))
                        if okW then
                            local saved = before
                            Ext.Timer.WaitFor(durationMs, function()
                                pcall(function() comp[field] = saved or 1.0 end)
                                Log.Write(string.format(
                                    "Spike7: %s.%s restored to %s",
                                    compName, field, tostring(saved or 1.0)))
                            end)
                        end
                    end
                end
            end
        end
    end
end

function M.Register()
    MCM.DefineBool("spike7", false, "Spike 7: per-character hit stop")
    MCM.RegisterToggleCommand("dag_spike7", "spike7")

    Ext.RegisterConsoleCommand("dag7_freeze", function(_, msArg)
        if not enabled() then Log.Write("Spike7: disabled; !dag_spike7 on"); return end
        local ms = tonumber(msArg) or 100
        Log.Write("Spike7: freeze local " .. ms .. "ms (client-local path)")
        freezeLocal(ms)
        -- Also exercise the net path so the server records the intent.
        local target = nil
        local okReq, S2 = pcall(Ext.Require, "Spikes/Spike2_AimRay.lua")
        if okReq and type(S2) == "table" and type(S2.GetLastHitUuid) == "function" then
            local ok, u = pcall(S2.GetLastHitUuid); if ok then target = u end
        end
        if target then ClientNet.HitStop(target, ms) end
    end)

    Log.Write("Spike7: registered (MCM spike7, cmd dag7_freeze [ms])")
end

return M
