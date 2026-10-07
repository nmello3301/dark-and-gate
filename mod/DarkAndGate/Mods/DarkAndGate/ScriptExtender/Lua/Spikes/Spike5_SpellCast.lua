-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 5: can a script trigger a BG3 spell cast end-to-end?
--
-- Original design assumed an FP aim ray would already be live. It isn't
-- (crosshair is M1). The spike's real question is simpler: given a caster
-- and a target picked server-side, does Osi.UseSpell actually fire the spell
-- with its full visual + damage path?
--
-- Target picking: nearest living non-player ServerCharacter within 30 m of
-- the caster. That's "whatever hostile you can see" without needing a camera.
--
-- Spell IDs are the Larian stat names. Confirmed from Brawl's constants:
--   Target_MistyStep (teleport). FireBolt and Fireball names are tried as
--   candidates below; the server logs the one that resolves.

local Log       = Ext.Require("Shared/Log.lua")
local MCM       = Ext.Require("Shared/MCM.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

local function enabled() return MCM.Get("spike5") == true end

-- Send a cast request. The server (Server/Net.lua) resolves the caster via
-- Osi.GetHostCharacter and the target via Spike5Server.PickTarget below.
local function cast(spell, wantTarget)
    if not enabled() then Log.Write("Spike5: disabled; !dag_spike5 on"); return end
    Log.Write("Spike5: request cast " .. spell .. " wantTarget=" .. tostring(wantTarget))
    -- aim stays (0,0,0); the server-side handler ignores it when wantTarget
    -- is true, and picks nearest enemy instead.
    ClientNet.CastSpell(spell, { x = 0, y = 0, z = 0 }, wantTarget and "__nearest_enemy__" or nil)
end

function M.Register()
    MCM.DefineBool("spike5", false, "Spike 5: cast spell at crosshair")
    MCM.RegisterToggleCommand("dag_spike5", "spike5")

    -- Larian spell IDs for the three targeting shapes. The server will log if
    -- a given name isn't a known stat.
    Ext.RegisterConsoleCommand("dag5_firebolt",  function() cast("Target_FireBolt",       true)  end)
    Ext.RegisterConsoleCommand("dag5_fireball",  function() cast("Projectile_Fireball",   true)  end)
    Ext.RegisterConsoleCommand("dag5_mistystep", function() cast("Target_MistyStep",      false) end)

    Log.Write("Spike5: registered (MCM spike5, cmds dag5_firebolt / _fireball / _mistystep)")
end

return M
