-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 6: push the ragdoll in the direction of the killing blow.
--
-- BG3's death animation picks a direction based on the final damage hit's
-- impact vector. The question is whether we can override that direction
-- from Lua. Two probes:
--   A. Pre-death: apply a tagged status with a direction payload so the
--      engine's death handler picks it up.
--   B. Post-death: directly nudge the character's velocity / impulse
--      component after `IsDead` reports true.
--
-- The real engine lever (CharacterCorpseData / RagdollState) is likely only
-- reachable from native; this spike records whether either Lua path works
-- before we add it to the native plugin scope.

local Log       = Ext.Require("Shared/Log.lua")
local MCM       = Ext.Require("Shared/MCM.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

local function enabled() return MCM.Get("spike6") == true end

function M.Register()
    MCM.DefineBool("spike6", false, "Spike 6: directional ragdoll push")
    MCM.RegisterToggleCommand("dag_spike6", "spike6")

    Ext.RegisterConsoleCommand("dag6_push", function()
        if not enabled() then Log.Write("Spike6: disabled; !dag_spike6 on"); return end
        -- Target picking lives on the server: ServerCharacter components only
        -- exist there. Same `__nearest_enemy__` sentinel as Spike 5.
        local dir = { x = 0, y = 0, z = 1 }
        Log.Write(string.format("Spike6: push nearest hostile dir=(%.2f,%.2f,%.2f)",
            dir.x, dir.y, dir.z))
        ClientNet.RagdollPush("__nearest_enemy__", dir, 10.0)
    end)

    Log.Write("Spike6: registered (MCM spike6, cmd dag6_push)")
end

return M
