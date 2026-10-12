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
-- fix2: required at load time (runtime Ext.Require inside a console
-- command is the same trap that broke Input.lua).
local Spells    = Ext.Require("Client/Combat/Spells.lua")
local Swing     = Ext.Require("Client/Combat/Swing.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")

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

    -- !dag_rt on|off|status|debug: Brawl's loop runs on the server
    -- (Server/BrawlAdapter.lua); typed here it is forwarded there.
    Ext.RegisterConsoleCommand("dag_rt", function(_, arg, arg2)
        if arg == "on" or arg == "off" or arg == "1" or arg == "0" then
            State.realTime = not (arg == "off" or arg == "0")
        end
        ClientNet.Send(Net.Channels.ServerCommand, { cmd = "dag_rt", args = { arg, arg2 } })
        Log.Write("Real-time combat: !dag_rt " .. tostring(arg or "status") .. " -> server (client flag " .. (State.realTime and "ON" or "OFF") .. ")")
    end)

    -- !dag_spawn_dummy [hostile] [name-filter]
    --   default: an adult Act 1 goblin, left non-hostile so BG3 does not
    --   flip into turn-based combat while we test real-time hits.
    --   "hostile": also put it in the Evil NPC faction (it will fight).
    --   name-filter: pick the first template whose name contains it.
    --   "moving": it walks back and forth across your view (data/
    --   projectiles.lua moving_dummy), to practise leading projectiles.
    Ext.RegisterConsoleCommand("dag_spawn_dummy", function(_, a, b, c)
        local hostile, moving, filter = false, false, nil
        for _, v in ipairs({ a, b, c }) do
            if v == "hostile" then hostile = true
            elseif v == "moving" then moving = true
            elseif v and v ~= "" then filter = v end
        end
        local fwd = nil
        pcall(function()
            local _, f = Aim.ReadInvView()
            if f then fwd = { x = f[1], y = f[2], z = f[3] } end
        end)
        ClientNet.Send(Net.Channels.SpawnDummy, { hostile = hostile, filter = filter, moving = moving, fwd = fwd })
        Log.Write(string.format("SpawnDummy: requested hostile=%s moving=%s filter=%s", tostring(hostile), tostring(moving), tostring(filter)))
    end)

    -- !dag_dummy_list [filter]  server logs up to 25 candidate templates.
    Ext.RegisterConsoleCommand("dag_dummy_list", function(_, filter)
        ClientNet.Send(Net.Channels.SpawnDummy, { list = true, filter = filter })
        Log.Write("SpawnDummy: list requested filter=" .. tostring(filter))
    end)

    -- Short-circuit the arm-then-LMB UX: fire the current slot-1 spell
    -- (default Projectile_FireBolt) at the crosshair target right now. Lets
    -- the user confirm the full cast pipeline works without needing the
    -- hotkey arming to be running correctly first.
    Ext.RegisterConsoleCommand("dag_fire_test", function()
        Spells.Cast("Projectile_FireBolt")
        Log.Write("fire_test: Projectile_FireBolt cast attempt")
    end)

    -- Fire any spell id at the crosshair.
    Ext.RegisterConsoleCommand("dag_cast", function(_, id)
        if not id or id == "" then
            Log.Write("usage: !dag_cast <spellId>"); return
        end
        Spells.Cast(id)
    end)

    -- fix5: if Gale gets stuck (can't walk) after an animation, this asks
    -- the server to purge his action queue.
    Ext.RegisterConsoleCommand("dag_unstick", function()
        ClientNet.PlayAnim("__unstick__")
        Log.Write("Unstick: requested (server purges Gale's action queue)")
    end)

    -- Fire one swing on command (bypasses mouse-look gate so the user can
    -- test the swing path when stuck in UI mode).
    Ext.RegisterConsoleCommand("dag_swing_test", function()
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
        if parsed.list then
            Log.Write(string.format("SpawnDummy list: %d candidates (filter=%s)",
                #(parsed.list), tostring(parsed.filter)))
            for i, c in ipairs(parsed.list) do
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
