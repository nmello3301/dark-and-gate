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
        local ok = pcall(function() Ext.Utils.GetGlobalSwitches().GameCameraEnableDynamicCombatCamera = false end)
        if not M.camLogged then
            M.camLogged = true
            Log.Write("BrawlClient: BG3 dynamic combat camera " .. (ok and "off" or "could not be turned off"))
        end
    end)
    Log.Write("BrawlClient: registered (re-select on round turnover, dynamic combat camera off)")
end

return M
