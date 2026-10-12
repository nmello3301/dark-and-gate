-- SPDX-License-Identifier: GPL-3.0-or-later
-- ImGui window flags the way the Script Extender exposes them: one boolean
-- field per flag (win.NoInputs = true). There is no `Flags` field: SE's
-- P_BITMASK(Flags) registers every GuiWindowFlags label as its own property
-- (reference/bg3se Lua/Shared/Proxies/LuaObjectProxies.cpp,
-- AddBitfieldProperty), so `win.Flags = { ... }` raises an error. A pcall
-- hid that error in round 2 of the HUD playtest (2026-10-12). The
-- full-screen HUD went up as a normal window, and SE gives ImGui every mouse
-- event while a hoverable window is under the cursor (Extender/Client/
-- SDL.cpp, io.WantCaptureMouse). The camera stopped turning and MMB did
-- nothing.
--
--   WindowFlags.Set(win, { "NoInputs", ... })  -> list of flags that did NOT stick

local M = {}

function M.Set(win, flags)
    local failed = {}
    for _, f in ipairs(flags or {}) do
        local okW = pcall(function() win[f] = true end)
        local okR, v = pcall(function() return win[f] end)
        if not okW or not okR or v ~= true then failed[#failed + 1] = f end
    end
    return failed
end

-- True when the window can't take the mouse (NoInputs or NoMouseInputs read
-- back as set).
function M.ClickThrough(win)
    for _, f in ipairs({ "NoInputs", "NoMouseInputs" }) do
        local ok, v = pcall(function() return win[f] end)
        if ok and v == true then return true end
    end
    return false
end

return M
