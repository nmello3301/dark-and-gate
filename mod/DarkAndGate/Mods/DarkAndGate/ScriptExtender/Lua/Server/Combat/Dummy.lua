-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server side: spawn a training dummy in front of the user for safe hit tests.
-- The dummy is a hostile goblin we can wail on without aggroing the camp.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")

local M = {}

-- Common BG3 goblin template UUIDs. First one that CreateAt accepts wins.
local DUMMY_TEMPLATES = {
    "a46ac901-7c86-4a99-b2cf-c8db7a94e67b",  -- generic goblin warrior (Act1)
    "e7107fd3-dc8a-4a1b-9cde-83e9f85e3220",  -- Target dummy template (if present)
}

function M.Register()
    Ext.RegisterNetListener(Net.Channels.SpawnDummy, function(_, _, userId)
        ServerNet.EnqueueOsi(function()
            local caster = ServerNet.UserToCharacter(userId)
            if not caster then return end
            local okX, cx = pcall(function() return Osi.GetX(caster) end)
            local okY, cy = pcall(function() return Osi.GetY(caster) end)
            local okZ, cz = pcall(function() return Osi.GetZ(caster) end)
            local okR, rot = pcall(function() return Osi.GetRotation(caster) end)
            if not (okX and okY and okZ) then return end
            -- rot is 0..360. Simplify: spawn 3 m in +X (BG3 doesn't give a
            -- clean forward vector via Osi; the user can walk to it).
            local x = (tonumber(cx) or 0) + 3.0
            local y = tonumber(cy) or 0
            local z = tonumber(cz) or 0

            local spawned
            for _, tpl in ipairs(DUMMY_TEMPLATES) do
                local ok, uuid = pcall(function()
                    return Osi.CreateAt(tpl, x, y, z, 1, 1, "")
                end)
                if ok and uuid and uuid ~= "" then
                    spawned = uuid
                    break
                end
            end
            if spawned then
                Log.Write("Dummy: spawned " .. tostring(spawned) .. " at " .. x .. "," .. y .. "," .. z)
            else
                Log.Write("Dummy: all templates failed; try Osi.CreateAtObject later")
            end
        end)
    end)
    Log.Write("Dummy: registered")
end

return M
