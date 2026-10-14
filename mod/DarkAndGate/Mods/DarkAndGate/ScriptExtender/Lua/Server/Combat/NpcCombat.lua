-- SPDX-License-Identifier: GPL-3.0-or-later
-- Enemy (and companion) AI on our combat rules (DECISIONS 2026-10-12,
-- docs/design/combat-rules.md, data/ai.lua).
--
-- Brawl still decides who acts, on whom, with which spell, and walks them
-- into range (Server/Brawl/AI.lua, Pick.lua, Movement.lua). This wraps the
-- one call where that decision becomes a BG3 cast, Actions.useSpellOnTarget:
--   melee weapon attack   -> our swing, run on the server with the player's
--                            own weapon data (timings, reach, arcs): the
--                            direction is committed at windup start, the arc
--                            is tested against cylinders every tick of the
--                            active window, with line of sight / wall stop and
--                            the shield disc first; weapon dice on our damage
--                            path (Server/Combat/Damage.lua: no hit reaction on
--                            the player). BG3's attack animation comes from a
--                            no-effect visual clone (DAG_V_Target_MainHandAttack).
--   ranged weapon attack  -> our projectile system: a reaction delay, an aim
--   / projectile spell       error cone and a misjudged lead on moving targets
--                            (arrows: weapon dice at our hit; spells: their
--                            impact clone)
--   bow attack            -> the draw first (data/bows.lua draw_s, like the
--                            player; every client plays BG3's draw clip on the
--                            archer, stretched to it: Server/Combat/Bows.lua
--                            Anim), facing the target; aimed at the release
--                            with lead and the arrow's drop, then the error
--   area / cone spell     -> the target point (with the same aim error) is
--                            committed when the cast starts; BG3 casts there
--                            after our cast time, so you can step out of it
--   Target_Help on a      -> our hold-to-revive (Server/Combat/Downed.lua)
--   downed ally
--   any other spell       -> BG3's own cast, after our cast time
-- Self casts (dash, rage, auras, shouts) pass straight through, and so does
-- everything with !dag_ai off. While a swing / shot / cast runs the
-- character is busy: Brawl's pulse skips it (AI.act wrapper).
--
-- The pace (Server/Combat/Pace.lua: your side 4 s, developer 2026-10-12;
-- enemies by BG3's difficulty, Explorer 10 s to Honour 4 s, 2026-10-13): an
-- action starts at most once a pace. A pulse that
-- comes while the last action still runs (a bow's 3 s draw, a cast), or
-- less than a pace after it started, waits, and the fighter acts again the
-- moment both are over instead of a whole pace later.
-- Nobody attacks a downed character (data/ai.lua skip_downed_targets; DAG
-- patches in Brawl's Pick.getWeightedTargets and Utils.isValidHostileTarget).
-- Your side (companions and NPC allies "play for the players side"):
-- when Brawl's AI finds nothing for one to do, it attacks the nearest enemy
-- with its weapon (data/ai.lua side); why one did nothing is logged; one
-- whose AI pulse stopped in a fight is logged with its state and restarted.
-- A fight roster (who is on which side, at what pace) is logged 2.5 s in.
-- The enemies' target choice (data/ai.lua targets; playtest 2026-10-14):
-- Brawl kept an enemy's first pick for as long as it stayed within 12 m
-- (AI.act "Remaining on target"), whoever came closer or hit it meanwhile.
-- Now every enemy action re-checks every opponent in the fight (each
-- player, companion and NPC ally) by an effective distance (nearest, who
-- attacked it lately, how many enemies are already on it, the current
-- target a little closer); Brawl's own weighing gets that distance (DAG
-- patch in Pick.getWeightedTargets) and picks again when a better opponent
-- shows up. Each pick and switch is logged with the distances and why.
--
--   !dag_ai on|off   !dag_ai_aim <deg>   !dag_ai_react <ms>   !dag_ai_debug on|off
--   !dag_ai_targets on|off
--   (server console, or the client console: Shared/ConsoleForward.lua)

local Log         = Ext.Require("Shared/Log.lua")
local Hitbox      = Ext.Require("Shared/Hitbox.lua")
local Shield      = Ext.Require("Shared/Shield.lua")
local TickBudget  = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party       = Ext.Require("Server/Party.lua")
local Damage      = Ext.Require("Server/Combat/Damage.lua")
local Shields     = Ext.Require("Server/Combat/Shields.lua")
local Projectiles = Ext.Require("Server/Combat/Projectiles.lua")
local CastRequest = Ext.Require("Server/Combat/CastRequest.lua")
local Brawl       = Ext.Require("Server/BrawlAdapter.lua")
local Bows        = Ext.Require("Server/Combat/Bows.lua")
local bowsCfg     = Ext.Require("data/bows.lua")
local hitboxData  = Ext.Require("data/hitbox.lua")
local cfg         = Ext.Require("data/ai.lua")
local rtCfg       = Ext.Require("data/realtime.lua")
local WEAPONS     = { longsword = Ext.Require("data/weapons/longsword.lua") }

local M = {}

local VISUAL_MELEE = "DAG_V_Target_MainHandAttack"
local ARROW_SPELL = "Projectile_MainHandAttack"
local CLONE_OPTIONS = { "IgnoreHasSpell", "NoMovement", "IgnoreTargetChecks" }

local debugOn = false
local busy = {}         -- uuid -> ms until which Brawl's pulse skips it
local actions = {}      -- running swings / shots / casts
local chainIdx = {}     -- uuid -> last swing index of the weapon chain
local vel = {}          -- uuid -> { p, at, v }
local enemyCache = {}   -- "a|b" -> { v, at }
local weaponCache = {}  -- "uuid|melee" -> { info, at }
local kinds = {}        -- spell -> kind
local reviveHandler = nil
local started = {}      -- uuid -> ms its last action started (the pace)
local retry = {}        -- uuid -> true while an "act again" timer is pending
local pulseSeen = {}    -- uuid -> ms of its last AI pulse (the stall watch)
local stalled = {}      -- uuid -> true once its stall was logged this fight
local idleWhy = {}      -- uuid -> { why, at }: the last "did nothing" logged
local sides = {}        -- uuid -> { v, at }
local threat = {}       -- uuid -> { attacker uuid -> ms it last attacked uuid } (this fight)
local picking = {}      -- uuid -> its target before this AI.act (false = none), while Brawl picks again
local watch = { at = -1e9, fightAt = nil }
local watchSide         -- the stall watch (below, with the sides); the tick calls it

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function noop() end
local function add(a, b, s) s = s or 1; return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function len(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
local function norm(a) local l = len(a); return l > 1e-6 and { a[1] / l, a[2] / l, a[3] / l } or { 0, 0, 1 } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function fmt(p) return p and string.format("(%.2f,%.2f,%.2f)", p[1], p[2], p[3]) or "?" end
local function rand(a, b) return a + (b - a) * math.random() end
local name = Brawl.Name

local function log(s) if cfg.log ~= false then Log.Write(s) end end
local function dbg(s) if debugOn then Log.Write(s) end end

local function feet(uuid)
    local ok, t = pcall(function() return Ext.Entity.Get(uuid).Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    local okP, x, y, z = pcall(function() return Osi.GetPosition(uuid) end)
    if okP and tonumber(x) then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
end

local function eyeOf(uuid)
    local f = feet(uuid)
    if not f then return nil end
    return { f[1], f[2] + hitboxData.height_m * (cfg.melee.eye_frac or 0.85) + Hitbox.Lift(uuid), f[3] }
end

local function canAct(uuid)
    local ok, v = pcall(function() return Utils.canAct(uuid) end)
    if ok then return v == true end
    local okD, dead = pcall(function() return Osi.IsDead(uuid) end)
    return not (okD and tonumber(dead) == 1)
end

local function alive(uuid)
    local okD, dead = pcall(function() return Osi.IsDead(uuid) end)
    if okD and tonumber(dead) == 1 then return false end
    return not Damage.IsDowned(uuid)
end

local function isEnemy(a, b)
    local k = a .. "|" .. b
    local c = enemyCache[k]
    local t = now()
    if c and t - c.at < 5000 then return c.v end
    local ok, v = pcall(function() return Osi.IsEnemy(a, b) end)
    local r = ok and tonumber(v) == 1
    enemyCache[k] = { v = r, at = t }
    return r
end

-- ---------------------------------------------------------------------
-- Spell kinds
-- ---------------------------------------------------------------------
local function rollOf(st)
    local r = ""
    pcall(function() r = tostring(st.SpellRoll.Default or "") end)
    if r == "" or r == "nil" then pcall(function() r = tostring(st.SpellRoll) end) end
    return r
end

local function classify(spell)
    if kinds[spell] then return kinds[spell] end
    local k = "cast"
    local ok, st = pcall(Ext.Stats.Get, spell)
    if ok and st then
        local stype = tostring(st.SpellType or "")
        local roll = rollOf(st)
        local area = tonumber(st.AreaRadius) or 0
        if spell == "Target_Help" then k = "help"
        elseif stype == "Target" and (roll:find("MeleeWeaponAttack", 1, true) or roll:find("MeleeUnarmedAttack", 1, true)
            or roll:find("MeleeOffHandWeaponAttack", 1, true)) then k = "melee"
        elseif stype == "Projectile" and roll:find("RangedWeaponAttack", 1, true) and Projectiles.Def(ARROW_SPELL) then k = "ranged"
        elseif stype == "Projectile" and Projectiles.Def(spell) then k = "projectile"
        elseif area > 0 or stype == "Zone" or stype == "Cone" or stype == "Wall" then k = "area"
        end
    end
    kinds[spell] = k
    log(string.format("AI: %s -> %s", spell, ({ melee = "our swing", ranged = "our arrow (projectile system)",
        projectile = "our projectile system", area = "area: point committed at cast start", help = "our revive",
        cast = "BG3 cast after our cast time" })[k]))
    return k
end

-- ---------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------
local function weaponInfo(uuid, ranged)
    local key = uuid .. (ranged and "|ranged" or "|melee")
    local c = weaponCache[key]
    if c and now() - c.at < 10000 then return c.info end
    local info = { dice = ranged and "1d6" or cfg.melee.unarmed_damage, type = ranged and "Piercing" or "Bludgeoning", mod = 0, name = "unarmed" }
    local item = nil
    pcall(function()
        if ranged then item = Osi.GetEquippedItem(uuid, "Ranged Main Weapon") else item = Osi.GetEquippedWeapon(uuid) end
    end)
    local finesse = false
    if item and item ~= "" then
        pcall(function()
            local statsId = Ext.Entity.Get(item).Data.StatsId
            local st = Ext.Stats.Get(statsId)
            info.name = tostring(statsId)
            info.dice = tostring(st.Damage or info.dice)
            info.type = tostring(st["Damage Type"] or info.type)
            local props = st["Weapon Properties"]
            if type(props) == "table" or type(props) == "userdata" then
                for _, p in ipairs(props) do if tostring(p) == "Finesse" then finesse = true end end
            else
                finesse = tostring(props or ""):find("Finesse", 1, true) ~= nil
            end
        end)
    end
    pcall(function()
        local mods = Ext.Entity.Get(uuid).Stats.AbilityModifiers
        local str, dex = tonumber(mods[2]) or 0, tonumber(mods[3]) or 0
        if ranged then info.mod = dex elseif finesse and dex > str then info.mod = dex else info.mod = str end
    end)
    weaponCache[key] = { info = info, at = now() }
    return info
end

local function weaponDamage(uuid, ranged)
    local w = weaponInfo(uuid, ranged)
    local fixed = tonumber(cfg.melee.damage)
    if fixed then return fixed, w end
    local ok, d = pcall(Damage.Roll, w.dice, w.mod)
    return ok and d or (cfg.melee.fallback_damage or 4), w
end

-- ---------------------------------------------------------------------
-- Velocity (for leads) + the shield facing check
-- ---------------------------------------------------------------------
local velAt = -1e9
local facingLogged = false
local function trackVelocities()
    local t = now()
    if t - velAt < 100 then return end
    velAt = t
    local want = {}
    for _, u in ipairs(Party.Members()) do want[u] = true end
    pcall(function()
        for _, b in pairs(Roster.getBrawlers() or {}) do
            if b.targetUuid then want[Party.Norm(b.targetUuid)] = true end
        end
    end)
    for u in pairs(want) do
        local p = feet(u)
        if p then
            local s = vel[u]
            if s then
                local dt = (t - s.at) / 1000
                if dt > 0.02 then
                    local v = { (p[1] - s.p[1]) / dt, 0, (p[3] - s.p[3]) / dt }
                    if len(v) > 20 then v = { 0, 0, 0 } end   -- a teleport, not a walk
                    s.v = { s.v[1] * 0.5 + v[1] * 0.5, 0, s.v[3] * 0.5 + v[3] * 0.5 }
                    s.p, s.at = p, t
                end
            else
                vel[u] = { p = p, at = t, v = { 0, 0, 0 } }
            end
            local sv = vel[u].v
            if Party.IsMember(u) and len(sv) > 1.2 then
                local okE, e = pcall(Ext.Entity.Get, u)
                if okE and e then
                    local dot, flipped = Shield.CheckFacing(e, sv)
                    if flipped then
                        Log.Write(string.format("Shields: walking characters face the Transform's %sZ, shield discs follow (dot %.2f)",
                            Shield.FwdSign() > 0 and "+" or "-", dot))
                    elseif dot and dot > 0.8 and not facingLogged then
                        facingLogged = true
                        Log.Write(string.format("Shields: facing check OK (%s walks along its forward, dot %.2f)", name(u), dot))
                    end
                end
            end
        end
    end
    for u in pairs(vel) do if not want[u] then vel[u] = nil end end
end

local function velocityOf(uuid)
    local s = vel[Party.Norm(uuid)]
    return s and s.v or { 0, 0, 0 }
end

-- ---------------------------------------------------------------------
-- Aim (ranged / area)
-- ---------------------------------------------------------------------
local function perturb(d, maxDeg)
    if not maxDeg or maxDeg <= 0 then return d, 0 end
    local r = math.sqrt(math.random()) * math.tan(math.rad(maxDeg))
    local th = 2 * math.pi * math.random()
    local up = math.abs(d[2]) < 0.95 and { 0, 1, 0 } or { 1, 0, 0 }
    local a = norm(cross(d, up))
    local b = cross(a, d)
    return norm(add(add(d, a, r * math.cos(th)), b, r * math.sin(th))), math.deg(math.atan(r))
end

-- The aim point on `target` when the shot lands: its cylinder at aim_height,
-- led by its velocity x (reaction + flight time) x lead_skill x jitter.
-- With gravity (arrows) the launch direction is the ballistic one that
-- drops onto that point; the aim error goes on top.
local function aimAt(attacker, target, speed, reactMs, gravity)
    local eye, tf = eyeOf(attacker), feet(target)
    if not eye or not tf then return nil end
    local R = cfg.ranged
    local cyl = Hitbox.Cylinder(target, tf)
    local p = { cyl.x, cyl.y0 + (cyl.y1 - cyl.y0) * (R.aim_height or 0.6), cyl.z }
    local dist = len(sub(p, eye))
    local v = velocityOf(target)
    local lj = R.lead_jitter or { 0.6, 1.2 }
    local skill = (R.lead_skill or 0.6) * rand(lj[1], lj[2])
    local tLead = reactMs / 1000 + dist / math.max(1, speed or 30)
    p = add(p, v, tLead * skill)
    local base, arc = norm(sub(p, eye)), nil
    if gravity and gravity > 0 then
        local bd, ang, far = Projectiles.Ballistic(eye, p, speed or 30, gravity)
        if bd then base, arc = bd, ang
        elseif far then base, arc = far, 45 end   -- out of reach: the longest shot
    end
    local dir, err = perturb(base, R.aim_error_deg)
    return { eye = eye, dir = dir, dist = dist, speed = len(v), skill = skill, lead = len(v) * tLead * skill, err = err, point = p, arc = arc }
end

-- ---------------------------------------------------------------------
-- Melee swing
-- ---------------------------------------------------------------------
local function meleeTest(s, cand, t)
    local f = feet(cand)
    if not f then return nil, "no position" end
    local def = s.def
    local cyl = Hitbox.Cylinder(cand, f, t)
    local surf = Hitbox.Distance(cyl, s.eye)
    if surf > def.reach_m then return nil, string.format("out of reach (%.2f m > %.2f m)", surf, def.reach_m) end
    local dx, dz = cyl.x - s.eye[1], cyl.z - s.eye[3]
    local hd = math.sqrt(dx * dx + dz * dz)
    if hd > 1e-3 then
        local ang = math.deg(math.acos(clamp((dx * s.dir[1] + dz * s.dir[3]) / hd, -1, 1)))
        local angR = math.deg(math.atan(cyl.r / math.max(hd, 0.05)))
        if ang - angR > def.arc_deg_h / 2 then
            return nil, string.format("outside the arc (%.0f deg off the swing, arc +-%.0f)", ang, def.arc_deg_h / 2)
        end
        local hv = math.max(hd, 0.05)
        local upDeg = math.deg(math.atan((cyl.y1 - s.eye[2]) / hv))
        local dnDeg = math.deg(math.atan((cyl.y0 - s.eye[2]) / hv))
        if dnDeg > def.arc_deg_v / 2 or upDeg < -def.arc_deg_v / 2 then
            return nil, string.format("outside the vertical arc (%.0f..%.0f deg, arc +-%.0f)", dnDeg, upDeg, def.arc_deg_v / 2)
        end
        local hy = clamp(s.eye[2] - 0.25, cyl.y0 + 0.2, cyl.y1 - 0.1)
        return { cyl.x - dx / hd * cyl.r, hy, cyl.z - dz / hd * cyl.r }, nil, cyl, surf
    end
    return { cyl.x, clamp(s.eye[2] - 0.25, cyl.y0, cyl.y1), cyl.z }, nil, cyl, surf
end

local function nextSwingDef(attacker)
    local w = WEAPONS[cfg.melee.weapon or "longsword"] or WEAPONS.longsword
    local i = ((chainIdx[attacker] or 0) % #w.chain) + 1
    chainIdx[attacker] = i
    return w.chain[i], i
end

local function melee(attacker, target, spell, onSubmitted, onCompleted, onFailed)
    local def, idx = nextSwingDef(attacker)
    local react = (cfg.melee.reaction_ms or 200) + math.random(0, cfg.melee.reaction_jitter_ms or 0)
    local t = now()
    local lead = cfg.melee.anim_lead_ms or 0
    busy[attacker] = t + react + lead + def.windup_ms + def.active_ms + def.recovery_ms + (cfg.busy_pad_ms or 300)
    pcall(onSubmitted, { RequestGuid = "dag-swing" })
    pcall(function() Osi.SteerTo(attacker, target, 0) end)
    actions[#actions + 1] = { kind = "melee", attacker = attacker, target = target, spell = spell, def = def, idx = idx,
        startAt = t + react, lead = lead, state = "react", hits = {}, results = {}, onCompleted = onCompleted, onFailed = onFailed }
    log(string.format("AI: %s -> swing #%d (%s) at %s in %d ms (Brawl picked %s)", name(attacker), idx, def.name, name(target), react, spell))
end

local function meleeStart(a, t)
    local af, tf = feet(a.attacker), feet(a.target)
    if not af or not tf then a.state, a.why = "done", "no positions"; return end
    a.eye = eyeOf(a.attacker)
    local d = { tf[1] - af[1], 0, tf[3] - af[3] }
    a.dir = norm(d)
    a.activeStart = t + a.def.windup_ms + a.lead
    a.activeEnd = a.activeStart + a.def.active_ms
    a.endAt = a.activeEnd + a.def.recovery_ms
    a.state = "windup"
    local okV = CastRequest.Submit(a.attacker, VISUAL_MELEE, { { uuid = a.target } }, { options = CLONE_OPTIONS })
    dbg(string.format("AI: %s swing #%d committed: eye %s dir (%.2f,%.2f) target %.2f m away, animation %s", name(a.attacker), a.idx,
        fmt(a.eye), a.dir[1], a.dir[3], len(d), okV and VISUAL_MELEE or "clone cast FAILED"))
end

local function meleeCandidates(a)
    local list, seen = { a.target }, { [a.target] = true }
    local af = feet(a.attacker)
    if not af then return list end
    local reach = a.def.reach_m + 1.5
    for u, c in pairs(Projectiles.Near()) do
        if not seen[u] and u ~= a.attacker then
            local f = Projectiles.FeetOf(c.ent)
            if f and math.abs(f[1] - af[1]) < reach and math.abs(f[3] - af[3]) < reach and isEnemy(a.attacker, u) then
                seen[u] = true
                list[#list + 1] = u
            end
        end
    end
    return list
end

local function meleeActive(a, t)
    if a.blocked then return end
    for _, cand in ipairs(meleeCandidates(a)) do
        if not a.hits[cand] and alive(cand) then
            local hp, why, cyl, dist = meleeTest(a, cand, t)
            if not hp then
                a.results[cand] = why
            else
                -- Wall stop: the swing's line to the body hits the world first.
                local L = len(sub(hp, a.eye))
                local dw = Projectiles.WorldHit(a.eye, hp)
                if dw and dw < L - 0.25 then
                    a.blocked = string.format("obstructed by the world at %.2f m of %.2f m (wall stop)", dw, L)
                    return
                end
                a.hits[cand] = true
                local dmg, w = weaponDamage(a.attacker, false)
                local shield = Shields.Has(cand) and Shields.Blocks(cand, a.eye, hp, 0.05)
                local base = dmg
                if shield then dmg = Shields.Reduce(dmg) end
                local dealt = Damage.Apply(cand, dmg, w.type, a.attacker, "AI swing")
                a.results[cand] = string.format("HIT for %d %s (%s %s%+d = %d%s) at %.2f m", dealt, w.type, w.name, w.dice, w.mod, base,
                    shield and string.format(", SHIELD -%.0f %% -> %d", Shield.Reduction() * 100, dmg) or "", dist or 0)
            end
        end
    end
end

local function meleeSummary(a)
    local parts = {}
    for _, cand in ipairs({ a.target }) do
        parts[#parts + 1] = name(cand) .. ": " .. (a.results[cand] or (a.hits[cand] and "HIT" or "not in reach during the swing"))
    end
    for cand, r in pairs(a.results) do
        if cand ~= a.target and a.hits[cand] then parts[#parts + 1] = name(cand) .. ": " .. r end
    end
    log(string.format("AI: %s swing #%d %s%s", name(a.attacker), a.idx, a.blocked and ("BLOCKED, " .. a.blocked .. "; ") or "",
        table.concat(parts, "; ")))
end

-- ---------------------------------------------------------------------
-- Ranged shots
-- ---------------------------------------------------------------------
local function fireShot(a)
    if not canAct(a.attacker) then a.state, a.why = "done", "can't act any more"; return end
    local eye = eyeOf(a.attacker) or a.aim.eye
    local ok, why = Projectiles.Launch(a.attacker, a.proj, { eye = eye, dir = a.aim.dir, targetUuid = a.target, npc = true,
        speed = a.shot and a.shot.speed, gravity = a.shot and a.shot.gravity, dmgMult = a.shot and a.shot.dmgMult },
        function(c, id, p) return CastRequest.AtPosition(c, id, p) end)
    if ok then
        if a.kind == "projectile" and Party.IsMember(a.attacker) == false then
            pcall(function() Resources.deductCastedSpell(a.attacker, a.spell, "dag-shot") end)
        end
        log(string.format("AI: %s fires %s at %s (aimed %d ms ago)", name(a.attacker), a.proj, name(a.target), math.floor(now() - a.aimedAt)))
    else
        log(string.format("AI: %s can't fire %s through our projectiles (%s): BG3 casts %s instead", name(a.attacker), a.proj, tostring(why), a.spell))
        a.fallback = true
    end
end

local function shotAim(a, t)
    -- Weapon shots: the bow / crossbow's speed and the arrow's drop.
    if a.kind == "ranged" then a.shot = Bows.Shot(a.attacker, 1) end
    local speed = a.shot and a.shot.speed or Projectiles.Speed(a.proj) or 30
    local react = (cfg.ranged.reaction_ms or 350) + math.random(0, cfg.ranged.reaction_jitter_ms or 0)
    a.aim = aimAt(a.attacker, a.target, speed, react, a.shot and a.shot.gravity or 0)
    if not a.aim then a.state, a.why = "done", "no positions"; return end
    a.aimedAt = t
    a.fireAt = t + react
    a.state = "aim"
    busy[a.attacker] = a.fireAt + 1500 + (cfg.busy_pad_ms or 300)
    pcall(function() Osi.SteerTo(a.attacker, a.target, 0) end)
    log(string.format("AI: %s aims %s at %s: %.1f m, target moving %.1f m/s, lead %.2f m (skill x%.2f), error %.1f deg%s, fires in %d ms",
        name(a.attacker), a.proj, name(a.target), a.aim.dist, a.aim.speed, a.aim.lead, a.aim.skill, a.aim.err,
        a.aim.arc and string.format(", %.1f deg up for the drop", a.aim.arc) or "", react))
end

local function ranged(attacker, target, spell, kind, onSubmitted, onCompleted, onFailed)
    local t = now()
    local a = { kind = kind, attacker = attacker, target = target, spell = spell, proj = kind == "ranged" and ARROW_SPELL or spell,
        onCompleted = onCompleted, onFailed = onFailed, state = "wait", hits = {} }
    -- A bow draws first (crossbows shoot as before, after the reaction delay).
    if kind == "ranged" then
        local fam = Bows.Family(attacker)
        if fam and fam.kind == "bow" then a.bow = fam end
    end
    -- A projectile spell is channelled first (our cast time), then aimed.
    a.aimAt = t + (kind == "projectile" and (cfg.cast_time_s or 0) * 1000 or 0)
    busy[attacker] = a.aimAt + 3000
    pcall(onSubmitted, { RequestGuid = "dag-shot" })
    actions[#actions + 1] = a
    if kind == "projectile" then
        log(string.format("AI: %s starts casting %s at %s (cast time %.1f s, then aims)", name(attacker), spell, name(target), cfg.cast_time_s or 0))
    end
end

-- ---------------------------------------------------------------------
-- Area spells and plain casts
-- ---------------------------------------------------------------------
local function area(attacker, target, spell, onSubmitted, onCompleted, onFailed)
    local t = now()
    local af, tf = feet(attacker), feet(target)
    if not af or not tf then return onFailed("no positions") end
    local dist = len(sub(tf, af))
    local r = math.sqrt(math.random()) * dist * math.tan(math.rad(cfg.ranged.aim_error_deg or 0))
    local th = 2 * math.pi * math.random()
    local point = { tf[1] + r * math.cos(th), tf[2], tf[3] + r * math.sin(th) }
    local ct = (cfg.cast_time_s or 0) * 1000
    busy[attacker] = t + ct + 1500 + (cfg.busy_pad_ms or 300)
    pcall(onSubmitted, { RequestGuid = "dag-area" })
    actions[#actions + 1] = { kind = "area", attacker = attacker, target = target, spell = spell, point = point, castAt = t + ct,
        state = "wait", onCompleted = onCompleted, onFailed = onFailed }
    pcall(function() Osi.SteerTo(attacker, target, 0) end)
    log(string.format("AI: %s starts casting %s at %s's spot %s (%.1f m off, committed now; cast time %.1f s)", name(attacker), spell,
        name(target), fmt(point), r, ct / 1000))
end

local origUse = nil
local function castLater(attacker, target, spell, isFriendly, onSubmitted, onCompleted, onFailed)
    local t = now()
    local ct = (cfg.cast_time_s or 0) * 1000
    busy[attacker] = t + ct + 8000
    actions[#actions + 1] = { kind = "cast", attacker = attacker, target = target, spell = spell, isFriendly = isFriendly, castAt = t + ct,
        state = "wait", onSubmitted = onSubmitted, onCompleted = onCompleted, onFailed = onFailed }
    log(string.format("AI: %s starts casting %s on %s (cast time %.1f s, then BG3 casts it)", name(attacker), spell, name(target), ct / 1000))
end

-- ---------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------
local function finish(a, ok, why)
    a.state = "done"
    busy[a.attacker] = now() + (cfg.busy_pad_ms or 300)
    if ok then pcall(a.onCompleted or noop, a.spell) else pcall(a.onFailed or noop, why or "failed") end
end

local function afterFire(a, t)
    if a.fallback then
        a.state = "done"
        busy[a.attacker] = t + 8000
        origUse(a.attacker, a.target, a.spell, false, noop, function(...) busy[a.attacker] = now(); pcall(a.onCompleted or noop, ...) end,
            function(...) busy[a.attacker] = now(); pcall(a.onFailed or noop, ...) end)
    elseif a.state ~= "done" then
        a.state, a.doneAt = "flying", t + 600
    end
end

-- Bow: the draw (BG3's clip on every client, Bows.Anim), facing the target.
local function drawStart(a, t)
    a.drawS = Bows.DrawTime(a.attacker)
    a.releaseAt = t + a.drawS * 1000
    a.faceAt = 0
    a.state = "draw"
    busy[a.attacker] = a.releaseAt + 1500 + (cfg.busy_pad_ms or 300)
    pcall(function() if tonumber(Osi.IsWeaponUnsheathed(a.attacker)) ~= 1 then Osi.SetWeaponUnsheathed(a.attacker, 1, 1) end end)
    Bows.Anim(a.attacker, "draw", a.drawS)
    log(string.format("AI: %s draws its %s at %s (%.1f s draw, aims at the release)", name(a.attacker), a.bow.family, name(a.target), a.drawS))
end

local function drawTick(a, t)
    if not canAct(a.attacker) then
        Bows.Anim(a.attacker, "cancel", 0)
        log("AI: " .. name(a.attacker) .. "'s draw interrupted (can't act)")
        finish(a, false, "can't act")
        return
    end
    if t >= a.faceAt then
        a.faceAt = t + ((bowsCfg.npc and bowsCfg.npc.face_every_ms) or 400)
        pcall(function() Osi.SteerTo(a.attacker, a.target, 0) end)
    end
    if t < a.releaseAt then return end
    if not alive(a.target) then
        Bows.Anim(a.attacker, "cancel", 0)
        log("AI: " .. name(a.attacker) .. " lowers its bow (" .. name(a.target) .. " is down)")
        finish(a, false, "target down")
        return
    end
    a.shot = Bows.Shot(a.attacker, 1)
    a.aim = aimAt(a.attacker, a.target, a.shot.speed, 0, a.shot.gravity)
    if not a.aim then
        Bows.Anim(a.attacker, "cancel", 0)
        finish(a, false, "no positions")
        return
    end
    a.aimedAt = t
    log(string.format("AI: %s releases at %s: %.1f m, target moving %.1f m/s, lead %.2f m (skill x%.2f), %.1f deg up for the drop, error %.1f deg",
        name(a.attacker), name(a.target), a.aim.dist, a.aim.speed, a.aim.lead, a.aim.skill, a.aim.arc or 0, a.aim.err))
    fireShot(a)
    Bows.Anim(a.attacker, "release", 0)
    afterFire(a, t)
end

local function step(a, t)
    if a.kind == "melee" then
        if a.state == "react" and t >= a.startAt then
            if not canAct(a.attacker) then finish(a, false, "can't act"); log("AI: " .. name(a.attacker) .. " swing cancelled (can't act)"); return end
            meleeStart(a, t)
        end
        if a.state == "windup" and t >= a.activeStart then a.state = "active" end
        if a.state == "active" then
            if t < a.activeEnd then meleeActive(a, t) else a.state = "recovery"; meleeSummary(a) end
        end
        if a.state == "recovery" and t >= a.endAt then finish(a, true) end
    elseif a.kind == "ranged" or a.kind == "projectile" then
        if a.state == "wait" and t >= a.aimAt then
            if not canAct(a.attacker) then finish(a, false, "can't act"); return end
            if a.bow then drawStart(a, t) else shotAim(a, t) end
        end
        if a.state == "draw" then drawTick(a, t) end
        if a.state == "aim" and t >= a.fireAt then
            fireShot(a)
            afterFire(a, t)
        end
        if a.state == "flying" and t >= a.doneAt then finish(a, true) end
    elseif a.kind == "area" then
        if a.state == "wait" and t >= a.castAt then
            if not canAct(a.attacker) then finish(a, false, "can't act"); log("AI: " .. name(a.attacker) .. " cast of " .. a.spell .. " interrupted"); return end
            local ok = CastRequest.AtPosition(a.attacker, a.spell, a.point)
            local tf = feet(a.target)
            if ok and not Party.IsMember(a.attacker) then pcall(function() Resources.deductCastedSpell(a.attacker, a.spell, "dag-area") end) end
            log(string.format("AI: %s casts %s at %s %s (%s is now %.1f m from that point)", name(a.attacker), a.spell, fmt(a.point),
                ok and "" or "FAILED", name(a.target), tf and len(sub(tf, a.point)) or -1))
            finish(a, ok, "cast failed")
        end
    elseif a.kind == "cast" then
        if a.state == "wait" and t >= a.castAt then
            a.state = "done"
            if not canAct(a.attacker) then busy[a.attacker] = t; pcall(a.onFailed or noop, "can't act"); return end
            if DAG_SkipDownedTargets and not a.isFriendly and a.target ~= a.attacker and Damage.IsDowned(a.target) then
                busy[a.attacker] = t
                log(string.format("AI: %s's %s is dropped: %s went down during the cast time", name(a.attacker), a.spell, name(a.target)))
                pcall(a.onFailed or noop, "target down")
                return
            end
            log(string.format("AI: %s's cast time is over, BG3 casts %s on %s", name(a.attacker), a.spell, name(a.target)))
            origUse(a.attacker, a.target, a.spell, a.isFriendly, a.onSubmitted or noop,
                function(...) busy[a.attacker] = now() + (cfg.busy_pad_ms or 300); pcall(a.onCompleted or noop, ...) end,
                function(...) busy[a.attacker] = now(); pcall(a.onFailed or noop, ...) end)
        end
    end
end

local function tick()
    trackVelocities()
    watchSide(now())
    if #actions == 0 then return end
    local t = now()
    local keep = {}
    for _, a in ipairs(actions) do
        local ok, err = pcall(step, a, t)
        if not ok then
            Log.Write("AI: action error (" .. tostring(a.kind) .. "): " .. tostring(err))
            a.state = "done"
            busy[a.attacker] = t
        end
        if a.state ~= "done" then keep[#keep + 1] = a end
    end
    actions = keep
end

-- ---------------------------------------------------------------------
-- Sides and the pace
-- ---------------------------------------------------------------------
-- "companion" (a party member on Brawl's AI), "ally" (an NPC on the party's
-- side), "enemy" or "neutral", seen from the host.
local function sideOf(u)
    if Party.IsMember(u) then return "companion" end
    local c = sides[u]
    local t = now()
    if c and t - c.at < 10000 then return c.v end
    local v = "neutral"
    pcall(function()
        local host = Osi.GetHostCharacter()
        if tonumber(Osi.IsAlly(host, u)) == 1 then v = "ally"
        elseif tonumber(Osi.IsEnemy(host, u)) == 1 then v = "enemy" end
    end)
    sides[u] = { v = v, at = t }
    return v
end
local function onPlayersSide(u) local s = sideOf(u); return s == "companion" or s == "ally" end

local function isHelper(raw)
    local ok, v = pcall(function() return Utils.isCombatHelper(raw) end)
    return ok and v == true
end

local function controlled(raw)
    local ok, v = pcall(function() return BrawlState.isPlayerControllingDirectly(raw) end)
    return ok and v == true
end

-- Brawl's per-fighter interval: the pace, scaled a little by initiative.
local function paceOf(b)
    return tonumber(b and b.actionInterval) or (tonumber(rtCfg.action_interval_s) or 4) * 1000
end

-- RealTime.pulseAction's checks: would Brawl's own pulse let it act now?
local function pulseWouldRun(b)
    if not b or not b.uuid or not Brawl.Enabled() then return false end
    local raw = b.uuid
    local ok, yes = pcall(function()
        local S = BrawlState.Session
        if not (S.PulseActionTimers and S.PulseActionTimers[raw]) then return false end
        if b.isPaused or S.IsInDialog then return false end
        if b.suppressPulseEventUuid and S.ActiveMovements and S.ActiveMovements[b.suppressPulseEventUuid] then return false end
        if controlled(raw) and not BrawlState.Settings.FullAuto then return false end
        if not Utils.canAct(raw) then return false end
        if tonumber(Osi.IsPlayer(raw)) == 0 and tonumber(Osi.IsInCombat(raw)) == 0 then return false end
        return true
    end)
    return ok and yes == true
end

-- Act again as soon as `due` has passed (one pending timer per fighter; the
-- AI.act wrapper checks the pace again when it fires).
local function actLater(u, raw, due)
    if retry[u] then return end
    retry[u] = true
    local P = cfg.pace or {}
    Ext.Timer.WaitFor(math.max(0, due - now()) + (P.retry_pad_ms or 50), function()
        retry[u] = nil
        local b = nil
        pcall(function() b = Roster.getBrawlerByUuid(raw) end)
        if pulseWouldRun(b) then
            dbg(string.format("AI: %s acts again (its last action is over)", name(u)))
            AI.act(b)
        end
    end)
end

-- The nearest living enemy of u in sight, within maxM.
local function nearestEnemy(u, maxM)
    local best, bestD = nil, nil
    local okB, list = pcall(function() return Roster.getBrawlers() end)
    if not okB or type(list) ~= "table" then return nil end
    for raw in pairs(list) do
        local t = Party.Norm(raw)
        if t and t ~= u and not isHelper(raw) and alive(t) and isEnemy(u, t) then
            local okD, d = pcall(Osi.GetDistanceTo, u, t)
            d = okD and tonumber(d) or nil
            if d and d <= maxM and (not bestD or d < bestD) then
                local okS, sees = pcall(Osi.CanSee, u, t)
                if okS and tonumber(sees) == 1 then best, bestD = t, d end
            end
        end
    end
    return best, bestD
end

-- Your side never stands idle: Brawl found nothing for this companion /
-- ally, so it attacks the nearest enemy with its weapon (our swing / shot).
local function sideAttack(brawler, u, why, onSubmitted, onCompleted, onFailed)
    local S = cfg.side or {}
    if S.fallback == false then return false end
    local target, d = nearestEnemy(u, S.fallback_range_m or 25)
    if not target then return false end
    local ranged = tostring(brawler.archetype or ""):find("ranged") ~= nil and Bows.Family(u) ~= nil and d > (S.melee_m or 3)
    local spell = ranged and ARROW_SPELL or "Target_MainHandAttack"
    brawler.targetUuid = target
    log(string.format("AI: %s (%s) found nothing to do (%s) -> attacks %s with its %s (%.1f m)", name(u), sideOf(u), why,
        name(target), ranged and "ranged weapon" or "weapon", d))
    local ok, err = pcall(Movement.moveIntoPositionForSpell, brawler.uuid, target, spell, false, function()
        Actions.useSpellOnTarget(brawler.uuid, target, spell, false, onSubmitted, onCompleted, onFailed)
    end, onFailed)
    if not ok then
        log("AI: " .. name(u) .. "'s weapon attack failed to start: " .. tostring(err))
        return false
    end
    return true
end

local FALLBACK_ON = {
    ["no hostile actions found"] = true, ["too many exclusions"] = true, ["can't find target"] = true,
    ["no prepared spells"] = true, ["no friendly actions available"] = true,
    ["no direct heals found (self)"] = true, ["no direct heals found (other)"] = true,
}

-- Brawl's AI gave up on a companion / ally this pulse.
local function sideIdle(brawler, u, why, onSubmitted, onCompleted, onFailed)
    why = tostring(why or "?")
    if FALLBACK_ON[why] and sideAttack(brawler, u, why, onSubmitted, onCompleted, onFailed) then return end
    local w = idleWhy[u]
    local t = now()
    if not w or w.why ~= why or t - w.at > ((cfg.side and cfg.side.log_every_s) or 15) * 1000 then
        idleWhy[u] = { why = why, at = t }
        log(string.format("AI: %s (%s) did nothing this pulse: %s", name(u), sideOf(u), why))
    end
    return onFailed(why)
end

-- One line of the state Brawl's pulse looks at (the stall log).
local function pulseState(raw, b)
    local parts = {}
    pcall(function()
        local S = BrawlState.Session
        parts[#parts + 1] = "pulse timer " .. ((S.PulseActionTimers and S.PulseActionTimers[raw]) and "on" or "OFF")
        parts[#parts + 1] = "can act " .. (Utils.canAct(raw) and "yes" or "NO")
        if b.isPaused then parts[#parts + 1] = "PAUSED" end
        if S.IsInDialog then parts[#parts + 1] = "IN DIALOG" end
        if controlled(raw) then parts[#parts + 1] = "controlled by a player" end
        parts[#parts + 1] = "in combat " .. tostring(Osi.IsInCombat(raw))
    end)
    return table.concat(parts, ", ")
end

local function roster()
    local okB, list = pcall(function() return Roster.getBrawlers() end)
    if not okB or type(list) ~= "table" then return end
    local parts = {}
    for raw, b in pairs(list) do
        if not isHelper(raw) then
            local u = Party.Norm(raw)
            if controlled(raw) then parts[#parts + 1] = name(u) .. " (you)"
            else parts[#parts + 1] = string.format("%s (%s, every %.1f s)", name(u), sideOf(u), paceOf(b) / 1000) end
        end
    end
    log("AI: fight roster: " .. (#parts > 0 and table.concat(parts, ", ") or "nobody yet"))
end

-- Companions / allies whose AI pulse stopped in a fight: logged once with
-- the state, and the pulse restarted when Brawl would run it.
function watchSide(t)
    if t - watch.at < 1000 then return end
    watch.at = t
    if not Brawl.Enabled() or not Brawl.InFight() then
        if watch.fightAt then watch.fightAt, stalled, pulseSeen = nil, {}, {} end
        return
    end
    watch.fightAt = watch.fightAt or t
    local okB, list = pcall(function() return Roster.getBrawlers() end)
    if not okB or type(list) ~= "table" then return end
    local S = cfg.side or {}
    for raw, b in pairs(list) do
        local u = Party.Norm(raw)
        if u and not isHelper(raw) and not controlled(raw) and onPlayersSide(u) then
            local last = pulseSeen[u] or watch.fightAt
            local limit = math.max((S.stall_paces or 3) * paceOf(b), (S.stall_min_s or 10) * 1000)
            if t - last > limit and not stalled[u] then
                stalled[u] = true
                local restart = ""
                local okT = pcall(function()
                    local Ss = BrawlState.Session
                    if not (Ss.PulseActionTimers and Ss.PulseActionTimers[raw]) and not b.isPaused and not Ss.IsInDialog
                        and not Pause.isPartyInFTB() and Utils.canAct(raw) then
                        RT.Timers.startPulseAction(b, 0)
                        restart = " -> pulse restarted"
                    end
                end)
                log(string.format("AI: %s (%s) has had no AI pulse for %.0f s (%s)%s", name(u), sideOf(u), (t - last) / 1000,
                    pulseState(raw, b), okT and restart or " (restart check failed)"))
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- The enemies' target choice (data/ai.lua targets)
-- ---------------------------------------------------------------------
local function targetsOn() return cfg.enabled ~= false and type(cfg.targets) == "table" and cfg.targets.enabled ~= false end

-- How many fighters on u's side (u not counted) are on each opponent now.
local function attackersOn(list, u)
    local n, mine = {}, onPlayersSide(u)
    for raw, b in pairs(list) do
        local a = Party.Norm(raw)
        if a and a ~= u and type(b) == "table" and b.targetUuid and not isHelper(raw) and onPlayersSide(a) == mine then
            local t = Party.Norm(b.targetUuid)
            if t then n[t] = (n[t] or 0) + 1 end
        end
    end
    return n
end

-- u's effective distance to opponent t, d metres away (lower = better), and why.
local function effective(u, t, d, cur, counts, at)
    local T = cfg.targets or {}
    local s, why = d, {}
    local hit = threat[u] and threat[u][t]
    if hit and at - hit <= (T.threat_s or 8) * 1000 then
        s = s - (T.threat_m or 0)
        why[#why + 1] = string.format("attacked it %.0f s ago", (at - hit) / 1000)
    end
    local n = math.min(counts[t] or 0, T.spread_max or 3)
    if n > 0 then
        s = s + n * (T.spread_m or 0)
        why[#why + 1] = string.format("%d other%s already on it", n, n == 1 and "" or "s")
    end
    if cur ~= nil and t == cur then s = s - (T.stick_m or 0) end
    return math.max(0, s), why
end

-- Every opponent in the fight u could pick now (players, companions and NPC
-- allies alike: Brawl's roster), best first: { t, d, s, why }.
local function rankTargets(u, cur)
    local okB, list = pcall(function() return Roster.getBrawlers() end)
    if not okB or type(list) ~= "table" then return {} end
    local T = cfg.targets or {}
    local counts, at, out = attackersOn(list, u), now(), {}
    for raw in pairs(list) do
        local t = Party.Norm(raw)
        if t and t ~= u and not isHelper(raw) and alive(t) and isEnemy(u, t) then
            local okD, d = pcall(Osi.GetDistanceTo, u, t)
            d = okD and tonumber(d) or nil
            if d and d <= (T.max_m or 40) then
                local okV, vis = pcall(function() return Utils.isVisible(u, t) end)
                local okS, sees = pcall(Osi.CanSee, u, t)
                if (not okV or vis ~= false) and (t == cur or (okS and tonumber(sees) == 1)) then
                    local s, why = effective(u, t, d, cur, counts, at)
                    out[#out + 1] = { t = t, d = d, s = s, why = why }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.s < b.s end)
    return out
end

-- Brawl's Pick.getWeightedTargets (DAG patch): the distance it weighs for an
-- enemy's hostile candidate. While AI.act re-picks, the target it had keeps
-- its stick bonus.
local function targetDistance(brawler, target, d)
    local u, t = Party.Norm(brawler.uuid), Party.Norm(target)
    if not targetsOn() or not u or not t or onPlayersSide(u) then return d end
    local cur = picking[u]
    if cur == nil then cur = brawler.targetUuid and Party.Norm(brawler.targetUuid) or nil end
    if cur == false then cur = nil end
    local okB, list = pcall(function() return Roster.getBrawlers() end)
    local s = effective(u, t, tonumber(d) or 0, cur, (okB and type(list) == "table") and attackersOn(list, u) or {}, now())
    return s
end

local function describe(r)
    return string.format("%s %.1f m%s", name(r.t), r.d, #r.why > 0 and (" (" .. table.concat(r.why, ", ") .. ")") or "")
end

-- After AI.act: the enemy's new target, with the distances and why.
local function logPick(brawler, u, before, ranked)
    if (cfg.targets or {}).log == false then return end
    local after = brawler.targetUuid and Party.Norm(brawler.targetUuid) or nil
    if not after or after == before then return end
    local mine, nearest, prev, others = nil, nil, nil, {}
    for _, r in ipairs(ranked or {}) do
        if not nearest or r.d < nearest.d then nearest = r end
        if r.t == after then mine = r end
        if r.t == before then prev = r end
    end
    for _, r in ipairs(ranked or {}) do
        if r.t ~= after and #others < 3 then others[#others + 1] = describe(r) end
    end
    local why
    if mine then
        local tags = {}
        if nearest and nearest.t == after then tags[#tags + 1] = "nearest" end
        for _, w in ipairs(mine.why) do tags[#tags + 1] = w end
        if nearest and nearest.t ~= after and #nearest.why > 0 then
            tags[#tags + 1] = string.format("%s is nearer but %s", name(nearest.t), table.concat(nearest.why, ", "))
        end
        if #tags == 0 then tags[1] = "best weight (distance, wounds, sight)" end
        why = string.format("%.1f m, %s", mine.d, table.concat(tags, ", "))
    else
        local okD, d = pcall(Osi.GetDistanceTo, u, after)
        why = string.format("%s m, %s", (okD and tonumber(d)) and string.format("%.1f", tonumber(d)) or "?",
            isEnemy(u, after) and "Brawl's pick, not in sight" or "a friend: Brawl's heal / support pick")
    end
    local was = ""
    if before then
        was = prev and string.format("; was %s, %.1f m", name(before), prev.d) or string.format("; was %s, now down, gone or out of sight", name(before))
    end
    log(string.format("AI: %s %s %s (%s%s) | %s", name(u), before and "switches to" or "targets", name(after), why, was,
        #others > 0 and ("others: " .. table.concat(others, "; ")) or "no other opponent in sight"))
end

-- ---------------------------------------------------------------------
-- Brawl wiring
-- ---------------------------------------------------------------------
-- The arrow's hit (Projectiles impact_mode "weapon"): ranged weapon dice.
local function arrowHit(p, target, pos, zone, shielded)
    if not alive(target) then return "target already down" end
    local dmg, w = weaponDamage(p.caster, true)
    -- The draw (Server/Combat/Bows.lua Shot): x1 at full draw.
    if p.dmgMult and p.dmgMult ~= 1 then dmg = math.max(1, math.floor(dmg * p.dmgMult + 0.5)) end
    local base = dmg
    local mult = Hitbox.ZoneMult(zone or "torso")
    dmg = math.max(1, math.floor(dmg * mult + 0.5))
    local zoned = dmg
    if shielded then dmg = Shields.Reduce(dmg) end
    local dealt = Damage.Apply(target, dmg, w.type, p.caster, "arrow")
    return string.format("%d %s to %s (%s %s%+d = %d%s, %s x%.1f%s)", dealt, w.type, name(target), w.name, w.dice, w.mod, base,
        (p.dmgMult and p.dmgMult ~= 1) and string.format(" after the draw's x%.2f", p.dmgMult) or "", zone or "torso",
        mult, shielded and string.format(", SHIELD %d -> %d", zoned, dmg) or "")
end

function M.SetReviveHandler(h) reviveHandler = h end
function M.Busy(uuid) local b = busy[uuid]; return b and now() < b end

local function wire()
    if origUse then return end
    origUse = Actions.useSpellOnTarget
    Actions.useSpellOnTarget = function(attacker, target, spell, isFriendly, onSubmitted, onCompleted, onFailed)
        onSubmitted, onCompleted, onFailed = onSubmitted or noop, onCompleted or noop, onFailed or noop
        attacker, target = Party.Norm(attacker), Party.Norm(target)
        if cfg.enabled ~= false and attacker then started[attacker] = now() end   -- the pace
        if cfg.enabled == false or not attacker or not target or attacker == target then
            return origUse(attacker, target, spell, isFriendly, onSubmitted, onCompleted, onFailed)
        end
        local kind = classify(spell)
        if kind == "melee" then return melee(attacker, target, spell, onSubmitted, onCompleted, onFailed) end
        if kind == "ranged" or kind == "projectile" then return ranged(attacker, target, spell, kind, onSubmitted, onCompleted, onFailed) end
        if kind == "area" then return area(attacker, target, spell, onSubmitted, onCompleted, onFailed) end
        if kind == "help" and reviveHandler and reviveHandler.Help then
            local took = reviveHandler.Help(attacker, target, onSubmitted, onCompleted, onFailed)
            if took then return end
        end
        return castLater(attacker, target, spell, isFriendly, onSubmitted, onCompleted, onFailed)
    end
    local origAct = AI.act
    AI.act = function(brawler, bonusActionOnly, onSubmitted, onCompleted, onFailed)
        onSubmitted, onCompleted, onFailed = onSubmitted or noop, onCompleted or noop, onFailed or noop
        if cfg.enabled ~= false and brawler and brawler.uuid then
            local u = Party.Norm(brawler.uuid)
            local t = now()
            if stalled[u] then stalled[u] = nil; log("AI: " .. name(u) .. " gets AI pulses again") end
            pulseSeen[u] = t
            -- The pace: its last action still running, or started less than a
            -- pace ago, holds this pulse; it acts again once both are over.
            local b = busy[u]
            local due = math.max(b or 0, (started[u] or -1e9) + paceOf(brawler) - ((cfg.pace and cfg.pace.slack_ms) or 250))
            if t < due then
                if not bonusActionOnly then actLater(u, brawler.uuid, due) end
                return onFailed((b and t < b) and "busy: our swing / shot / cast is running" or "pace: its last action started less than a pace ago")
            end
            if reviveHandler and reviveHandler.Act and reviveHandler.Act(brawler) then return onCompleted("revive") end
            -- Your side: why Brawl gave up is logged, and it attacks with its
            -- weapon instead of standing idle.
            if not bonusActionOnly and onPlayersSide(u) then
                local giveUp = onFailed
                onFailed = function(why) return sideIdle(brawler, u, why, onSubmitted, onCompleted, giveUp) end
            end
            -- The enemies' target choice: a better opponent than the current
            -- one clears it, so Brawl picks again (weighing our distance).
            if targetsOn() and not bonusActionOnly and not onPlayersSide(u) then
                local before = brawler.targetUuid and Party.Norm(brawler.targetUuid) or nil
                local ranked = rankTargets(u, before)
                if before and not brawler.lockedOnTarget and ranked[1] and ranked[1].t ~= before then
                    for _, r in ipairs(ranked) do
                        if r.t == before then
                            if ranked[1].s < r.s then brawler.targetUuid = nil end
                            break
                        end
                    end
                end
                picking[u] = before or false
                local res = table.pack(pcall(origAct, brawler, bonusActionOnly, onSubmitted, onCompleted, onFailed))
                picking[u] = nil
                local okL, errL = pcall(logPick, brawler, u, before, ranked)
                if not okL then dbg("AI: target log failed: " .. tostring(errL)) end
                if not res[1] then error(res[2], 0) end
                return table.unpack(res, 2, res.n)
            end
        end
        return origAct(brawler, bonusActionOnly, onSubmitted, onCompleted, onFailed)
    end
    Log.Write("AI: Brawl's Actions.useSpellOnTarget and AI.act wrapped (melee -> our swing, ranged -> our projectiles, casts -> our cast time)")
end

function M.Register()
    Projectiles.SetWeaponHandler(arrowHit)
    wire()
    DAG_SkipDownedTargets = cfg.skip_downed_targets ~= false   -- Brawl's Pick / Utils (DAG patches)
    -- Brawl's Pick.getWeightedTargets (DAG patch): the enemies' effective distance.
    DAG_TargetDistance = function(brawler, target, d)
        local ok, s = pcall(targetDistance, brawler, target, d)
        return (ok and tonumber(s)) or d
    end
    -- Who attacked whom this fight: the target choice's threat (our hits go
    -- through Osi.ApplyDamage, BG3's casts through its own attacks; both
    -- raise AttackedBy, 7 args as Brawl's Listeners register it).
    Ext.Osiris.RegisterListener("AttackedBy", 7, "after", function(defender, attackerOwner, attacker)
        if not Brawl.InFight() then return end
        local d = Party.Norm(defender)
        if not d then return end
        local t = now()
        threat[d] = threat[d] or {}
        for _, a in ipairs({ Party.Norm(attackerOwner), Party.Norm(attacker) }) do
            if a and a ~= d then threat[d][a] = t end
        end
    end)
    Brawl.Hook("CombatStarted", function() threat, picking = {}, {} end)
    Brawl.Hook("CombatStarted", function() Ext.Timer.WaitFor(2500, roster) end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("NpcCombat", tick))
    ConsoleForward.Server("dag_ai", function(_, a)
        if a == "on" or a == "off" then cfg.enabled = (a == "on") end
        Log.Write("AI: our combat rules for Brawl's AI " .. (cfg.enabled ~= false and "ON" or "OFF (Brawl casts BG3's attacks as before)"))
    end)
    ConsoleForward.Server("dag_ai_aim", function(_, v)
        if tonumber(v) then cfg.ranged.aim_error_deg = math.max(0, tonumber(v)) end
        Log.Write(string.format("AI: aim error cone +-%.1f deg (lead skill %.2f, aim height %.2f)", cfg.ranged.aim_error_deg,
            cfg.ranged.lead_skill, cfg.ranged.aim_height))
    end)
    ConsoleForward.Server("dag_ai_react", function(_, v)
        if tonumber(v) then
            cfg.ranged.reaction_ms = math.max(0, tonumber(v))
            cfg.melee.reaction_ms = math.max(0, tonumber(v))
        end
        Log.Write(string.format("AI: reaction delay %d ms (+0..%d ranged, +0..%d melee)", cfg.ranged.reaction_ms, cfg.ranged.reaction_jitter_ms,
            cfg.melee.reaction_jitter_ms))
    end)
    ConsoleForward.Server("dag_ai_debug", function(_, a)
        debugOn = (a ~= "off" and a ~= "0")
        Log.Write("AI: debug lines " .. (debugOn and "ON" or "OFF"))
    end)
    local function targetsLine()
        local T = cfg.targets or {}
        if not targetsOn() then return "AI: enemies' target choice OFF (Brawl's first pick, kept while within 12 m)" end
        return string.format("AI: enemies' target choice ON: every action re-checks every opponent within %.0f m by distance, -%.1f m if it attacked them in the last %.0f s, +%.1f m per other enemy already on it (max %.0f), -%.1f m for the current target (!dag_ai_targets on|off)",
            T.max_m or 40, T.threat_m or 0, T.threat_s or 8, T.spread_m or 0, T.spread_max or 3, T.stick_m or 0)
    end
    ConsoleForward.Server("dag_ai_targets", function(_, a)
        if type(cfg.targets) ~= "table" then cfg.targets = {} end
        if a == "on" or a == "off" then cfg.targets.enabled = (a == "on") end
        Log.Write(targetsLine())
    end)
    Log.Write(string.format("AI: registered (your side's pace %.1f s, enemies' by BG3's difficulty; %s; aim error %.1f deg, reaction %d+%d ms, lead skill %.2f, melee %s, cast time %.1f s; your side %s)",
        tonumber(rtCfg.action_interval_s) or 4, DAG_SkipDownedTargets and "downed characters are no targets" or "downed characters are targets",
        cfg.ranged.aim_error_deg, cfg.ranged.reaction_ms, cfg.ranged.reaction_jitter_ms,
        cfg.ranged.lead_skill, cfg.melee.weapon, cfg.cast_time_s,
        (cfg.side and cfg.side.fallback == false) and "on Brawl only" or string.format("falls back to weapon attacks within %d m",
            (cfg.side and cfg.side.fallback_range_m) or 25)))
    Log.Write(targetsLine())
end

return M
