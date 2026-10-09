-- SPDX-License-Identifier: GPL-3.0-or-later
-- In-game animation browser + gallery remote (!dag_animlib).
--
-- Pick animations by watching the engine play them:
--   * target: the controlled character, party members, anyone within 10 m;
--     its rig and AnimationSet(s) are shown (Client/AnimLib/Library.lua);
--   * list: that target's own playable clips, one row per clip file (all
--     its mapping ids kept), filtered by text / category / family / phase,
--     paged (page size = gallery size);
--   * Play / Replay / Prev / Next (PageUp / PageDown) / Stop on the target,
--     through the server PlayAnim channel ("force" skips the turn-based
--     guard). "Try next id" cycles the clip's mapping ids, then its
--     resource id; "It played" remembers which kind works;
--   * "Use as": tag the selected clip (Client/AnimLib/Tags.lua), by mapping
--     id, optionally only for the target's rig;
--   * Coverage: which rigs have a clip for the selected mapping id;
--   * Gallery: n preview copies loop the current page (Gallery.lua).
--   * Play rate (0 = freeze .. 2): the Genome "PlayRate" blueprint
--     variable (AnimSpeed.lua, approach learned from QSAT), on the target
--     or on every gallery copy -- when the blueprint has that variable.
-- While the window is open first person is off (third person to watch);
-- it comes back on close. ImGui elements are created once.
--
-- Commands (client console):
--   !dag_animlib                       open / close the browser
--   !dag_animlib gallery [n]           open with a gallery of n copies (default 12, max 25)
--   !dag_animlib clear                 remove the gallery copies
--   !dag_animlib template <uuid>       gallery template override (empty = automatic)
--   !dag_animlib global                build the global index (coverage, fallback lists)
--   !dag_animlib_export                print the tags as a Lua table for data/anim_tags.lua

local Log       = Ext.Require("Shared/Log.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local FullPov   = Ext.Require("FullPov.lua")
local Library   = Ext.Require("Client/AnimLib/Library.lua")
local Tags      = Ext.Require("Client/AnimLib/Tags.lua")
local Gallery   = Ext.Require("Client/AnimLib/Gallery.lua")
local AnimSpeed = Ext.Require("Client/AnimLib/AnimSpeed.lua")

local M = {}

local MAX_ROWS = 25
local NEAR_M = 10.0

local W = nil            -- widgets (built once)
local open = false
local povWasOn = false
local targets = {}       -- { uuid, name, ent }
local target = nil
local filtered = {}
local page = 1
local pageSize = 12
local selected = nil     -- clip
local altIdx = 1         -- which id of the selected clip to play (1..#keys, then res)
local preferRes = false  -- "It played" on a resource id
local force = false
local filters = { text = "", cat = nil, fam = nil, phase = nil }
local templateOverride = nil
local lastStatusAt = 0
local lastStatus = nil
local listStamp = nil

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function trySet(o, k, v) pcall(function() o[k] = v end) end
local function set(o, k, v) if o and o[k] ~= v then trySet(o, k, v) end end

-- ---------------------------------------------------------------------
-- Targets
-- ---------------------------------------------------------------------
local function nameOf(ent)
    local ok, n = pcall(function()
        return Ext.Loca.GetTranslatedString(ent.DisplayName.NameKey.Handle.Handle)
    end)
    if ok and n and n ~= "" then return n end
    return "?"
end

local function uuidOf(ent)
    local ok, u = pcall(function() return ent.Uuid.EntityUuid end)
    return ok and u or nil
end

local function posOf(ent)
    local ok, t = pcall(function() return ent.Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    return nil
end

local function collectTargets()
    local list, seen = {}, {}
    local function add(ent, tag)
        local u = ent and uuidOf(ent)
        if u and not seen[u] then
            seen[u] = true
            list[#list + 1] = { uuid = u, name = nameOf(ent) .. tag, ent = ent }
        end
    end
    local okC, cc = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local me = okC and cc and cc[1] or nil
    add(me, " (you)")
    local okP, party = pcall(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if okP and party then for _, e in ipairs(party) do add(e, " (party)") end end
    local mp = me and posOf(me)
    if mp then
        local okA, all = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientCharacter")
        if okA and all then
            for _, e in ipairs(all) do
                local p = posOf(e)
                if p then
                    local dx, dy, dz = p[1] - mp[1], p[2] - mp[2], p[3] - mp[3]
                    if dx * dx + dy * dy + dz * dz <= NEAR_M * NEAR_M then add(e, "") end
                end
            end
        end
    end
    return list
end

-- ---------------------------------------------------------------------
-- Filtering and paging
-- ---------------------------------------------------------------------
local function hasCat(c, cat)
    for _, x in ipairs(c.cats) do if x == cat then return true end end
    return false
end

local function applyFilters()
    filtered = {}
    local text = (filters.text or ""):lower()
    for _, c in ipairs(Library.B.clips) do
        if (text == "" or c.lower:find(text, 1, true))
            and (not filters.cat or hasCat(c, filters.cat))
            and (not filters.fam or c.family == filters.fam)
            and (not filters.phase or c.phase == filters.phase) then
            filtered[#filtered + 1] = c
        end
    end
    page = 1
end

local function pageCount() return math.max(1, math.ceil(#filtered / pageSize)) end

local function pageClips()
    local out = {}
    local first = (page - 1) * pageSize
    for i = 1, pageSize do out[i] = filtered[first + i] end
    return out
end

-- Combo options: "(any)" + the most common values, most common first.
local function topValues(field, limit)
    local counts = {}
    for _, c in ipairs(Library.B.clips) do
        if field == "cats" then
            for _, x in ipairs(c.cats) do counts[x] = (counts[x] or 0) + 1 end
        else
            counts[c[field]] = (counts[c[field]] or 0) + 1
        end
    end
    local list = {}
    for v, n in pairs(counts) do if v and v ~= "?" then list[#list + 1] = { v = v, n = n } end end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.v < b.v end)
    local opts, vals = { "(any)" }, { false }
    for i = 1, math.min(limit, #list) do
        opts[#opts + 1] = string.format("%s (%d)", list[i].v, list[i].n)
        vals[#vals + 1] = list[i].v
    end
    return opts, vals
end

local comboVals = { cat = { false }, fam = { false }, phase = { false } }

local function refreshFilterCombos()
    for key, field in pairs({ cat = "cats", fam = "family", phase = "phase" }) do
        local opts, vals = topValues(field, 40)
        comboVals[key] = vals
        trySet(W[key], "Options", opts)
        trySet(W[key], "SelectedIndex", 0)
        filters[key] = nil
    end
end

-- ---------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------
local function idFor(c)
    if preferRes and altIdx == 1 then return c.res, "resource" end
    if altIdx <= #c.keys then return c.keys[altIdx], string.format("mapping %d/%d", altIdx, #c.keys) end
    return c.res, "resource"
end

local function playSelected(why)
    if not selected or not target then return end
    local id, kind = idFor(selected)
    ClientNet.PlayAnimOn(target.uuid, id, selected.dur, force)
    Log.Write(string.format("AnimLib: %s %s on %s via %s (%s, %.2fs)%s", why or "play", selected.base,
        target.name, kind, id, selected.dur or 0, force and " force" or ""))
end

-- ---------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------
local function rowLabel(i, c)
    local n = (page - 1) * pageSize + i
    return string.format("#%d  %s  (%.1fs, %d id%s)##row%d", n, c.base, c.dur or 0, #c.keys, #c.keys == 1 and "" or "s", i)
end

local function refreshRows()
    local clips = pageClips()
    for i = 1, MAX_ROWS do
        local r = W.rows[i]
        local c = (i <= pageSize) and clips[i] or nil
        set(r, "Visible", c ~= nil)
        if c then
            set(r, "Label", rowLabel(i, c))
            set(r, "Selected", selected == c)
        end
    end
    set(W.pageText, "Label", string.format("page %d/%d  (%d of %d clips)", page, pageCount(), #filtered, #Library.B.clips))
    if Gallery.Active() then Gallery.SetPage(clips) end
end

local function selectedInfo()
    if not selected then
        set(W.sel, "Label", "selected: (none) -- click a row")
        return
    end
    local subs = {}
    for s in pairs(selected.subsets) do subs[#subs + 1] = s end
    table.sort(subs)
    local id, kind = idFor(selected)
    set(W.sel, "Label", string.format("selected: %s\n%.2fs  rig %s  family %s  phase %s\n%d mapping id(s), subsets: %s\nnext play uses %s %s",
        selected.base, selected.dur or 0, selected.rig, selected.family, selected.phase,
        #selected.keys, table.concat(subs, ", "), kind, id))
end

local function coverageText()
    if not selected then set(W.cov, "Label", ""); return end
    local key = selected.keys[1]
    local byRig, gaps = Library.Coverage(key)
    if not byRig then
        set(W.cov, "Label", "coverage: " .. (Library.G.state == "building" and Library.G.status
            or "needs the global index (click Coverage to build it; several minutes, once)"))
        return
    end
    local parts = {}
    for rig, e in pairs(byRig) do parts[#parts + 1] = string.format("%s: %s (%d set%s)", rig, e.file, e.sets, e.sets == 1 and "" or "s") end
    table.sort(parts)
    set(W.cov, "Label", string.format("coverage of %s:\n%s\nGAPS (no clip): %s", key, table.concat(parts, "\n"),
        #gaps > 0 and table.concat(gaps, ", ") or "none"))
end

local function selectRow(i)
    local c = pageClips()[i]
    if not c then return end
    selected, altIdx = c, 1
    refreshRows()
    selectedInfo()
    coverageText()
end

local function setTarget(t)
    if not t then return end
    target = t
    selected = nil
    listStamp = nil
    Library.Load(t, t.ent)
    selectedInfo()
    if W then
        local ok = AnimSpeed.Available(t.ent)
        set(W.speed, "Label", ok and ("speed: " .. AnimSpeed.VAR .. " variable found on " .. t.name)
            or ("speed: no " .. AnimSpeed.VAR .. " variable on " .. t.name .. "'s blueprint (see !dag_anim_vars)"))
        Log.Write(string.format("AnimLib: play-rate lever on %s: %s", t.name, ok and "PlayRate variable found" or "not available"))
    end
end

local function tagSelected()
    if not selected then Log.Write("AnimLib: select a clip first"); return end
    local idx = (W.tagCombo.SelectedIndex or 0) + 1
    local tag = Tags.KNOWN[idx]
    local custom = W.tagCustom.Text
    if custom and custom ~= "" then tag = custom end
    if not tag then return end
    local key = idFor(selected)
    Tags.Set(tag, selected, key, W.tagRig.Checked and Library.B.rig or nil)
    set(W.tags, "Label", "tags: " .. Tags.Summary())
end

local function build()
    if W then return W end
    local ok, err = pcall(function()
        local w = Ext.IMGUI.NewWindow("Dark and Gate - Animations")
        trySet(w, "Closeable", true)
        pcall(function() w:SetSize({ 560, 760 }) end)
        local t = { win = w, rows = {} }

        t.target = w:AddCombo("Target")
        t.refresh = w:AddButton("Refresh targets"); trySet(t.refresh, "SameLine", true)
        t.info = w:AddText("")
        w:AddSeparator()

        t.search = w:AddInputText("Search", "")
        t.cat = w:AddCombo("Category")
        t.fam = w:AddCombo("Family")
        t.phase = w:AddCombo("Phase")
        t.clearF = w:AddButton("Clear filters")
        t.prev = w:AddButton("< Prev"); trySet(t.prev, "SameLine", true)
        t.next = w:AddButton("Next >"); trySet(t.next, "SameLine", true)
        t.pageText = w:AddText("")
        for i = 1, MAX_ROWS do
            local r = w:AddSelectable("##row" .. i)
            trySet(r, "Visible", false)
            r.OnClick = function() selectRow(i) end
            t.rows[i] = r
        end
        w:AddSeparator()

        t.sel = w:AddText("")
        t.play = w:AddButton("Play")
        t.replay = w:AddButton("Replay"); trySet(t.replay, "SameLine", true)
        t.stop = w:AddButton("Stop"); trySet(t.stop, "SameLine", true)
        t.alt = w:AddButton("Try next id"); trySet(t.alt, "SameLine", true)
        t.works = w:AddButton("It played"); trySet(t.works, "SameLine", true)
        t.force = w:AddCheckbox("force (ignore the turn-based guard)", false)
        t.speedSl = w:AddSlider("Play rate", 1.0, 0.0, 2.0)
        t.speedTgt = w:AddButton("Apply to target")
        t.speedAll = w:AddButton("Apply to all copies"); trySet(t.speedAll, "SameLine", true)
        t.speedReset = w:AddButton("1x"); trySet(t.speedReset, "SameLine", true)
        t.speed = w:AddText("speed: (pick a target)")
        w:AddSeparator()

        t.tagCombo = w:AddCombo("Use as")
        trySet(t.tagCombo, "Options", Tags.KNOWN)
        trySet(t.tagCombo, "SelectedIndex", 0)
        t.tagCustom = w:AddInputText("custom tag", "")
        t.tagRig = w:AddCheckbox("only for this rig (override)", false)
        t.tagBtn = w:AddButton("Tag selected")
        t.export = w:AddButton("Export tags to log"); trySet(t.export, "SameLine", true)
        t.tags = w:AddText("tags: " .. Tags.Summary())
        t.covBtn = w:AddButton("Coverage")
        t.cov = w:AddText("")
        w:AddSeparator()

        t.galN = w:AddSliderInt("Gallery size", 12, 1, 25)
        t.galBtn = w:AddButton("Gallery")
        t.galClear = w:AddButton("Clear gallery"); trySet(t.galClear, "SameLine", true)
        t.galLoop = w:AddCheckbox("loop", true); trySet(t.galLoop, "SameLine", true)
        t.galSolo = w:AddButton("Solo selected"); trySet(t.galSolo, "SameLine", true)

        -- Handlers
        t.target.OnChange = function(h)
            local i = (h.SelectedIndex or 0) + 1
            setTarget(targets[i])
        end
        t.refresh.OnClick = function() M.RefreshTargets() end
        t.search.OnChange = function(_, text) filters.text = text or ""; applyFilters(); refreshRows() end
        for key in pairs({ cat = 1, fam = 1, phase = 1 }) do
            t[key].OnChange = function(h)
                local v = comboVals[key][(h.SelectedIndex or 0) + 1]
                filters[key] = v or nil
                applyFilters(); refreshRows()
            end
        end
        t.clearF.OnClick = function()
            filters = { text = "", cat = nil, fam = nil, phase = nil }
            trySet(t.search, "Text", "")
            for _, k in ipairs({ "cat", "fam", "phase" }) do trySet(t[k], "SelectedIndex", 0) end
            applyFilters(); refreshRows()
        end
        t.prev.OnClick = function() M.Page(-1) end
        t.next.OnClick = function() M.Page(1) end
        t.play.OnClick = function() playSelected("play") end
        t.replay.OnClick = function() playSelected("replay") end
        t.stop.OnClick = function()
            if target then ClientNet.PlayAnimOn(target.uuid, "__unstick__", nil, true) end
            Log.Write("AnimLib: stop on " .. (target and target.name or "?"))
        end
        t.alt.OnClick = function()
            if not selected then return end
            altIdx = altIdx + 1
            if altIdx > #selected.keys + 1 then altIdx = 1 end
            selectedInfo()
            playSelected("try next id")
        end
        t.works.OnClick = function()
            if not selected then return end
            local _, kind = idFor(selected)
            preferRes = (kind == "resource")
            Log.Write(string.format("AnimLib: %s plays via %s -- %s ids preferred from now on",
                selected.base, kind, preferRes and "resource" or "mapping"))
        end
        t.force.OnChange = function(_, v) force = v and true or false end
        local function rate()
            local v = t.speedSl.Value
            local r = tonumber(type(v) == "table" and (v[1] or v.x) or v) or 1
            if r > 0 and r < 0.1 then r = 0.1 end   -- 0 = freeze, else 0.1 .. 2
            return r
        end
        local function applyRate(ents, label)
            local okN, last = 0, nil
            for _, e in ipairs(ents) do
                local ok, why = AnimSpeed.Set(e, rate())
                if ok then okN = okN + 1 else last = why end
            end
            local msg = string.format("speed: x%.2f on %d/%d %s%s", rate(), okN, #ents, label,
                last and (" -- " .. last) or "")
            set(t.speed, "Label", msg)
            Log.Write("AnimLib: " .. msg)
        end
        t.speedTgt.OnClick = function() if target then applyRate({ target.ent }, "target") end end
        t.speedAll.OnClick = function() applyRate(Gallery.Entities(), "gallery copies") end
        t.speedReset.OnClick = function()
            trySet(t.speedSl, "Value", { 1, 0, 0, 0 })
            if target then applyRate({ target.ent }, "target") end
            if Gallery.Active() then applyRate(Gallery.Entities(), "gallery copies") end
        end
        t.tagBtn.OnClick = function() tagSelected() end
        t.export.OnClick = function() M.Export() end
        t.covBtn.OnClick = function()
            if Library.G.state ~= "ready" then Library.BuildGlobal(false) end
            coverageText()
        end
        t.galN.OnChange = function(h)
            local v = h.Value
            local n = tonumber(type(v) == "table" and (v[1] or v.x) or v) or 12
            pageSize = math.max(1, math.min(MAX_ROWS, n))
            page = math.min(page, pageCount())
            refreshRows()
        end
        t.galBtn.OnClick = function() M.OpenGallery(pageSize) end
        t.galClear.OnClick = function() Gallery.Clear("button") end
        t.galLoop.OnChange = function(_, v) Gallery.SetLoop(v) end
        t.galSolo.OnClick = function()
            Gallery.SetPaused(true)
            playSelected("solo")
            Log.Write("AnimLib: solo -- gallery loops paused (tick 'loop' or press Gallery to resume)")
        end
        w.OnClose = function() M.Close("window closed") end
        W = t
    end)
    if not ok then
        Log.Write("AnimLib: browser UI build failed: " .. tostring(err))
        W = nil
    end
    return W
end

local function updateStatus()
    local t = now()
    if t - lastStatusAt < 250 then return end
    lastStatusAt = t
    local B = Library.B
    local s = string.format("rig %s  |  %s  |  sets: %d%s\n%s%s", B.rig or "?", B.source or "",
        #(B.sets or {}), B.fallback and "  |  FALLBACK LIST" or "", B.status or "",
        Library.G.state == "building" and ("\nglobal index: " .. Library.G.status) or "")
    if s ~= lastStatus then lastStatus = s; set(W.info, "Label", s) end
    -- List finished building: fill combos and rows once.
    if B.state == "ready" and listStamp ~= B.clips then
        listStamp = B.clips
        refreshFilterCombos()
        applyFilters()
        refreshRows()
    end
end

-- ---------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------
function M.RefreshTargets()
    targets = collectTargets()
    local names = {}
    for i, t in ipairs(targets) do names[i] = t.name end
    trySet(W.target, "Options", names)
    local idx = 0
    for i, t in ipairs(targets) do if target and t.uuid == target.uuid then idx = i - 1 end end
    trySet(W.target, "SelectedIndex", idx)
    Log.Write(string.format("AnimLib: %d targets (you, party, within %d m)", #targets, NEAR_M))
end

function M.Page(d)
    page = math.max(1, math.min(pageCount(), page + d))
    refreshRows()
end

function M.Open(galleryN)
    if not build() then return end
    if not open then
        open = true
        povWasOn = FullPov.IsOn()
        if povWasOn then FullPov.SetOn(false) end
        trySet(W.win, "Open", true)
        trySet(W.win, "Visible", true)
        M.RefreshTargets()
        if not target then setTarget(targets[1]) end
        Log.Write("AnimLib: browser open" .. (povWasOn and " (first person off while open)" or ""))
    end
    if galleryN then M.OpenGallery(galleryN) end
end

function M.OpenGallery(n)
    n = math.max(1, math.min(25, tonumber(n) or 12))
    pageSize = n
    trySet(W.galN, "Value", { n, 0, 0, 0 })
    page = math.min(page, pageCount())
    Gallery.Open(n, Library.B.rig, target and target.uuid, templateOverride, pageClips())
    Gallery.SetLoop(W.galLoop.Checked ~= false)
    refreshRows()
end

function M.Close(why)
    if not open then return end
    open = false
    Gallery.Clear("browser closed")
    trySet(W.win, "Open", false)
    if povWasOn then FullPov.SetOn(true) end
    Log.Write("AnimLib: browser closed (" .. tostring(why) .. ")" .. (povWasOn and ", first person back on" or ""))
    povWasOn = false
end

function M.Export()
    local lua = Tags.Export()
    Log.Write("AnimLib: paste into data/anim_tags.lua:\n" .. lua)
    Ext.Utils.Print(lua)
end

function M.Register()
    Gallery.Register()

    local lastSpikeLog = 0
    Ext.Events.Tick:Subscribe(function()
        local t0 = Ext.Timer.MicrosecTime()
        pcall(Library.Tick)
        if open and W then pcall(updateStatus) end
        pcall(Gallery.Tick)
        local dt = (Ext.Timer.MicrosecTime() - t0) / 1000
        if dt > 2 and now() - lastSpikeLog > 2000 then
            lastSpikeLog = now()
            Log.Write(string.format("AnimLib: tick took %.1f ms (library=%s gallery=%s)", dt,
                Library.B.state, Gallery.Active() and tostring(Gallery.Size()) or "off"))
        end
    end)

    Ext.Events.KeyInput:Subscribe(function(e)
        if not open or tostring(e.Event) ~= "KeyDown" then return end
        local k = tostring(e.Key)
        if k == "PAGEUP" or k == "PAGEDOWN" then
            M.Page(k == "PAGEUP" and -1 or 1)
            pcall(function() e:PreventAction() end)
        end
    end)

    Ext.Events.SessionLoaded:Subscribe(function() if open then M.Close("session loaded") end end)
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local to = tostring(e.ToState)
        if open and (to == "UnloadLevel" or to == "UnloadSession" or to == "LoadLevel") then M.Close("level change") end
    end)

    Ext.RegisterConsoleCommand("dag_animlib", function(_, a, b)
        if a == "gallery" then
            M.Open(tonumber(b) or 12)
        elseif a == "clear" then
            Gallery.Clear("command")
        elseif a == "template" then
            templateOverride = (b and b ~= "") and b or nil
            Log.Write("AnimLib: gallery template override = " .. tostring(templateOverride))
        elseif a == "global" then
            Library.BuildGlobal(b == "force")
        elseif open then
            M.Close("command")
        else
            M.Open()
        end
    end)
    Ext.RegisterConsoleCommand("dag_animlib_export", function() M.Export() end)
    Log.Write("AnimLib: registered (!dag_animlib [gallery n|clear|template <uuid>|global], !dag_animlib_export)")
end

return M
