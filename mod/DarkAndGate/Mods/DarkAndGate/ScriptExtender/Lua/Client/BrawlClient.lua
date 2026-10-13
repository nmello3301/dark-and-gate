-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client side of the real-time fights (Server/BrawlAdapter.lua). The two jobs
-- Brawl's own client did that our fights need (learned from Brawl's
-- Client/Main.lua, tinybike, GPL-3, credited in NOTICE):
--   * DAG_BrawlSelectCharacter <uuid>: at a round turnover the engine can
--     hand control to another party member; the server names the character
--     this player was controlling, and we re-select it through the party
--     portraits' SelectCharacter command (PlayerPortraits is only made
--     invisible in first person, its view model still works).
--   * DAG_BrawlNoDynamicCamera: BG3's dynamic combat camera off (it would
--     move the camera during fights).

local Log = Ext.Require("Shared/Log.lua")

local FullPov = Ext.Require("FullPov.lua")

local M = {}

local function controlled()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local e = ok and ents and ents[1] or nil
    local okU, u = pcall(function() return e.Uuid.EntityUuid end)
    return okU and u or nil
end

local function reselect(targetUuid)
    if not targetUuid or targetUuid == "" or controlled() == targetUuid then return end
    local done, why = false, "PlayerPortraits not found"
    pcall(function()
        for _, child in ipairs(Ext.UI.GetRoot():Find("ContentRoot").Children) do
            if child.Name == "PlayerPortraits" then
                why = "not among this player's characters"
                for _, character in ipairs(child.DataContext.CurrentPlayer.AssignedCharacters) do
                    if character.EntityUUID == targetUuid then
                        child.DataContext.SelectCharacter:Execute(character)
                        done = true
                        return
                    end
                end
                return
            end
        end
    end)
    Log.Write(done and ("BrawlClient: control back on " .. targetUuid .. " (round turnover)")
        or ("BrawlClient: could not re-select " .. targetUuid .. ": " .. why))
end

function M.Register()
    Ext.RegisterNetListener("DAG_BrawlSelectCharacter", function(_, payload) reselect(payload) end)
    Ext.RegisterNetListener("DAG_BrawlNoDynamicCamera", function()
        local ok = pcall(function()
            local sw = Ext.Utils.GetGlobalSwitches()
            sw.GameCameraEnableDynamicCombatCamera = false
            -- The attack camera swings the view to whoever attacks or casts
            -- (goblin casts took the first-person camera, playtest 2026-10-12).
            sw.GameCameraEnableAttackCamera = false
            sw.GameCameraEnableAttackCameraOtherPlayers = false
            -- Playtest 2026-10-12: during your own projectile casts BG3 swapped
            -- in a camera riding the projectile (a wall / black view). The DLL
            -- keeps first person on you whatever camera BG3 uses (Pov.cpp
            -- "foreign" camera); this switch is the camera-follows-flight one.
            sw.GameCameraEnableFlyFollow = false
        end)
        if not M.camLogged then
            M.camLogged = true
            Log.Write("BrawlClient: BG3 dynamic combat camera, attack camera and fly-follow camera " .. (ok and "off" or "could not be turned off"))
        end
    end)
    -- Keep them off while first person is on: re-checked every 0.5 s and
    -- logged when BG3 turned one back on (playtest 2026-10-12: casts in a
    -- fight still moved the camera with the switches set once at load).
    local CAM_SWITCHES = { "GameCameraEnableDynamicCombatCamera", "GameCameraEnableAttackCamera",
        "GameCameraEnableAttackCameraOtherPlayers", "GameCameraEnableFlyFollow" }
    local camCheckAt, camReenabled = 0, 0
    Ext.Events.Tick:Subscribe(function()
        local t = tonumber(Ext.Timer.MonotonicTime()) or 0
        if t - camCheckAt < 500 or not FullPov.IsOn() then return end
        camCheckAt = t
        pcall(function()
            local sw = Ext.Utils.GetGlobalSwitches()
            local back = {}
            for _, k in ipairs(CAM_SWITCHES) do
                if sw[k] then sw[k] = false; back[#back + 1] = k end
            end
            if #back > 0 and camReenabled < 20 then
                camReenabled = camReenabled + 1
                Log.Write("BrawlClient: BG3 had turned " .. table.concat(back, ", ") .. " back on -> off again")
            end
        end)
    end)
    -- !dag_combat_cam on|off: BG3's combat camera mode in first person (off by
    -- default: the DLL clears the camera's combat flag, FullPov nocombatcam).
    Ext.RegisterConsoleCommand("dag_combat_cam", function(_, a)
        if a == "on" or a == "off" then FullPov.SetNoCombatCam(a == "off") end
        Log.Write("BrawlClient: BG3's combat camera mode in first person " .. (FullPov.NoCombatCam() and "OFF (cleared every frame)" or "ON (vanilla)"))
    end)
    -- !dag_combat_wasd on|off: WASD in fights through BG3's own movement (the
    -- DLL skips its "no WASD in a combat" check; on by default).
    Ext.RegisterConsoleCommand("dag_combat_wasd", function(_, a)
        if a == "on" or a == "off" then FullPov.SetCombatWasd(a == "on") end
        Log.Write("BrawlClient: BG3's own WASD in fights " .. (FullPov.CombatWasd() and "ON (DLL skips its combat check)" or "OFF (vanilla: no WASD while in a combat)"))
    end)
    Log.Write("BrawlClient: registered (re-select on round turnover, dynamic combat camera off)")
end

return M
