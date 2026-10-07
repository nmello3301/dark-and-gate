-- Spike 4: play a custom-speed animation and cancel at a combo point.
--
-- Three questions:
--   A. Can we trigger an animation on the local character from the client?
--   B. Can we modify its playback speed?
--   C. Can we cancel it mid-play (combo window)?
--
-- Path: Osi.PlayAnimation on the server, called via the net channel so we
-- also exercise the shared plumbing. Speed is attempted via the character's
-- GameplayLight / AnimationSetOverride components (the only speed knobs the
-- SE Lua binding exposes); if neither takes, that's the "answer: no" we're
-- probing for, and the spike result goes in docs/spikes/04-anim-control.md.
--
-- MCM toggle: dag_spike4 (default off). Console commands all gate on it.
--   !dag4_play        -- play a known animation id on the player character
--   !dag4_play_fast   -- same, with Timeline.PlaySpeed = 2.0 attempt
--   !dag4_cancel      -- immediately play a short idle to interrupt the chain

local Log = Ext.Require("Shared/Log.lua")
local MCM = Ext.Require("Shared/MCM.lua")
local Net = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

-- A placeholder animation id that we know exists in base game data. Brawl
-- uses Constants.LOOPING_COMBAT_ANIMATION_ID = "01932f4d-a39b-4ea8-96ba-aef3e6b4c2d8"
-- (confirmed in reference/Brawl/.../Server/Constants.lua if we want to swap).
-- Spike 4's goal is "does the lever work", not "pick the right clip".
local PROBE_ANIM = "01932f4d-a39b-4ea8-96ba-aef3e6b4c2d8"
local PROBE_IDLE = "48dde7b3-9f6a-4a0b-9e2a-67db9c5cd59f" -- unused slot; swap during test

local function enabled() return MCM.Get("spike4") == true end

-- Probe every component field name that could plausibly carry a playback
-- speed. All reads/writes are pcall'd because none of them are documented;
-- the spike's whole purpose is to record which (if any) take. 2026-10-08:
-- AnimationSet.PlaySpeed does not exist (SE threw "Property does not exist:
-- AnimationSetComponent::PlaySpeed"), so that lever is confirmed closed.
local SPEED_FIELD_CANDIDATES = { "PlaySpeed", "Speed", "Rate", "TimeScale", "PlaybackRate" }
local ANIM_COMPONENT_NAMES   = { "AnimationSet", "AnimationBlueprint", "Animation", "ActiveAnimationSlots" }

local function trySpeedWrite(mult)
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ClientControl")
    for _, ent in ipairs(ents) do
        for _, compName in ipairs(ANIM_COMPONENT_NAMES) do
            local okComp, comp = pcall(function() return ent[compName] end)
            if okComp and comp then
                for _, field in ipairs(SPEED_FIELD_CANDIDATES) do
                    local okR, before = pcall(function() return comp[field] end)
                    local okW = false
                    if okR then
                        okW = pcall(function() comp[field] = mult end)
                    end
                    Log.Write(string.format(
                        "Spike4: %s.%s read_ok=%s before=%s write_ok=%s",
                        compName, field, tostring(okR), tostring(before), tostring(okW)))
                end
            end
        end
    end
end

function M.Register()
    MCM.DefineBool("spike4", false, "Spike 4: animation playback")
    MCM.RegisterToggleCommand("dag_spike4", "spike4")

    Ext.RegisterConsoleCommand("dag4_play", function()
        if not enabled() then Log.Write("Spike4: disabled; !dag_spike4 on"); return end
        Log.Write("Spike4: play probe anim via net")
        ClientNet.PlayAnim(PROBE_ANIM, 1.0)
    end)

    Ext.RegisterConsoleCommand("dag4_play_fast", function()
        if not enabled() then Log.Write("Spike4: disabled"); return end
        Log.Write("Spike4: play probe anim + attempt speed 2.0")
        ClientNet.PlayAnim(PROBE_ANIM, 2.0)
        trySpeedWrite(2.0)
    end)

    Ext.RegisterConsoleCommand("dag4_cancel", function()
        if not enabled() then Log.Write("Spike4: disabled"); return end
        Log.Write("Spike4: fire interrupt animation")
        ClientNet.PlayAnim(PROBE_IDLE, 1.0)
    end)

    Log.Write("Spike4: registered (MCM spike4, cmds dag4_play / _fast / _cancel)")
end

return M
