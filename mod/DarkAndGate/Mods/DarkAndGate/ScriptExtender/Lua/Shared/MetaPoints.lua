-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points, both Lua states (DECISIONS 2026-10-15, docs/DESIGN.md
-- "Meta-Points", data/metapoints.lua).
--
-- Storage: one SE user variable per character, DAG_MetaPoints =
-- { v = 1, spent = { STR = n, ... }, bonus = n } (bonus = debug grants).
-- Persistent (saved with the character), written by the server only, synced
-- to clients. Points available = points_per_level x character level + bonus
-- - spent, so old saves get their points from the level at once and unspent
-- points carry over; a character with no variable reads as 0 spent.
--
-- The server owns it (Server/MetaPoints.lua). Clients read the server's
-- MetaState messages (Client/MetaPoints.lua -> SetState), falling back to
-- the synced variable.
--
--   MetaPoints.Config()                  effective config (defaults + JSON override)
--   MetaPoints.Effect(id)                one effect's entry
--   MetaPoints.Value(uuid, id[, spent])  the effect's curve value for a character
--                                        (spent = a { STR = n } table to preview)
--   MetaPoints.Mult(uuid, id)            Value, or 1.0 without data
--   MetaPoints.Floor(seconds)            min_action_interval floor (engine safety)
--   MetaPoints.Record(uuid)              { spent, bonus } or nil
--   MetaPoints.Points(rec, stat)         points spent on a stat

local Log       = Ext.Require("Shared/Log.lua")
local MetaCurve = Ext.Require("Shared/MetaCurve.lua")
local defaults  = Ext.Require("data/metapoints.lua")

local M = {}

M.VAR  = "DAG_MetaPoints"
M.FILE = "DarkAndGate/metapoints.json"

-- Registered when the bootstrap loads this module, with the same settings on
-- both sides (SE docs, "User variables").
local okReg, errReg = pcall(Ext.Vars.RegisterUserVariable, M.VAR, {
    Server = true, Client = true, WriteableOnServer = true, WriteableOnClient = false,
    Persistent = true, SyncToClient = true, SyncToServer = false,
})
if not okReg then Log.Write("MetaPoints: RegisterUserVariable FAILED: " .. tostring(errReg)) end
-- An enemy's max HP scaling (Server/Combat/MetaDamage.lua): { mult, max }.
M.ENEMY_HP_VAR = "DAG_EnemyHp"
local okReg2, errReg2 = pcall(Ext.Vars.RegisterUserVariable, M.ENEMY_HP_VAR, {
    Server = true, Client = true, WriteableOnServer = true, WriteableOnClient = false,
    Persistent = true, SyncToClient = false, SyncToServer = false,
})
if not okReg2 then Log.Write("MetaPoints: RegisterUserVariable (enemy HP) FAILED: " .. tostring(errReg2)) end

local function isServer()
    local ok, v = pcall(Ext.IsServer)
    return ok and v == true
end
M.IsServer = isServer

local function copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

local function norm(g)
    if g == nil then return nil end
    g = tostring(g)
    return g:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or g
end
M.Norm = norm

local config = copy(defaults)
local effectsById = {}
local function index()
    effectsById = {}
    for _, e in ipairs(config.effects or {}) do effectsById[e.id] = e end
end
index()

-- ---------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------
local function validPoints(p)
    if type(p) ~= "table" or #p == 0 then return false end
    local last = -math.huge
    for _, bp in ipairs(p) do
        if type(bp) ~= "table" or tonumber(bp[1]) == nil or tonumber(bp[2]) == nil then return false end
        if tonumber(bp[1]) < last then return false end
        last = tonumber(bp[1])
    end
    return true
end

-- The defaults with `over` on top: plain keys replace, effects merge by id.
-- Returns the merged table and a list of notes about what was refused.
function M.Merge(base, over)
    local out = copy(base)
    local notes = {}
    if type(over) ~= "table" then return out, notes end
    for k, v in pairs(over) do
        if k == "effects" then
            if type(v) == "table" then
                local byId = {}
                for i, e in ipairs(out.effects) do byId[e.id] = i end
                for _, e in ipairs(v) do
                    local i = type(e) == "table" and byId[e.id] or nil
                    if not i then
                        notes[#notes + 1] = "effect " .. tostring(type(e) == "table" and e.id or e) .. " is not one the mod knows (ignored)"
                    else
                        for ek, ev in pairs(e) do
                            if ek == "points" and not validPoints(ev) then
                                notes[#notes + 1] = "effect " .. e.id .. ": points must be [[points, value], ...] in rising order (kept the default)"
                            elseif ek ~= "id" then
                                out.effects[i][ek] = copy(ev)
                            end
                        end
                    end
                end
            end
        elseif type(k) == "string" and k:sub(1, 1) ~= "_" then
            out[k] = copy(v)
        end
    end
    return out, notes
end

function M.Config() return config end
function M.Effect(id) return effectsById[id] end
function M.Defaults() return defaults end

function M.SetConfig(t)
    if type(t) ~= "table" or type(t.effects) ~= "table" then return false end
    config = M.Merge(defaults, t)
    index()
    return true
end

-- The JSON override on this PC: table, or nil + why.
function M.ReadFile()
    local ok, s = pcall(Ext.IO.LoadFile, M.FILE)
    if not ok or not s or s == "" then return nil, "missing" end
    local okJ, t = pcall(Ext.Json.Parse, s)
    if not okJ or type(t) ~= "table" then return nil, "not valid JSON (" .. tostring(t) .. ")" end
    return t
end

function M.WriteDefaultsFile()
    local t = copy(defaults)
    t._readme = "Dark and Gate Meta-Points. Edit and type !dag_meta_reload in the Script Extender console. "
        .. "points = [[points, value], ...]: linear between breakpoints, flat after the last. "
        .. "respec_mode: camp | anywhere | off. Delete this file to get the defaults back."
    local ok, s = pcall(Ext.Json.Stringify, t, { Beautify = true })
    if not ok then ok, s = pcall(Ext.Json.Stringify, t) end
    if ok then pcall(Ext.IO.SaveFile, M.FILE, s) end
    return ok
end

-- ---------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------
local cache = {}   -- client: uuid -> the server's last MetaState
function M.SetState(uuid, st) uuid = norm(uuid); if uuid then cache[uuid] = st end end
function M.State(uuid) return cache[norm(uuid) or ""] end
function M.States() return cache end

function M.Record(uuid)
    uuid = norm(uuid)
    if not uuid then return nil end
    if not isServer() then
        local st = cache[uuid]
        if st then return { spent = st.spent or {}, bonus = tonumber(st.bonus) or 0 } end
    end
    local rec = nil
    pcall(function() rec = Ext.Entity.Get(uuid).Vars[M.VAR] end)
    if type(rec) ~= "table" then return nil end
    return rec
end

function M.Points(rec, stat)
    if type(rec) ~= "table" or type(rec.spent) ~= "table" then return 0 end
    return math.max(0, math.floor(tonumber(rec.spent[stat]) or 0))
end

function M.SpentTotal(rec)
    local n = 0
    for _, s in ipairs(config.stats or {}) do n = n + M.Points(rec, s) end
    return n
end

function M.Total(level, rec)
    return (tonumber(config.points_per_level) or 8) * math.max(0, tonumber(level) or 0) + math.max(0, tonumber(rec and rec.bonus) or 0)
end

-- ---------------------------------------------------------------------
-- Effects
-- ---------------------------------------------------------------------
function M.Value(uuid, id, spent)
    local e = effectsById[id]
    if not e then return nil end
    local pts
    if type(spent) == "table" then pts = tonumber(spent[e.stat]) or 0 else pts = M.Points(M.Record(uuid), e.stat) end
    return MetaCurve.Eval(e.points, pts)
end

function M.Mult(uuid, id)
    if not uuid then return 1.0 end
    return M.Value(uuid, id) or 1.0
end

function M.MinInterval()
    local f = tonumber(config.min_action_interval) or 0
    return f > 0 and f or 0
end

function M.Floor(seconds)
    return math.max(M.MinInterval(), tonumber(seconds) or 0)
end

function M.SelfTest(log)
    local ok, lines = MetaCurve.SelfTest(defaults.effects, 0.01)
    if log then
        for _, l in ipairs(lines) do Log.Write("MetaPoints: self-test " .. l) end
    end
    return ok, lines
end

return M
