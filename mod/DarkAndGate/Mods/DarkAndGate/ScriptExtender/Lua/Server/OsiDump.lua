-- Dumps every Osiris function visible to the current SE build to
-- Script Extender/DarkAndGate/osiris-functions.txt. Fires on the first
-- !dag_osidump console call so we never run it on load.
--
-- SE's `Osi` global is a proxy; direct `pairs(Osi)` won't walk it. Instead we
-- use the SE registry hook that bg3se exposes: `Ext.Osiris.GetFunctionList()`
-- returns an array of { name, type, numArgs }. If that API isn't present in
-- the running SE, we fall back to grepping the SE runtime log for the
-- function registration lines SE prints at startup when LogRuntime is on.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local function listViaExtApi()
    if type(Ext.Osiris) ~= "table" then return nil end
    local getter = Ext.Osiris.GetFunctionList
                or Ext.Osiris.GetAllFunctions
                or Ext.Osiris.GetFunctions
    if type(getter) ~= "function" then return nil end
    local ok, list = pcall(getter)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

-- Walk the hidden Osi proxy by probing a known-good set of names. Not a true
-- enumeration — just a sanity check that the proxy resolves. Returns the
-- subset that resolved.
local KNOWN_PROBE_NAMES = {
    "ApplyStatus", "ApplyDamage", "PlayAnimation", "UseSpell",
    "GetUUID", "GetDistanceTo", "IsPlayer", "IsDead",
    "GetHitpoints", "GetMaxHitpoints", "HasPassive", "HasActiveStatus",
    "RemoveStatus", "GetEquippedWeapon", "GetReservedUserID",
    "GetClosestAlivePlayer", "GetCurrentCharacter", "GetRegion",
    "PlaySound", "QuestMessageShow", "QuestMessageHide",
}

local function probeKnown()
    local hits = {}
    for _, name in ipairs(KNOWN_PROBE_NAMES) do
        local ok, fn = pcall(function() return Osi[name] end)
        if ok and type(fn) == "function" then
            table.insert(hits, name)
        end
    end
    return hits
end

local function dump()
    local lines = { "# Osiris functions seen by SE at runtime", "# SE: " .. tostring(Ext.Utils.Version()), "" }
    local list = listViaExtApi()
    if list then
        table.sort(list, function(a, b)
            return tostring(a.name or a[1] or a) < tostring(b.name or b[1] or b)
        end)
        for _, entry in ipairs(list) do
            if type(entry) == "table" then
                table.insert(lines, string.format("%s/%s  [%s]",
                    tostring(entry.name or "?"),
                    tostring(entry.numArgs or entry.arity or "?"),
                    tostring(entry.type or "?")))
            else
                table.insert(lines, tostring(entry))
            end
        end
        Log.Write("OsiDump: enumerated " .. #list .. " functions via Ext.Osiris")
    else
        table.insert(lines, "# Ext.Osiris.GetFunctionList() not available in this SE build.")
        table.insert(lines, "# Known-name probe hits (sanity check only):")
        for _, name in ipairs(probeKnown()) do
            table.insert(lines, "  " .. name)
        end
        table.insert(lines, "")
        table.insert(lines, "# For the full list run scripts/extract-story.ps1 to pull story.div.osi")
        table.insert(lines, "# out of Shared.pak, then open it in LSLib's Osiris Debugger.")
        Log.Write("OsiDump: Ext.Osiris enumeration unavailable; wrote probe fallback")
    end
    Ext.IO.SaveFile("DarkAndGate/osiris-functions.txt", table.concat(lines, "\n") .. "\n")
    Log.Write("OsiDump: wrote DarkAndGate/osiris-functions.txt")
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_osidump", function()
        local ok, err = pcall(dump)
        if not ok then Log.Write("OsiDump: error " .. tostring(err)) end
    end)
    Log.Write("OsiDump: !dag_osidump registered")
end

return M
