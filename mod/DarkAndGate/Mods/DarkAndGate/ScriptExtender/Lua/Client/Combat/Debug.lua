-- SPDX-License-Identifier: GPL-3.0-or-later
-- Debug console commands for M1b:
--   !dag_mana [refill]        print state; refill drains server to full
--   !dag_hotbar <slot> <id>   assign a spell to a slot
--   !dag_hotbar_reset         reset to DEV-SAVE defaults
--   !dag_swing_debug on/off   log the per-sample ray fan
--   !dag_rt on/off            toggle real-time combat (default on)
--   !dag_spawn_dummy          server spawns a goblin dummy 3m +X of player
--   !dag_pov_on               thin wrapper that also sets State.povOn so
--                             the HUD + input know POV is active.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

function M.Register()
    Ext.RegisterConsoleCommand("dag_mana", function(_, arg)
        if arg == "refill" or arg == "full" then
            ClientNet.Send(Net.Channels.ManaRefill, {})
            Log.Write("Mana: refill requested")
        else
            Log.Write(string.format("Mana: %d / %d  +%.1f/s",
                math.floor(State.mana.current),
                math.floor(State.mana.max),
                State.mana.regen))
        end
    end)

    Ext.RegisterConsoleCommand("dag_swing_debug", function(_, arg)
        State.swingDebug = (arg == "on" or arg == "1")
        Log.Write("Swing debug: " .. (State.swingDebug and "ON" or "OFF"))
    end)

    Ext.RegisterConsoleCommand("dag_rt", function(_, arg)
        State.realTime = not (arg == "off" or arg == "0")
        Log.Write("Real-time combat: " .. (State.realTime and "ON" or "OFF"))
    end)

    Ext.RegisterConsoleCommand("dag_spawn_dummy", function()
        ClientNet.Send(Net.Channels.SpawnDummy, {})
        Log.Write("SpawnDummy: requested")
    end)

    -- Short-circuit the arm-then-LMB UX: fire the current slot-1 spell
    -- (default Target_FireBolt) at the crosshair target right now. Lets
    -- the user confirm the full cast pipeline works without needing the
    -- hotkey arming to be running correctly first.
    Ext.RegisterConsoleCommand("dag_fire_test", function()
        local Spells = Ext.Require("Client/Combat/Spells.lua")
        Spells.Cast("Target_FireBolt")
        Log.Write("fire_test: Target_FireBolt cast attempt (see client.log for NO TARGET IN SIGHT or Spells: request)")
    end)

    -- Fire any spell id at the crosshair.
    Ext.RegisterConsoleCommand("dag_cast", function(_, id)
        if not id or id == "" then
            Log.Write("usage: !dag_cast <spellId>"); return
        end
        local Spells = Ext.Require("Client/Combat/Spells.lua")
        Spells.Cast(id)
    end)

    -- Fire one swing on command (bypasses mouse-look gate so the user can
    -- test the swing path when stuck in UI mode).
    Ext.RegisterConsoleCommand("dag_swing_test", function()
        local Swing = Ext.Require("Client/Combat/Swing.lua")
        Swing.OnLMB()
        Log.Write("swing_test: swing fired (see Swing: start + first sample)")
    end)

    -- Server echoes result so a client.log paste shows what happened —
    -- the user's first playtest reported "nothing printed" because the
    -- only outcome log was in server.log.
    Ext.RegisterNetListener(Net.Channels.SpawnDummyReply, function(_, payload)
        local ok, parsed = pcall(Ext.Json.Parse, payload)
        if not ok then
            Log.Write("SpawnDummy reply: bad JSON")
            return
        end
        if parsed.ok then
            local t = parsed.template or {}
            local p = parsed.pos      or {}
            Log.Write(string.format(
                "SpawnDummy reply: OK uuid=%s template=%s tier=%s type=%s at (%.2f, %.2f, %.2f)",
                tostring(parsed.uuid), tostring(t.name), tostring(t.tier),
                tostring(t.type),
                p.x or 0, p.y or 0, p.z or 0))
        else
            Log.Write("SpawnDummy reply: FAIL reason=" .. tostring(parsed.reason))
            if parsed.template then
                Log.Write(string.format("  tried: name=%s uuid=%s type=%s",
                    tostring(parsed.template.name),
                    tostring(parsed.template.uuid),
                    tostring(parsed.template.type)))
            end
            for i, c in ipairs(parsed.top or {}) do
                Log.Write(string.format("  cand[%d] name=%s uuid=%s type=%s",
                    i, tostring(c.name), tostring(c.uuid), tostring(c.type)))
            end
        end
    end)

    -- Fast diagnostic: dumps every input gate + spell state at once.
    -- Fires without needing a playtest, so a silent input gate shows up
    -- immediately instead of after someone has swung at a dummy.
    Ext.RegisterConsoleCommand("dag_combat_status", function()
        local active = State:IsCombatActive()
        Log.Write(string.format(
            "Combat status: povOn=%s realTime=%s inFight=%s armedSpell=%s mana=%d/%d IsCombatActive=%s lastInput=%s",
            tostring(State.povOn), tostring(State.realTime), tostring(State.inFight),
            tostring(State.armedSpell),
            math.floor(State.mana.current), math.floor(State.mana.max),
            tostring(active),
            tostring(State.lastInputEvent)))
    end)

    Log.Write("Combat Debug: registered")
end

return M
