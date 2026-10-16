-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points damage (docs/DESIGN.md "Meta-Points", data/metapoints.lua).
--
--   MetaDamage.AttackerMult(source, kind) -> mult, why
--       kind "melee" | "ranged" | "spell". A party member: their STR / DEX /
--       INT damage curve. An enemy of the party: enemy_damage_mult. Anyone
--       else: 1. Our own hit paths call it (HitValidator: the player's swings;
--       NpcCombat: AI swings and every arrow).
--
-- Spell damage is BG3's own (Osi.UseSpell, our impact clones), so it is
-- scaled in SE's server damage events (spell_damage_hook):
--   "before"  BeforeDealDamage: the hit's damage list and totals x mult before
--             BG3 takes the HP, so resistances apply once. Untested in this
--             mod before 2026-10-15, so it checks itself: the target's HP is
--             read 0.4 s after each scaled hit; HP gone by the original amount
--             (not the scaled one) means BG3 ignored the change -> the
--             difference is dealt at once and the hook switches to "after"
--             for the session (logged).
--   "after"   DealtDamage: (mult - 1) x the damage dealt, straight off the HP
--             right after the hit (or healed back for a mult under 1).
--   "off"
-- A hit counts as spell damage when it has a spell id and isn't a weapon /
-- unarmed attack, a fall, a surface or a trap. Only enemies' hits get
-- enemy_damage_mult here (BG3's own spells and attacks); party members'
-- weapon attacks through BG3 (not our swing) are left alone.
--
-- Falls: the party takes no fall damage at all (Server/Combat/NoFallDamage.lua,
-- BG3's IgnoreFallDamage boost); a fall hit seen here is only logged.
--
-- Enemy HP: enemy_hp_mult x max HP when an enemy enters a fight (Osiris
-- EnteredCombat), remembered on the character (DAG_EnemyHp) so it is
-- applied once; nothing happens at 1.0.
--
-- !dag_meta_damage_log on|off: every damage event of the next hits logged.

local Log         = Ext.Require("Shared/Log.lua")
local Party       = Ext.Require("Server/Party.lua")
local Damage      = Ext.Require("Server/Combat/Damage.lua")
local MetaPoints  = Ext.Require("Shared/MetaPoints.lua")

local M = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function cfg() return MetaPoints.Config() end
local name = Damage.Name

local mode = nil          -- the spell_damage_hook in use (nil = the config's)
local verbose = 0         -- damage events still to log in full
local enemyCache = {}     -- uuid -> { at, yes }

local function hookMode() return mode or tostring(cfg().spell_damage_hook or "before") end

-- ---------------------------------------------------------------------
-- Who
-- ---------------------------------------------------------------------
local function isEnemy(uuid)
    local c = enemyCache[uuid]
    local t = now()
    if c and t - c.at < 3000 then return c.yes end
    local yes = false
    pcall(function()
        local host = Osi.GetHostCharacter()
        yes = host ~= nil and tonumber(Osi.IsEnemy(uuid, host)) == 1
    end)
    enemyCache[uuid] = { at = t, yes = yes }
    return yes
end
M.IsEnemy = isEnemy

local KIND_EFFECT = { melee = "melee_damage", ranged = "ranged_damage", spell = "spell_damage" }

function M.AttackerMult(source, kind)
    source = Party.Norm(source)
    if not source then return 1.0, nil end
    if Party.IsMember(source) then
        local id = KIND_EFFECT[kind]
        if not id then return 1.0, nil end
        return MetaPoints.Mult(source, id), id
    end
    local em = tonumber(cfg().enemy_damage_mult) or 1.0
    if math.abs(em - 1.0) > 1e-6 and isEnemy(source) then return em, "enemy_damage_mult" end
    return 1.0, nil
end

-- amount x AttackerMult, rounded, at least 1 if it was at least 1.
function M.Scale(amount, source, kind)
    local mult, why = M.AttackerMult(source, kind)
    if math.abs(mult - 1.0) < 1e-6 then return amount, 1.0, nil end
    local a = tonumber(amount) or 0
    local s = math.floor(a * mult + 0.5)
    if a >= 1 and s < 1 and mult > 0 then s = 1 end
    return s, mult, why
end

-- ---------------------------------------------------------------------
-- Raw HP changes (the "after" hook and its fallbacks)
-- ---------------------------------------------------------------------
-- Takes `amount` straight off the HP (no resistances: they applied to the
-- hit already). A lethal amount goes through Osi.ApplyDamage (BG3's death /
-- downed flow), large enough to beat a resistance.
local function takeRaw(target, amount, damageType, source, why)
    amount = math.floor((tonumber(amount) or 0) + 0.5)
    if amount <= 0 or not target then return end
    local ok, e = pcall(Ext.Entity.Get, target)
    if not ok or not e then return end
    local hp, temp = nil, 0
    pcall(function() hp = tonumber(e.Health.Hp); temp = tonumber(e.Health.TemporaryHp) or 0 end)
    if not hp or hp <= 0 then return end
    if amount < hp + temp then
        local fromTemp = math.min(temp, amount)
        local okW = pcall(function()
            e.Health.TemporaryHp = temp - fromTemp
            e.Health.Hp = hp - (amount - fromTemp)
            e:Replicate("Health")
        end)
        Log.Write(string.format("MetaDamage: %s -%d HP (%s)%s", name(target), amount, why, okW and "" or " (write FAILED)"))
    else
        pcall(function() Osi.ApplyDamage(target, (hp + temp) * 4 + 10, damageType or "Force", source or "NULL_00000000-0000-0000-0000-000000000000") end)
        Log.Write(string.format("MetaDamage: %s takes the killing %d (%s)", name(target), amount, why))
    end
end

-- ---------------------------------------------------------------------
-- Damage events
-- ---------------------------------------------------------------------
local function uuidOf(h)
    if h == nil then return nil end
    local u = nil
    pcall(function() u = h.Uuid.EntityUuid end)
    if not u then pcall(function() u = Ext.Entity.Get(h).Uuid.EntityUuid end) end
    return u and Party.Norm(tostring(u)) or nil
end

local function hpOf(uuid)
    local hp = nil
    pcall(function() hp = tonumber(Ext.Entity.Get(uuid).Health.Hp) end)
    return hp
end

local NOT_SPELL_HIT = { Weapon = true, FallDamage = true, CrushByFall = true, Surface = true, Trap = true }
local WEAPON_ATTACK = { MeleeWeaponAttack = true, RangedWeaponAttack = true, MeleeOffHandWeaponAttack = true,
                        RangedOffHandWeaponAttack = true, MeleeUnarmedAttack = true, RangedUnarmedAttack = true }

-- What a hit is: "spell" | "attack" (BG3 weapon / unarmed attack) | "fall" | nil
local function hitKind(hit)
    local hw, sid, at = "?", "", "?"
    pcall(function() hw = tostring(hit.HitWith) end)
    pcall(function() sid = tostring(hit.SpellId or "") end)
    pcall(function() at = tostring(hit.SpellAttackType) end)
    if hw == "FallDamage" or hw == "CrushByFall" then return "fall", hw, sid, at end
    if sid == "" or sid == "nil" then return nil, hw, sid, at end
    if WEAPON_ATTACK[at] or NOT_SPELL_HIT[hw] then return "attack", hw, sid, at end
    return "spell", hw, sid, at
end

local function total(hit, attack)
    local t = nil
    pcall(function() t = tonumber(hit.TotalDamageDone) end)
    if (not t or t == 0) and attack then pcall(function() t = tonumber(attack.TotalDamageDone) end) end
    return t or 0
end

local function damageType(hit)
    local ty = "Force"
    pcall(function() ty = tostring(hit.DamageType) end)
    if ty == "None" or ty == "nil" or ty == "" then
        pcall(function() ty = tostring(hit.DamageList[1].DamageType) end)
    end
    return ty
end

-- Scale every amount of the hit in place (both descriptions BG3 keeps).
local function scaleHit(hit, attack, mult)
    local function list(l)
        pcall(function()
            for _, pair in ipairs(l) do pair.Amount = math.floor((tonumber(pair.Amount) or 0) * mult + 0.5) end
        end)
    end
    pcall(function() list(hit.DamageList) end)
    pcall(function() list(attack.DamageList) end)
    pcall(function() hit.TotalDamageDone = math.floor((tonumber(hit.TotalDamageDone) or 0) * mult + 0.5) end)
    pcall(function() attack.TotalDamageDone = math.floor((tonumber(attack.TotalDamageDone) or 0) * mult + 0.5) end)
end

-- The functor hit in progress (DealDamage -> BeforeDealDamage -> DealtDamage),
-- so BeforeDealDamage (which has no target) knows whom it is about.
local current = nil

local function logEvent(what, e, extra)
    if verbose <= 0 then return end
    verbose = verbose - 1
    local hit = e.Hit
    local kind, hw, sid, at = hitKind(hit)
    Log.Write(string.format("MetaDamage: event %s kind=%s spell=%s hitWith=%s attackType=%s total=%s inflicter=%s%s", what,
        tostring(kind), sid, hw, at, tostring(total(hit, e.Attack)), tostring(uuidOf(hit and hit.Inflicter)), extra or ""))
end

-- The multiplier for a spell / BG3-attack hit from `src` (nil = none).
local function hitMult(kind, src)
    if not src or (kind ~= "spell" and kind ~= "attack") then return nil end
    if Party.IsMember(src) then
        if kind ~= "spell" then return nil end
        local m = MetaPoints.Mult(src, "spell_damage")
        return math.abs(m - 1) > 1e-6 and m or nil, "INT"
    end
    local em = tonumber(cfg().enemy_damage_mult) or 1.0
    if math.abs(em - 1) > 1e-6 and isEnemy(src) then return em, "enemy" end
    return nil
end

-- "before" verification: the target's HP 0.4 s after a scaled hit.
local function verify(target, hp0, orig, scaled, dtype, src, spell)
    if not target or not hp0 or orig == scaled then return end
    local t1 = now() + 400
    local function check()
        if now() < t1 then Ext.OnNextTick(check); return end
        local hp1 = hpOf(target)
        if not hp1 then return end
        local drop = hp0 - hp1
        if hp1 <= 0 then
            Log.Write(string.format("MetaDamage: %s's %s check: %s is down (HP %d -> %d), inconclusive", name(src), spell, name(target), hp0, hp1))
        elseif math.abs(drop - scaled) <= 1 then
            if not M.beforeVerified then
                M.beforeVerified = true
                Log.Write(string.format("MetaDamage: BEFORE-HOOK WORKS: %s's %s took %d HP from %s (BG3 rolled %d, scaled to %d)",
                    name(src), spell, drop, name(target), orig, scaled))
            end
        elseif math.abs(drop - orig) <= 1 then
            Log.Write(string.format("MetaDamage: BEFORE-HOOK IGNORED: %s's %s took %d HP (BG3's %d, not the scaled %d) -> the difference now, and \"after\" for this session",
                name(src), spell, drop, orig, scaled))
            mode = "after"
            if scaled > orig then takeRaw(target, scaled - orig, dtype, src, "spell damage, after the ignored before-hook")
            else Damage.HealBack(target, orig - scaled, "damage mult under 1, after the ignored before-hook") end
        else
            Log.Write(string.format("MetaDamage: %s's %s check inconclusive (HP %d -> %d: %d gone; BG3 %d, scaled %d)",
                name(src), spell, hp0, hp1, drop, orig, scaled))
        end
    end
    Ext.OnNextTick(check)
end

local function onBefore(e)
    local hit, attack = e.Hit, e.Attack
    local kind, hw, sid = hitKind(hit)
    logEvent("BeforeDealDamage", e, current and string.format(" target=%s", tostring(current.target)) or "")
    if kind == "fall" then
        -- The party has IgnoreFallDamage (NoFallDamage.lua); an enemy's fall is BG3's.
        local fallH = nil
        pcall(function() fallH = tonumber(hit.FallHeight) end)
        local who = uuidOf(hit.Inflicter) or uuidOf(hit.InflicterOwner)
        Log.Write(string.format("MetaDamage: fall damage %d (%s m fall)%s", total(hit, attack), fallH and string.format("%.1f", fallH) or "?",
            who and (" on or by " .. name(who) .. (Party.IsMember(who) and ": a party member, the no-fall-damage status was missing?" or "")) or ""))
        return
    end
    if hookMode() ~= "before" then return end
    local src = (current and current.caster) or uuidOf(hit.Inflicter) or uuidOf(hit.InflicterOwner)
    local mult, why = hitMult(kind, src)
    if not mult then return end
    local orig = total(hit, attack)
    if orig <= 0 then return end
    scaleHit(hit, attack, mult)
    local scaled = total(hit, attack)
    local target = current and current.target or nil
    Log.Write(string.format("MetaDamage: %s's %s on %s: %d -> %d (%s x%.2f, before)", name(src), sid, target and name(target) or "?",
        orig, scaled, why, mult))
    if current and not M.beforeVerified then verify(target, current.hp0, orig, scaled, damageType(hit), src, sid) end
end

local function onDeal(e)
    local caster, target = uuidOf(e.Caster), uuidOf(e.Target)
    current = { caster = caster, target = target, hp0 = target and hpOf(target) or nil }
    logEvent("DealDamage", e, string.format(" caster=%s target=%s", tostring(caster), tostring(target)))
end

local function onDealt(e)
    local c = current
    current = nil
    logEvent("DealtDamage", e)
    if hookMode() ~= "after" then return end
    local hit = e.Hit
    pcall(function() if e.Result and e.Result.Hit then hit = e.Result.Hit end end)
    local kind, _, sid = hitKind(hit)
    local src = (c and c.caster) or uuidOf(e.Caster)
    local target = (c and c.target) or uuidOf(e.Target)
    local mult, why = hitMult(kind, src)
    if not mult or not target then return end
    local dealt = total(hit, nil)
    if dealt <= 0 then return end
    local dtype = damageType(hit)
    if mult > 1 then
        Ext.OnNextTick(function() takeRaw(target, dealt * (mult - 1), dtype, src, string.format("%s's %s, %s x%.2f after %d", name(src), sid, why, mult, dealt)) end)
    else
        Ext.Timer.WaitFor(400, function() Damage.HealBack(target, dealt * (1 - mult), string.format("%s x%.2f", why, mult)) end)
    end
end

-- ---------------------------------------------------------------------
-- Enemy HP
-- ---------------------------------------------------------------------
local hpVar = MetaPoints.ENEMY_HP_VAR
local function scaleEnemyHp(uuid)
    local want = tonumber(cfg().enemy_hp_mult) or 1.0
    local e = Ext.Entity.Get(uuid)
    if not e or not e.Health then return end
    local rec = nil
    pcall(function() rec = e.Vars[hpVar] end)
    local maxNow = tonumber(e.Health.MaxHp) or 0
    local from = 1.0
    if type(rec) == "table" and tonumber(rec.max) == maxNow then from = tonumber(rec.mult) or 1.0 end
    if math.abs(want - from) < 1e-3 or maxNow <= 0 then return end
    local f = want / from
    local newMax = math.max(1, math.floor(maxNow * f + 0.5))
    local newHp = math.max(1, math.floor((tonumber(e.Health.Hp) or maxNow) * f + 0.5))
    e.Health.MaxHp = newMax
    e.Health.Hp = math.min(newMax, newHp)
    e:Replicate("Health")
    e.Vars[hpVar] = { mult = want, max = newMax }
    Log.Write(string.format("MetaDamage: enemy %s max HP %d -> %d (enemy_hp_mult %.2f)", name(uuid), maxNow, newMax, want))
end

-- ---------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------
local function subscribe(evName, fn)
    local ok, err = pcall(function() Ext.Events[evName]:Subscribe(function(e) local okE, errE = pcall(fn, e); if not okE then Log.Write("MetaDamage: " .. evName .. " error " .. tostring(errE)) end end) end)
    return ok, err
end

function M.Register()
    local parts = {}
    for _, ev in ipairs({ { "DealDamage", onDeal }, { "BeforeDealDamage", onBefore }, { "DealtDamage", onDealt } }) do
        local ok, err = subscribe(ev[1], ev[2])
        parts[#parts + 1] = ev[1] .. (ok and " ok" or (" FAILED (" .. tostring(err) .. ")"))
    end
    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(obj)
        local u = Party.Norm(obj)
        if not u or Party.IsMember(u) then return end
        if math.abs((tonumber(cfg().enemy_hp_mult) or 1) - 1) < 1e-3 then
            -- 1.0: only an earlier scaling (another value) is put back.
            local rec = nil
            pcall(function() rec = Ext.Entity.Get(u).Vars[hpVar] end)
            if type(rec) ~= "table" then return end
        end
        if not isEnemy(u) then return end
        local ok, err = pcall(scaleEnemyHp, u)
        if not ok then Log.Write("MetaDamage: enemy HP error " .. tostring(err)) end
    end)
    Ext.RegisterConsoleCommand("dag_meta_damage_log", function(_, v)
        verbose = (v == "off") and 0 or 40
        Log.Write("MetaDamage: " .. (verbose > 0 and "the next 40 damage events are logged" or "damage event log off")
            .. " (spell damage hook: " .. hookMode() .. ")")
    end)
    -- The first damage events of every session, for the record (the hook is new).
    verbose = 12
    Log.Write("MetaDamage: registered (server damage events: " .. table.concat(parts, ", ") .. "; spell damage hook " .. hookMode() .. ")")
end

function M.Describe()
    return "damage events: spell damage hook " .. hookMode() .. (M.beforeVerified and " (before-hook verified this session)" or "")
end

return M
