-- Shared logger. Writes to the SE console AND to a file under
-- %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\session.log
--
-- Lines look like:
--   [2026-10-07 02:45:12] [Server] Dark and Gate loaded. SE v32
--
-- Ext.IO.SaveFile overwrites, so we buffer this session's lines in memory and
-- rewrite the whole file each time. For M0 that is fine; we switch to append
-- or a rolling writer once the volume justifies it.

local Log = {}

-- Client and server run as separate Lua states that cannot share memory, and
-- Ext.IO.SaveFile has no append mode -- it rewrites the file every call. If
-- both states wrote to one path they would clobber each other, so each side
-- gets its own file. read-log.ps1 merges them on display.
local LOG_PATH = nil
local buffer = {}
local tag = "?"
local startMs = nil  -- set on first Write; monotonic ms since engine start.

-- SE's Lua sandbox omits the standard `os` library, so there's no wall-clock
-- source available. `Ext.Timer.MonotonicTime()` returns int64 ms since engine
-- start. For M0 that's fine: logs are session-scoped and only need to be
-- ordered, not absolute. Format: "+000.000s" from the first log line of this
-- Lua state.
local function timestamp()
    local now = Ext.Timer.MonotonicTime()
    if startMs == nil then startMs = now end
    local secs = (tonumber(now) - tonumber(startMs)) / 1000
    return string.format("+%07.3fs", secs)
end

function Log.Init(side)
    tag = side  -- "Server" or "Client"
    LOG_PATH = "DarkAndGate/" .. string.lower(side) .. ".log"
    -- Fresh file for this session. Later lines append in-memory and the whole
    -- buffer is rewritten on each Write.
    Ext.IO.SaveFile(LOG_PATH, "")
end

function Log.Write(msg)
    local line = string.format("[%s] [%s] %s", timestamp(), tag, tostring(msg))
    table.insert(buffer, line)
    -- Console / SE log window.
    Ext.Utils.Print(line)
    -- Flush the whole buffer to the file. Cheap for M0.
    Ext.IO.SaveFile(LOG_PATH, table.concat(buffer, "\n") .. "\n")
end

return Log
