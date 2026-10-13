local debugPrint = Utils.debugPrint
local debugDump = Utils.debugDump

local function getNumExtraAttacks(entityUuid)
    if M.Osi.HasPassive(entityUuid, "ExtraAttack_3") == 1 or M.Osi.HasPassive(entityUuid, "WildStrike_3") == 1 or M.Osi.HasPassive(entityUuid, "Slayer_ExtraAttack_3") == 1 then
        return 3
    elseif M.Osi.HasPassive(entityUuid, "ExtraAttack_2") == 1 or M.Osi.HasPassive(entityUuid, "WildStrike_2") == 1 or M.Osi.HasPassive(entityUuid, "Slayer_ExtraAttack_2") == 1 then
        return 2
    elseif M.Osi.HasPassive(entityUuid, "ExtraAttack") == 1 or M.Osi.HasPassive(entityUuid, "WildStrike") == 1 or M.Osi.HasPassive(entityUuid, "Slayer_ExtraAttack") == 1 then
        return 1
    end
    return 0
end

local function addBrawler(entityUuid, replaceExistingBrawler)
    if entityUuid ~= nil then
        local level = M.Osi.GetRegion(entityUuid)
        local okToAdd = false
        if replaceExistingBrawler then
            okToAdd = level and BrawlState.Session.Brawlers[level] ~= nil and M.Utils.isAliveAndCanFight(entityUuid)
        else
            okToAdd = level and BrawlState.Session.Brawlers[level] ~= nil and BrawlState.Session.Brawlers[level][entityUuid] == nil and M.Utils.isAliveAndCanFight(entityUuid)
        end
        if BrawlState.Settings.TurnBasedSwarmMode and M.Utils.isToT() and Mods.ToT.PersistentVars.Scenario and entityUuid == Mods.ToT.PersistentVars.Scenario.CombatHelper then
            okToAdd = true
        end
        if okToAdd then
            local displayName = M.Utils.getDisplayName(entityUuid)
            local entity = Ext.Entity.Get(entityUuid)
            local existingBrawler = BrawlState.Session.Brawlers[level][entityUuid]
            -- Preserve actionInterval from any existing brawler entry within this combat.  The first addBrawler call (at first EnteredCombat) computes
            -- from the natural rolled init before our bumps fire; subsequent re-adds (level changes, party joins, etc.) would otherwise read the bumped InitiativeRoll.
            -- DAG: each side's own pace (enemies: BG3's difficulty; Server/Combat/Pace.lua)
            local actionInterval = existingBrawler and existingBrawler.actionInterval
                or (DAG_ActionInterval and DAG_ActionInterval(entityUuid, TurnOrder.getInitiativeRoll(entityUuid)))
                or TurnOrder.calculateActionInterval(TurnOrder.getInitiativeRoll(entityUuid))
            local brawler = {
                uuid = entityUuid,
                displayName = displayName,
                combatGuid = M.Osi.CombatGetGuidFor(entityUuid),
                combatGroupId = M.Osi.GetCombatGroupID(entityUuid),
                isPaused = M.Osi.IsInForceTurnBasedMode(entityUuid) == 1,
                archetype = BrawlState.getArchetype(entityUuid),
                numExtraAttacks = getNumExtraAttacks(entityUuid),
                actionInterval = actionInterval,
                auras = Spells.getAuras(entityUuid),
            }
            if existingBrawler and existingBrawler.actionResources then
                brawler.actionResources = existingBrawler.actionResources
            else
                -- does this work for entities that get pulled out of the brawl and then re-entered?
                brawler.actionResources = {}
                for _, resourceType in ipairs(Constants.PER_TURN_ACTION_RESOURCES) do
                    brawler.actionResources[resourceType] = {amount = M.Resources.getActionResourceAmount(entity, resourceType), refillQueue = {}}
                end
                brawler.actionResources.listener = Ext.Entity.Subscribe("ActionResources", Resources.actionResourcesCallback, entity)
            end
            if BrawlState.getArchetype(entityUuid) == "barbarian" then
                brawler.rage = Spells.getRageAbility(entityUuid)
                debugPrint(displayName, "barbarian archetype, setting rage", brawler.rage)
            end
            debugPrint(displayName, "Adding Brawler", entityUuid, brawler.actionInterval)
            local modVars = Ext.Vars.GetModVariables(ModuleUUID)
            modVars.ModifiedHitpoints = modVars.ModifiedHitpoints or {}
            BrawlState.revertHitpoints(entityUuid)
            BrawlState.modifyHitpoints(entityUuid)
            Osi.SetCanJoinCombat(entityUuid, 1)
            if BrawlState.Settings.TurnBasedSwarmMode then
                BrawlState.Session.Brawlers[level][entityUuid] = brawler
                if M.Osi.IsPartyMember(entityUuid, 1) ~= 1 then
                    BrawlState.Session.SwarmTurnComplete[entityUuid] = false
                    Osi.PROC_SelfHealing_Disable(entityUuid)
                elseif BrawlState.Session.TurnBasedSwarmModePlayerTurnEnded[entityUuid] == nil then
                    local newFlag = M.Utils.isPlayerTurnEnded(entityUuid)
                    BrawlState.Session.TurnBasedSwarmModePlayerTurnEnded[entityUuid] = newFlag
                    debugPrint("[LATEJOIN] addBrawler player", displayName,
                        "round=", TurnOrder.getCurrentCombatRound(),
                        "RequestedEndTurn=", entity.TurnBased and tostring(entity.TurnBased.RequestedEndTurn) or "no-tb",
                        "IsActiveCombatTurn=", entity.TurnBased and tostring(entity.TurnBased.IsActiveCombatTurn) or "no-tb",
                        "HadTurnInCombat=", entity.TurnBased and tostring(entity.TurnBased.HadTurnInCombat) or "no-tb",
                        "ActedThisRoundInCombat=", entity.TurnBased and tostring(entity.TurnBased.ActedThisRoundInCombat) or "no-tb",
                        "newFlag=", tostring(newFlag))
                end
            else
                if Osi.IsPlayer(entityUuid) == 0 then
                    -- thank u lunisole/ghostboats
                    Osi.PROC_SelfHealing_Disable(entityUuid)
                end
                BrawlState.Session.Brawlers[level][entityUuid] = brawler
                if M.Osi.IsInForceTurnBasedMode(M.Osi.GetHostCharacter()) == 0 then
                    -- Only pre-pause fresh entries (pre-APoCS); re-adds after APoCS would silently freeze the brawler.
                    if BrawlState.Settings.AutoPauseOnCombatStart and not BrawlState.Session.APoCSScheduled then
                        brawler.isPaused = true
                    elseif BrawlState.Session.IsInDialog then
                        -- Don't start pulse actions for new combat entrants while a dialog/cutscene is in progress, otherwise turned-during-cutscene
                        -- enemies start spellcasting mid-cutscene and interrupt it.
                    elseif BrawlState.Session.PulseActionTimers[entityUuid] == nil then
                        RT.Timers.startPulseAction(brawler, Constants.INITIAL_PULSE_ACTION_DELAY)
                    end
                else
                    if not existingBrawler then
                        Utils.clearOsirisQueue(entityUuid)
                    end
                    RT.Timers.stopPulseAction(brawler)
                    Osi.ForceTurnBasedMode(entityUuid, 1)
                    if not BrawlState.Session.Players[entityUuid] then
                        brawler.isPaused = true
                        if BrawlState.Settings.TruePause then
                            Pause.startTruePause(entityUuid)
                            Pause.lock(Ext.Entity.Get(entityUuid))
                        end
                    end
                end
            end
            -- DAG: Brawl's summon reaction override (Loadouts.lua) stripped
        end
    end
end

local function removeBrawler(level, entityUuid)
    local combatGuid = nil
    local brawlersInLevel = BrawlState.Session.Brawlers[level]
    if brawlersInLevel then
        for brawlerUuid, brawler in pairs(brawlersInLevel) do
            if brawler.targetUuid == entityUuid then
                brawler.targetUuid = nil
                brawler.lockedOnTarget = nil
                Utils.clearOsirisQueue(brawlerUuid)
            end
        end
        if brawlersInLevel[entityUuid] then
            local actionResources = brawlersInLevel[entityUuid].actionResources
            if actionResources then
                for _, resourceType in ipairs(Constants.PER_TURN_ACTION_RESOURCES) do
                    if actionResources[resourceType] and actionResources[resourceType].refillQueue then
                        for _, actionResourceTimer in ipairs(actionResources[resourceType].refillQueue) do
                            Ext.Timer.Cancel(actionResourceTimer)
                        end
                    end
                end
                if actionResources.listener then
                    Ext.Entity.Unsubscribe(actionResources.listener)
                end
            end
            RT.Timers.stopPulseAction(brawlersInLevel[entityUuid])
            brawlersInLevel[entityUuid] = nil
        end
        Osi.SetCanJoinCombat(entityUuid, 1)
        Osi.RequestSetSwarmGroup(entityUuid, "")
        if M.Osi.IsPartyMember(entityUuid, 1) == 0 then
            BrawlState.revertHitpoints(entityUuid)
        else
            BrawlState.Session.PlayerCurrentTarget[entityUuid] = nil
            BrawlState.Session.PlayerMarkedTarget[entityUuid] = nil
            BrawlState.Session.IsAttackingOrBeingAttackedByPlayer[entityUuid] = nil
        end
        if BrawlState.Session.SwarmTurnComplete[entityUuid] ~= nil then
            BrawlState.Session.SwarmTurnComplete[entityUuid] = true
        end
        if BrawlState.Session.ResurrectedPlayer[entityUuid] ~= nil then
            BrawlState.Session.ResurrectedPlayer[entityUuid] = nil
        end
    end
end

local function addCombatParticipantsToBrawlers()
    local combatEntity = Utils.getCombatEntity()
    if combatEntity and combatEntity.CombatState and combatEntity.CombatState.Participants then
        for _, participant in ipairs(combatEntity.CombatState.Participants) do
            debugPrint(M.Utils.getDisplayName(participant.Uuid.EntityUuid), "adding to brawlers")
            Osi.RequestSetSwarmGroup(participant.Uuid.EntityUuid, "")
            addBrawler(participant.Uuid.EntityUuid)
        end
    end
end

local function endBrawl(level)
    -- Skip during pause -- IsInCombat flicker during NPC-on-NPC see-saw can otherwise tear down state mid-FTB
    if M.Pause and M.Pause.isPartyInFTB() then
        debugPrint("endBrawl skipped (party in FTB)", level)
        return
    end
    debugPrint("endBrawl", level)
    local brawlersInLevel = BrawlState.Session.Brawlers[level]
    if brawlersInLevel then
        local uuids = {}
        for brawlerUuid, _ in pairs(brawlersInLevel) do
            table.insert(uuids, brawlerUuid)
        end
        for _, brawlerUuid in ipairs(uuids) do
            local combatGuid = M.Osi.CombatGetGuidFor(brawlerUuid)
            removeBrawler(level, brawlerUuid)
            if combatGuid then
                Osi.EndCombat(combatGuid)
            end
        end
        debugDump(brawlersInLevel)
    end
    if BrawlState.Session.CombatHelper then
        Utils.remove(BrawlState.Session.CombatHelper)
        BrawlState.Session.CombatHelper = nil
    end
    for combatGuid, refreshers in pairs(BrawlState.Session.RefresherCombatHelper) do
        for _, refresherUuid in ipairs(refreshers) do
            Utils.remove(refresherUuid)
        end
    end
    BrawlState.Session.RefresherCombatHelper = {}
    BrawlState.Session.ActiveCombatGroups = {}
    BrawlState.Session.Brawlers[level] = {}
    BrawlState.Session.StoryActionIDs = {}
    BrawlState.Session.SwarmTurnComplete = {}
    BrawlState.Session.ActionsInProgress = {}
    BrawlState.Session.MeanInitiativeRoll = nil
    TurnOrder.clearAllNaturalInitiative() -- DAG: Encounters stripped
    BrawlState.Session.ExtraAttacksRemaining = {}
    BrawlState.Session.FTBLockedIn = {}
    BrawlState.Session.MovementQueue = {}
    BrawlState.Session.PreExistingCastAtPause = {}
    BrawlState.Session.IsAttackingOrBeingAttackedByPlayer = {}
    -- Cancel any pending heal-request timers before zeroing (the values are timer handles)
    for _, timerHandle in pairs(BrawlState.Session.HealRequestedTimer) do
        Ext.Timer.Cancel(timerHandle)
    end
    BrawlState.Session.HealRequestedTimer = {}
    BrawlState.Session.HealRequested = {}
    -- DAG: Swarm Mode stripped
end

local function getBrawlerByUuid(uuid)
    local level = M.Osi.GetRegion(uuid)
    if level and BrawlState.Session.Brawlers[level] then
        return BrawlState.Session.Brawlers[level][uuid]
    end
    return nil
end

local function getBrawlerByName(name)
    local hostCharacter = M.Osi.GetHostCharacter()
    if hostCharacter then
        local level = M.Osi.GetRegion(hostCharacter)
        if level and BrawlState.Session.Brawlers then
            local brawlersInLevel = BrawlState.Session.Brawlers[level]
            if brawlersInLevel then
                for uuid, brawler in pairs(brawlersInLevel) do
                    if brawler.displayName == name then
                        return brawler
                    end
                end
            end
        end
    end
end

local function getBrawlersSortedByDistance(entityUuid)
    local brawlersSortedByDistance = {}
    local level = M.Osi.GetRegion(entityUuid)
    local brawlersInLevel = BrawlState.Session.Brawlers[level]
    if brawlersInLevel then
        for brawlerUuid, brawler in pairs(brawlersInLevel) do
            if M.Utils.isOnSameLevel(brawlerUuid, entityUuid) and M.Utils.isAliveAndCanFight(brawlerUuid) then
                table.insert(brawlersSortedByDistance, {brawlerUuid, M.Osi.GetDistanceTo(entityUuid, brawlerUuid)})
            end
        end
        table.sort(brawlersSortedByDistance, function (a, b) return a[2] < b[2] end)
    end
    return brawlersSortedByDistance
end

local function addPlayersInEnterCombatRangeToBrawlers(brawlerUuid)
    local players = BrawlState.Session.Players
    for playerUuid, _ in pairs(players) do
        local distanceTo = M.Osi.GetDistanceTo(brawlerUuid, playerUuid)
        if distanceTo ~= nil and distanceTo < Constants.ENTER_COMBAT_RANGE then
            addBrawler(playerUuid)
        end
    end
end

local function disableLockedOnTarget(uuid)
    local level = M.Osi.GetRegion(uuid)
    if level and M.Utils.isAliveAndCanFight(uuid) then
        local brawlersInLevel = BrawlState.Session.Brawlers[level]
        if brawlersInLevel[uuid] then
            brawlersInLevel[uuid].lockedOnTarget = false
        end
    end
end

local function checkForEndOfBrawl(level)
    local numEnemiesRemaining = M.State.getNumEnemiesRemaining(level)
    debugPrint("Number of enemies remaining:", numEnemiesRemaining)
    if numEnemiesRemaining == 0 then
        endBrawl(level)
    end
end

-- Shared death cleanup: lay the body flat, remove from brawler table, check if combat ended.
-- Runs in both RT and Swarm modes. Called from each mode's onDied handler.
local function handleDeath(level, entityUuid)
    if level and entityUuid and BrawlState.Session.Brawlers[level] and BrawlState.Session.Brawlers[level][entityUuid] then
        Ext.Timer.WaitFor(Constants.LIE_ON_GROUND_TIMEOUT, function ()
            debugPrint("LieOnGround", entityUuid)
            Utils.clearOsirisQueue(entityUuid)
            Osi.LieOnGround(entityUuid)
        end)
        removeBrawler(level, entityUuid)
        checkForEndOfBrawl(level)
    end
end

local function initBrawlers(level)
    BrawlState.Session.Brawlers[level] = {}
    local players = BrawlState.Session.Players
    for playerUuid, _ in pairs(players) do
        if Osi.IsInCombat(playerUuid) == 1 then
            Listeners.onCombatStarted(M.Osi.CombatGetGuidFor(playerUuid))
            break
        end
    end
end

local function getBrawlers()
    if not BrawlState.Session.Brawlers then
        return {}
    end
    local region = M.Utils.getCurrentRegion()
    if not BrawlState.Session.Brawlers[region] then
        return {}
    end
    return BrawlState.Session.Brawlers[region]
end

local function setExcludedFromAI(uuid, isExcluded)
    BrawlState.Session.ExcludedFromAI[uuid] = isExcluded
end

local function isExcludedFromAI(uuid)
    return BrawlState.Session.ExcludedFromAI[uuid]
end

return {
    getBrawlerByUuid = getBrawlerByUuid,
    getBrawlerByName = getBrawlerByName,
    addBrawler = addBrawler,
    removeBrawler = removeBrawler,
    addCombatParticipantsToBrawlers = addCombatParticipantsToBrawlers,
    endBrawl = endBrawl,
    getBrawlersSortedByDistance = getBrawlersSortedByDistance,
    addPlayersInEnterCombatRangeToBrawlers = addPlayersInEnterCombatRangeToBrawlers,
    disableLockedOnTarget = disableLockedOnTarget,
    checkForEndOfBrawl = checkForEndOfBrawl,
    handleDeath = handleDeath,
    initBrawlers = initBrawlers,
    getBrawlers = getBrawlers,
    setExcludedFromAI = setExcludedFromAI,
    isExcludedFromAI = isExcludedFromAI,
}
