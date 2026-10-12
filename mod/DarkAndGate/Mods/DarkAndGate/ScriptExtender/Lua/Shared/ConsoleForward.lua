-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server console commands that also work from the client console.
--
-- SE runs a console command in the Lua state the console is switched to
-- (`server` / `client`), and most playtests sit in the client console. The
-- server registers its knobs with Server(); the client registers a
-- forwarder for the same names with Forward(), which sends
-- ServerCommand { cmd, args } to the server. The server runs the same
-- handler on the next tick (Osi calls are safe there) and logs who sent it.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")

local M = {}

local handlers = {}   -- server: name -> fn(cmd, ...)

-- Server: `name` as a console command and as a forward target.
function M.Server(name, fn)
    handlers[name] = fn
    Ext.RegisterConsoleCommand(name, fn)
end

-- Client: forward these command names to the server.
function M.Forward(names)
    for _, name in ipairs(names) do
        Ext.RegisterConsoleCommand(name, function(_, ...)
            local args = {}
            for i = 1, select("#", ...) do args[i] = tostring(select(i, ...)) end
            local ok, err = pcall(function()
                Ext.Net.PostMessageToServer(Net.Channels.ServerCommand, Ext.Json.Stringify({ cmd = name, args = args }))
            end)
            Log.Write(string.format("Console: !%s %s -> server%s", name, table.concat(args, " "), ok and "" or (" FAILED " .. tostring(err))))
        end)
    end
end

function M.RegisterServer()
    Ext.RegisterNetListener(Net.Channels.ServerCommand, function(_, payload, userId)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or type(p.cmd) ~= "string" then return end
        local fn = handlers[p.cmd]
        if not fn then
            Log.Write("Console: forwarded command !" .. p.cmd .. " has no server handler")
            return
        end
        local args = type(p.args) == "table" and p.args or {}
        Ext.OnNextTick(function()
            Log.Write(string.format("Console: !%s %s (typed in user %s's client console)", p.cmd, table.concat(args, " "), tostring(userId)))
            local okR, err = pcall(fn, p.cmd, table.unpack(args))
            if not okR then Log.Write("Console: !" .. p.cmd .. " failed: " .. tostring(err)) end
        end)
    end)
end

return M
