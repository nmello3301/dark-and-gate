-- DAG: ECSPrinter (Brawl's debug printer) not imported

local debugPrint = Utils.debugPrint
local debugDump = Utils.debugDump

local function cleanupAll()
    RT.Timers.stopAllPulseActionTimers()
    Movement.removeAllDashSpeedBoosts()
    BrawlState.endBrawls()
    BrawlState.revertAllModifiedHitpoints()
    BrawlState.recapMovementDistances()
    Spells.resetSpellData()
end

local function onGameStateChanged(e)
    if e and e.ToState == "UnloadLevel" then
        cleanupAll()
    end
end

local function onStarted(level)
    debugPrint("onStarted")
    M.memoizeAll()
    Spells.resetSpellData()
    Spells.buildSpellTable()
    BrawlState.setMaxPartySize()
    BrawlState.resetPlayers()
    BrawlState.setIsControllingDirectly()
    Movement.setMovementSpeedThresholds()
    BrawlState.setupPartyMembersHitpoints()
    Roster.initBrawlers(level)
    RT.Listeners.onStarted() -- DAG: Swarm Mode, Leaderboard and the client "Started" message stripped
    debugDump(BrawlState.Session.Players)
end

local function onCombatStarted(combatGuid)
    debugPrint("CombatStarted", combatGuid)
    -- Preserve each user's pre-combat selection: by the time CombatStarted fires "after", the engine may have already swapped control to the
    -- highest-init character.  Capture the actual pre-combat controlled-char from LastControlledUuid (updated by setIsControllingDirectly), set
    -- up an expectation window, and re-assert immediately.  onGainedControl will keep correcting wrong-char picks during the window.
    if BrawlState.Session.LastControlledUuid and next(BrawlState.Session.LastControlledUuid) then
        local expectedByUser = {}
        for userId, uuid in pairs(BrawlState.Session.LastControlledUuid) do
            expectedByUser[userId] = uuid
            RT.sendSelectCharacter(uuid, "Listeners.onCombatStarted")
        end
        BrawlState.Session.ExpectedControlled = expectedByUser
        BrawlState.Session.ExpectedControlledExpiresAt = Ext.Utils.MonotonicTime() + 3000
    end
    -- DAG: Swarm Mode stripped
    -- NB: clean this up / don't reassign "constant" values
    if Utils.isToT() then
        if Mods.ToT.PersistentVars.Scenario and Mods.ToT.PersistentVars.Scenario.Round == 0 then
            BrawlState.Session.TBSMToTSkippedPrepRound = false
        else
            BrawlState.Session.TBSMToTSkippedPrepRound = true
        end
        Constants.ENTER_COMBAT_RANGE = 100
    else
        Constants.ENTER_COMBAT_RANGE = 20
    end
    Roster.addCombatParticipantsToBrawlers()
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onCombatStarted(combatGuid)
    end
end

local function onResetCompleted()
    debugPrint("ResetCompleted")
    -- if Printer then Printer:Start() end
    onStarted(Osi.GetRegion(Osi.GetHostCharacter()))
end

-- New user joined (multiplayer).  Also fires whenever UserReservedFor changes on any entity, including engine-driven reassignments at FTB entry.
local function onUserReservedFor(entity, _, _)
    BrawlState.setIsControllingDirectly()
    local entityUuid = entity.Uuid.EntityUuid
    if BrawlState.Session.Players and BrawlState.Session.Players[entityUuid] then
        BrawlState.Session.Players[entityUuid].userId = entity.UserReservedFor.UserID
    end
end

local function onLevelGameplayStarted(level, _)
    debugPrint("LevelGameplayStarted", level)
    if DAG_SkipLevel and DAG_SkipLevel(level) then return end -- DAG: not in character creation
    onStarted(level)
end

local function onCombatRoundStarted(combatGuid, round)
    debugPrint("CombatRoundStarted", combatGuid, round)
    Roster.addCombatParticipantsToBrawlers()
    BrawlState.Session.ReactionInterruptCount = {}
    BrawlState.Session.ReactionInterruptLoopDetected = {}
    debugPrint(string.format("CombatRoundStarted round=%d", round or -1))
    RT.Listeners.onCombatRoundStarted(combatGuid, round) -- DAG: Swarm Mode stripped
end

-- NB: move all of the endBrawl stuff to here
local function onCombatEnded(combatGuid)
    debugPrint("CombatEnded", combatGuid)
    BrawlState.Session.StoryActionIDs = {}
    BrawlState.Session.MeanInitiativeRoll = nil
    TurnOrder.clearAllNaturalInitiative()
    Movement.removeAllDashSpeedBoosts() -- DAG: Encounters + Swarm Mode stripped
    RT.Listeners.onCombatEnded(combatGuid)
end

local function onEnteredCombat(entityGuid, combatGuid)
    debugPrint("EnteredCombat", entityGuid, combatGuid)
    local uuid = M.Osi.GetUUID(entityGuid)
    if uuid then
        -- Handle resurrection first so the entity's InitiativeRoll is set to the
        -- mean before addBrawler caches actionInterval from it.
        if BrawlState.Session.Players and BrawlState.Session.Players[uuid] then
            if BrawlState.Session.ResurrectedPlayer[uuid] then
                BrawlState.Session.ResurrectedPlayer[uuid] = nil
                TurnOrder.setInitiativeRoll(uuid, BrawlState.Session.MeanInitiativeRoll)
            end
        end
        -- Replace existing brawler entries so actionInterval is refreshed from the
        -- now-rolled InitiativeRoll (entries added pre-combat got the default).
        Roster.addBrawler(uuid, true)
        RT.Listeners.onEnteredCombat(uuid) -- DAG: Swarm Mode stripped
    end
end

local function onLeftCombat(entityGuid, combatGuid)
    local uuid = M.Osi.GetUUID(entityGuid)
    if uuid and M.Roster.getBrawlerByUuid(uuid) then
        if M.Pause.isPartyInFTB() then
            -- Defer non-player removals until FTB exits; party members get spurious LeftCombat during see-saw, skip them.
            if M.Osi.IsPartyMember(uuid, 1) ~= 1 then
                BrawlState.Session.PendingLeftCombat = BrawlState.Session.PendingLeftCombat or {}
                BrawlState.Session.PendingLeftCombat[uuid] = true
            end
        else
            local level = M.Osi.GetRegion(M.Osi.GetHostCharacter())
            Roster.removeBrawler(level, uuid)
            Roster.checkForEndOfBrawl(level)
        end
    end
end

local function onTurnStarted(entityGuid)
    debugPrint("TurnStarted", entityGuid)
    local turnUuid = M.Osi.GetUUID(entityGuid)
    debugPrint(string.format("TurnStarted target=%s isPlayer=%s",
        M.Utils.getDisplayName(turnUuid) or tostring(entityGuid),
        tostring(turnUuid and BrawlState.Session.Players[turnUuid] ~= nil)))
    -- DAG: Swarm Mode stripped
end

local function onTurnEnded(entityGuid)
    debugPrint("TurnEnded", entityGuid)
    -- DAG: Swarm Mode stripped
end

local function onDied(entityGuid)
    debugPrint("Died", entityGuid)
    local entityUuid = M.Osi.GetUUID(entityGuid)
    -- Drop the cached natural init so a rezzed unit's fresh roll is captured by the next equalize/bumpNpc.
    if entityUuid then
        TurnOrder.clearNaturalInitiativeFor(entityUuid)
    end
    RT.Listeners.onDied(entityUuid) -- DAG: Swarm Mode stripped
end

local function onResurrected(entityGuid)
    debugPrint("Resurrected", entityGuid)
    -- DAG: Swarm Mode stripped
end

-- NB: entity.ClientControl does NOT get reliably updated immediately when this fires
local function onGainedControl(targetGuid)
    debugPrint("GainedControl", targetGuid)
    local targetUuid = M.Osi.GetUUID(targetGuid)
    local windowActive = BrawlState.Session.ExpectedControlled
        and BrawlState.Session.ExpectedControlledExpiresAt
        and Ext.Utils.MonotonicTime() < BrawlState.Session.ExpectedControlledExpiresAt
    debugPrint(string.format("GainedControl target=%s window=%s",
        M.Utils.getDisplayName(targetUuid) or tostring(targetUuid), tostring(windowActive and "active" or "expired/none")))
    if targetUuid ~= nil then
        -- Expected-controlled reassertion window: set on FTB entry and on combat start.  If the engine picked a different char for a user during
        -- the window, redirect their client to the intended one.  Mode-agnostic; runs in both RT and Swarm.  RT-specific initiative bump only
        -- happens in RT mode (Swarm doesn't use TurnOrder.Groups initiatives the same way).
        if windowActive then
            local gainedUserId = Osi.GetReservedUserID(targetUuid)
            local expectedForUser = gainedUserId and BrawlState.Session.ExpectedControlled[gainedUserId]
            if expectedForUser then
                if targetUuid ~= expectedForUser then
                    debugPrint(string.format("GainedControl mismatch: expected=%s got=%s userId=%s - correcting",
                        M.Utils.getDisplayName(expectedForUser), M.Utils.getDisplayName(targetUuid), tostring(gainedUserId)))
                    if not BrawlState.Settings.TurnBasedSwarmMode then
                        TurnOrder.bumpInitiativeRollsFor(expectedForUser)
                    end
                    RT.sendSelectCharacter(expectedForUser, "Listeners.onGainedControl-windowMismatch")
                else
                    debugPrint(string.format("GainedControl match: %s - clearing expectation for userId=%s", M.Utils.getDisplayName(targetUuid), tostring(gainedUserId)))
                    BrawlState.Session.ExpectedControlled[gainedUserId] = nil
                    if not next(BrawlState.Session.ExpectedControlled) then
                        BrawlState.Session.ExpectedControlled = nil
                        BrawlState.Session.ExpectedControlledExpiresAt = nil
                    end
                end
            end
        end
        if targetUuid == Osi.GetHostCharacter() then
            local modVars = Ext.Vars.GetModVariables(ModuleUUID)
            local partyArchetypes = modVars.PartyArchetypes
            if partyArchetypes == nil then
                partyArchetypes = {}
                modVars.PartyArchetypes = partyArchetypes
            end
            local archetype = ""
            if partyArchetypes[targetUuid] ~= nil then
                archetype = partyArchetypes[targetUuid]
            end
            local isValidArchetype = false
            for _, validArchetype in ipairs(Constants.PLAYER_ARCHETYPES) do
                if archetype == validArchetype then
                    isValidArchetype = true
                    break
                end
            end
            -- DAG: Brawl's MCM archetype setting stripped
        end
        if BrawlState.Session.Players[targetUuid] then
            local targetUserId = Osi.GetReservedUserID(targetUuid)
            if targetUserId then
                BrawlState.Session.Players[targetUuid].isControllingDirectly = true
                for playerUuid, player in pairs(BrawlState.Session.Players) do
                    if player.userId == targetUserId and playerUuid ~= targetUuid then
                        player.isControllingDirectly = false
                    end
                end
                BrawlState.Session.LastGainedControlAt = BrawlState.Session.LastGainedControlAt or {}
                BrawlState.Session.LastGainedControlAt[targetUserId] = Ext.Utils.MonotonicTime()
                -- Feed the during-pause selection tracker (consumed by allExitFTB recency heuristic).
                if BrawlState.Session.FTBSelectionTrack and M.Pause.isPartyInFTB() then
                    local prior = BrawlState.Session.FTBSelectionTrack[targetUserId]
                    if not prior or prior.current ~= targetUuid then
                        BrawlState.Session.FTBSelectionTrack[targetUserId] = {
                            current = targetUuid,
                            currentAt = Ext.Utils.MonotonicTime(),
                            previous = prior and prior.current or nil,
                        }
                    end
                end
            end
            if not BrawlState.Settings.TurnBasedSwarmMode then
                RT.Listeners.onGainedControl(targetUuid)
            end
            -- DAG: the client "GainedControl" message (Brawl's keybinds) stripped
        end
    end
end

-- Diagnostic: ClientControl create/destroy logging -- the engine can move CC silently without firing GainedControl
local function dumpClientControlSnapshot(label)
    local entities = Ext.Entity.GetAllEntitiesWithComponent("ClientControl") or {}
    local entries = {}
    for _, entity in ipairs(entities) do
        local euuid = entity.Uuid and entity.Uuid.EntityUuid or "?"
        local userId = entity.UserReservedFor and entity.UserReservedFor.UserID or "?"
        table.insert(entries, string.format("%s(user=%s)", M.Utils.getDisplayName(euuid) or euuid, tostring(userId)))
    end
    debugPrint(string.format("[ClientControl] %s | currently held by %d: %s",
        label, #entities, table.concat(entries, ", ")))
end

local function onClientControlCreated(entity)
    local t = Ext.Utils.MonotonicTime()
    local euuid = entity and entity.Uuid and entity.Uuid.EntityUuid or "?"
    local userId = entity and entity.UserReservedFor and entity.UserReservedFor.UserID or "?"
    debugPrint(string.format("[ClientControl] [%dms] CREATE entity=%s user=%s",
        t, M.Utils.getDisplayName(euuid) or euuid, tostring(userId)))
    dumpClientControlSnapshot("post-create")
end

local function onClientControlDestroyed(entity)
    local t = Ext.Utils.MonotonicTime()
    local euuid = entity and entity.Uuid and entity.Uuid.EntityUuid or "?"
    debugPrint(string.format("[ClientControl] [%dms] DESTROY entity=%s",
        t, M.Utils.getDisplayName(euuid) or euuid))
    dumpClientControlSnapshot("post-destroy")
end

local function onEnteredForceTurnBased(entityGuid)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onEnteredForceTurnBased(M.Osi.GetUUID(entityGuid))
    end
end

local function onLeftForceTurnBased(entityGuid)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onLeftForceTurnBased(M.Osi.GetUUID(entityGuid))
    end
end

local function onCharacterJoinedParty(character)
    debugPrint("CharacterJoinedParty", character)
    local uuid = M.Osi.GetUUID(character)
    if uuid then
        if BrawlState.Session.Players and not BrawlState.Session.Players[uuid] then
            BrawlState.setupPlayer(uuid)
            BrawlState.setupPartyMembersHitpoints()
            BrawlState.uncapMovementDistance(uuid) -- DAG: Swarm Mode stripped
        end
        if M.Osi.IsSummon(uuid) == 1 then
            BrawlState.Session.Players[uuid].isFreshSummon = true
            local ownerUuid = Osi.CharacterGetOwner(uuid)
            if ownerUuid and not Utils.hasLoseControlStatus(uuid) then
                local ownerInitiativeRoll = TurnOrder.getInitiativeRoll(ownerUuid)
                if ownerInitiativeRoll then
                    TurnOrder.setInitiativeRoll(uuid, ownerInitiativeRoll)
                end
            end
        end
        if BrawlState.areAnyPlayersBrawling() then
            Roster.addBrawler(uuid)
        end
    end
end

local function onCharacterLeftParty(character)
    debugPrint("CharacterLeftParty", character)
    local uuid = M.Osi.GetUUID(character)
    if uuid then
        if BrawlState.Session.Players and BrawlState.Session.Players[uuid] then
            BrawlState.Session.Players[uuid] = nil
        end
        if BrawlState.Session.PartyMembersHitpointsListeners[uuid] then
            Ext.Entity.Unsubscribe(BrawlState.Session.PartyMembersHitpointsListeners[uuid])
            BrawlState.Session.PartyMembersHitpointsListeners[uuid] = nil
        end
        -- NB: can remove this??
        -- local level = M.Osi.GetRegion(uuid)
        -- if BrawlState.Session.Brawlers and BrawlState.Session.Brawlers[level] and BrawlState.Session.Brawlers[level][uuid] then
        --     BrawlState.Session.Brawlers[level][uuid] = nil
        -- end
    end
end

local function onRollResult(eventName, roller, rollSubject, resultType, isActiveRoll, criticality)
    debugPrint("RollResult", eventName, roller, rollSubject, resultType, isActiveRoll, criticality)
end

local function onDownedChanged(character, isDowned)
    local uuid = M.Osi.GetUUID(character)
    debugPrint("DownedChanged", character, isDowned, uuid)
    local player = BrawlState.Session.Players[uuid]
    if player then
        if isDowned == 1 and BrawlState.Settings.AutoPauseOnDowned and player.isControllingDirectly then
            local brawler = M.Roster.getBrawlerByUuid(uuid)
            if brawler and not brawler.isPaused then
                Osi.ForceTurnBasedMode(uuid, 1)
            end
        end
        if isDowned == 0 then
            player.isBeingHelped = false
        end
    end
end

-- DAG: the Leaderboard heal tracker (ServerStatusApplyEvent) stripped

local function onAttackedBy(defenderGuid, attackerGuid, attacker2, damageType, damageAmount, damageCause, storyActionID)
    debugPrint("AttackedBy", defenderGuid, attackerGuid, attacker2, damageType, damageAmount, damageCause, storyActionID)
    local attackerUuid = M.Osi.GetUUID(attackerGuid)
    local defenderUuid = M.Osi.GetUUID(defenderGuid)
    if attackerUuid ~= nil and defenderUuid ~= nil and M.Osi.IsCharacter(attackerUuid) == 1 and M.Osi.IsCharacter(defenderUuid) == 1 then
        if M.Utils.isToT() then
            Roster.addBrawler(attackerUuid)
            Roster.addBrawler(defenderUuid)
        end
        if M.Osi.IsPlayer(attackerUuid) == 1 then
            BrawlState.Session.PlayerCurrentTarget[attackerUuid] = defenderUuid
            if M.Osi.IsPlayer(defenderUuid) == 0 and damageAmount > 0 then
                BrawlState.Session.IsAttackingOrBeingAttackedByPlayer[defenderUuid] = attackerUuid
            end
        end
        if M.Osi.IsPlayer(defenderUuid) == 1 then
            if M.Osi.IsPlayer(attackerUuid) == 0 and damageAmount > 0 then
                BrawlState.Session.IsAttackingOrBeingAttackedByPlayer[attackerUuid] = defenderUuid
            end
        end
        -- DAG: Leaderboard stripped
    end
    if attackerUuid ~= nil then
        Actions.handleExtraAttacks(attackerUuid, defenderUuid, storyActionID, damageType, damageAmount)
    end
end

local function onKilledBy(defenderGuid, attackOwner, attackerGuid, storyActionID)
    debugPrint("KilledBy", defenderGuid, attackOwner, attackerGuid, storyActionID)
    -- NB: attackOwner for summons?
    local attackerUuid = M.Osi.GetUUID(attackerGuid)
    local defenderUuid = M.Osi.GetUUID(defenderGuid)
    -- DAG: Leaderboard stripped
    BrawlState.Session.ExtraAttacksRemaining[attackerUuid] = nil
    BrawlState.Session.ExtraAttacksRemaining[defenderUuid] = nil
end

local function onSpellSyncTargeting(cast, _, _)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onSpellSyncTargeting(cast.SpellCastState)
    end
end

local function onDestroySpellSyncTargeting(cast, _, _)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onDestroySpellSyncTargeting(cast.SpellCastState)
    end
end

local function onSpellCastStateCreated(cast, _, _)
    if not BrawlState.Settings.TurnBasedSwarmMode and cast and cast.SpellCastState then
        RT.Listeners.onSpellCastStateCreated(cast.SpellCastState)
    end
end

local function onSpellCastStateDestroyed(cast, _, _)
    if not BrawlState.Settings.TurnBasedSwarmMode and cast and cast.SpellCastState then
        RT.Listeners.onSpellCastStateDestroyed(cast.SpellCastState)
    end
end

-- Capture the requestUuid of a registered action for this storyActionID, if there is one. Use `or` so that follow-up events sharing the same
-- storyActionID (e.g. the Target_Counterspell_Success metaspell that fires after a successful counter) don't clobber the original cast's
-- requestUuid -- the counterspell handler in onCastedSpell needs the original to look up and fail the right action precisely.
local function captureStoryActionRequestUuid(storyActionID, casterUuid, spellName)
    if BrawlState.Session.StoryActionIDs[storyActionID].requestUuid then
        return
    end
    local action = Actions.getActionInProgressByName(casterUuid, spellName)
    if action then
        BrawlState.Session.StoryActionIDs[storyActionID].requestUuid = action.requestUuid
    end
end

local function onUsingSpellOnTarget(casterGuid, targetGuid, spellName, spellType, spellElement, storyActionID)
    local casterUuid = M.Osi.GetUUID(casterGuid)
    local targetUuid = M.Osi.GetUUID(targetGuid)
    if casterUuid and targetUuid and spellName then
        -- debugPrint(M.Utils.getDisplayName(casterUuid), "UsingSpellOnTarget", M.Utils.getDisplayName(targetUuid), spellName, spellType, spellElement, storyActionID)
        if not BrawlState.Session.StoryActionIDs[storyActionID] then
            BrawlState.Session.StoryActionIDs[storyActionID] = {}
        end
        BrawlState.Session.StoryActionIDs[storyActionID].casterUuid = casterUuid
        BrawlState.Session.StoryActionIDs[storyActionID].spellName = spellName
        BrawlState.Session.StoryActionIDs[storyActionID].targetUuid = targetUuid
        captureStoryActionRequestUuid(storyActionID, casterUuid, spellName)
        -- NB: what other instakill effects are there? Word of Bhaal, chasms...?
        -- if spellName == "Target_PowerWordKill" or spellName == "Target_ATT_PowerWordKill" then
        --     Leaderboard.updateDamage(casterUuid, targetUuid, Osi.GetHitpoints(targetUuid))
        -- end
    end
end

local function onUsingSpellOnZoneWithTarget(casterGuid, targetGuid, spellName, spellType, spellElement, storyActionID)
    local casterUuid = M.Osi.GetUUID(casterGuid)
    local targetUuid = M.Osi.GetUUID(targetGuid)
    if casterUuid and targetUuid and spellName then
        -- debugPrint("UsingSpellOnZoneWithTarget", casterGuid, targetGuid, spell, spellType, spellElement, storyActionID)
        if not BrawlState.Session.StoryActionIDs[storyActionID] then
            BrawlState.Session.StoryActionIDs[storyActionID] = {}
        end
        BrawlState.Session.StoryActionIDs[storyActionID].casterUuid = casterUuid
        BrawlState.Session.StoryActionIDs[storyActionID].spellName = spellName
        BrawlState.Session.StoryActionIDs[storyActionID].targetUuid = targetUuid
        captureStoryActionRequestUuid(storyActionID, casterUuid, spellName)
        -- NB: what other instakill effects are there? Word of Bhaal, chasms...?
        -- if spellName == "Target_PowerWordKill" or spellName == "Target_ATT_PowerWordKill" then
        --     Leaderboard.updateDamage(casterUuid, targetUuid, Osi.GetHitpoints(targetUuid))
        -- end
    end
end

local function onUsingSpell(casterGuid, spellName, spellType, spellElement, storyActionID)
    -- debugPrint(M.Utils.getDisplayName(M.Osi.GetUUID(casterGuid)), "UsingSpell", casterGuid, spellName, spellType, spellElement, storyActionID)
    local casterUuid = M.Osi.GetUUID(casterGuid)
    if casterUuid and spellName then
        -- debugPrint("UsingSpell", casterGuid, targetGuid, spell, spellType, spellElement, storyActionID)
        if not BrawlState.Session.StoryActionIDs[storyActionID] then
            BrawlState.Session.StoryActionIDs[storyActionID] = {}
        end
        BrawlState.Session.StoryActionIDs[storyActionID].casterUuid = casterUuid
        BrawlState.Session.StoryActionIDs[storyActionID].spellName = spellName
        captureStoryActionRequestUuid(storyActionID, casterUuid, spellName)
    end
end

local function onCastedSpell(casterGuid, spellName, spellType, spellElement, storyActionID)
    local casterUuid = M.Osi.GetUUID(casterGuid)
    local actionInProgress = Actions.getActionInProgressByName(casterUuid, spellName)
    if actionInProgress then
        debugPrint(M.Utils.getDisplayName(casterUuid), "CastedSpell", casterGuid, spellName, spellType, spellElement, storyActionID)
        -- debugPrint("actionInProgress")
        -- debugDump(actionInProgress)
        local requestUuid = actionInProgress.requestUuid
        -- debugPrint("Spell cast succeeded! (CastedSpell)")
        debugPrint("onCompleted onCastedSpell") -- DAG: Swarm Mode stripped
        local onCompleted = actionInProgress.onCompleted
        Actions.removeActionInProgress(casterUuid, requestUuid)
        if not BrawlState.Settings.HogwildMode and M.Osi.IsPlayer(casterUuid) == 0 then
            Resources.deductCastedSpell(casterUuid, spellName, requestUuid)
        end
        onCompleted(spellName)
    end
    if M.Utils.isCounterspell(spellName) then
        local originalCastInfo = BrawlState.Session.StoryActionIDs[storyActionID]
        if originalCastInfo and originalCastInfo.casterUuid and originalCastInfo.requestUuid then
            debugPrint("got counterspelled!", spellName, originalCastInfo.spellName, M.Utils.getDisplayName(originalCastInfo.targetUuid), M.Utils.getDisplayName(originalCastInfo.casterUuid))
            local originalAction = Actions.getActionInProgress(originalCastInfo.casterUuid, originalCastInfo.requestUuid)
            if originalAction then
                local onFailed = originalAction.onFailed
                Actions.removeActionInProgress(originalCastInfo.casterUuid, originalCastInfo.requestUuid)
                BrawlState.Session.StoryActionIDs[storyActionID] = {}
                onFailed("counterspelled")
            end
        end
    end
    Utils.checkDivineIntervention(spellName, casterUuid)
end

-- thank u Norb and Mazzle
local function onSpellCastFinishedEvent(cast, _, _)
    if cast and cast.SpellCastState and cast.SpellCastState.Caster and cast.ServerSpellCastState and cast.ServerSpellCastState.StoryActionId then
        -- _D(cast.SpellCastState)
        -- _D(cast.ServerSpellCastState)
        -- _D(cast:GetAllComponents())
        local casterUuid = cast.SpellCastState.Caster.Uuid.EntityUuid
        local requestUuid = cast.SpellCastState.SpellCastGuid
        local storyActionId = cast.ServerSpellCastState.StoryActionId
        local actionInProgress = Actions.getActionInProgress(casterUuid, requestUuid)
        if actionInProgress then
            debugPrint("SpellCastFinishedEvent", M.Utils.getDisplayName(casterUuid), cast.SpellCastOutcome.Result)
            local outcome = cast.SpellCastOutcome.Result
            local spellName = actionInProgress.spellName
            local onCompleted = actionInProgress.onCompleted
            local onFailed = actionInProgress.onFailed
            Actions.removeActionInProgress(casterUuid, requestUuid)
            if outcome == "None" then
                debugPrint("Spell cast succeeded")
                debugPrint("onCompleted") -- DAG: Swarm Mode stripped
                if not BrawlState.Settings.HogwildMode and M.Osi.IsPlayer(casterUuid) == 0 then
                    Resources.deductCastedSpell(casterUuid, spellName, requestUuid)
                end
                onCompleted(spellName)
            else
                debugPrint("onFailed")
                onFailed(outcome)
            end
        end
    end
end

local function onCastSpellFailed(casterGuid, spellName, spellType, spellElement, storyActionID)
    debugPrint(M.Utils.getDisplayName(M.Osi.GetUUID(casterGuid)), "CastSpellFailed", casterGuid, spellName, spellType, spellElement, storyActionID)
end

local function onDialogStarted(...)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onDialogStarted()
    end
end

local function onDialogEnded(...)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onDialogEnded()
    end
end

-- NB: get rid of this??
local function onStatusApplied(targetGuid, statusId, causeeGuid, storyActionId)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onStatusApplied(targetGuid, statusId)
    end
end

local function onStatusRemoved(targetGuid, statusId, causeeGuid, storyActionId)
    if not BrawlState.Settings.TurnBasedSwarmMode then
        RT.Listeners.onStatusRemoved(targetGuid, statusId)
    end
end

local function onDifficultyChanged(difficulty)
    debugPrint("DifficultyChanged", difficulty)
    Movement.setMovementSpeedThresholds()
end

local function onTeleportedToCamp(character)
    debugPrint("TeleportedToCamp", character)
    local uuid = M.Osi.GetUUID(character)
    RT.Listeners.onTeleportedToCamp(uuid) -- DAG: Swarm Mode stripped
end

local function onLevelUnloading(level)
    debugPrint("LevelUnloading", level)
    BrawlState.Session.Brawlers[level] = nil
end

local function onFlagSet(flag, speaker, dialogInstance)
    debugPrint("FlagSet", flag, speaker, dialogInstance)
    RT.Listeners.onFlagSet(flag) -- DAG: Swarm Mode stripped
end

local function onLeveledUp(character)
    debugPrint("LeveledUp", character)
    if character ~= nil and M.Osi.IsPartyMember(character, 1) == 1 then
        Spells.buildSpellTable()
    end
end

local function onEntityEvent(characterGuid, eventUuid)
    debugPrint("EntityEvent", characterGuid, eventUuid)
    if BrawlState.Session.ActiveMovements[eventUuid] then
        Movement.finishMovement(M.Osi.GetUUID(characterGuid), eventUuid, BrawlState.Session.ActiveMovements[eventUuid])
    end
end

local function onReactionInterruptActionNeeded(characterGuid)
    debugPrint("ReactionInterruptActionNeeded", characterGuid)
    RT.Listeners.onReactionInterruptActionNeeded(M.Osi.GetUUID(characterGuid)) -- DAG: Swarm Mode stripped
end

-- DAG: onServerInterruptUsed (Swarm Mode only) stripped

-- Engine-side reaction-interrupt loop circuit-breaker.  When an actor is mid-cast (we submitted a spell, the engine never fired the completion event)
-- and a reaction triggers (e.g. attack-of-opportunity) the engine wants to fire the reaction but can't fully commit, so it spins on ReactionInterruptUsed,
-- which can crash the game.  Force-fail the source's pending action(s) and end their turn so the engine can move forward.
local function forceFailReactionInterruptLoop(uuid)
    print("[REACTION_LOOP] threshold exceeded, force-failing", M.Utils.getDisplayName(uuid), uuid)
    BrawlState.Session.ReactionInterruptLoopDetected[uuid] = true
    local actions = BrawlState.Session.ActionsInProgress[uuid]
    if actions and next(actions) then
        for _, action in ipairs(actions) do
            if action.onFailed then
                action.onFailed("reaction interrupt loop")
            end
        end
        BrawlState.Session.ActionsInProgress[uuid] = {}
    end
    if BrawlState.Session.ActionSequenceFailsafeTimer and BrawlState.Session.ActionSequenceFailsafeTimer[uuid] and BrawlState.Session.ActionSequenceFailsafeTimer[uuid].timer then
        Ext.Timer.Cancel(BrawlState.Session.ActionSequenceFailsafeTimer[uuid].timer)
        BrawlState.Session.ActionSequenceFailsafeTimer[uuid] = nil
    end
    -- DAG: Swarm Mode stripped
end

local function onReactionInterruptUsed(characterGuid, reactionInterruptPrototypeId, isAutoTriggered)
    debugPrint("ReactionInterruptUsed", characterGuid, reactionInterruptPrototypeId, isAutoTriggered)
    local uuid = M.Osi.GetUUID(characterGuid)
    if uuid and not BrawlState.Session.ReactionInterruptLoopDetected[uuid] then
        BrawlState.Session.ReactionInterruptCount[uuid] = (BrawlState.Session.ReactionInterruptCount[uuid] or 0) + 1
        if BrawlState.Session.ReactionInterruptCount[uuid] > Constants.REACTION_INTERRUPT_LOOP_THRESHOLD then
            forceFailReactionInterruptLoop(uuid)
            return
        end
    end
    RT.Listeners.onReactionInterruptUsed(uuid, isAutoTriggered) -- DAG: Swarm Mode stripped
end

local function onServerInterruptDecision()
    RT.Listeners.onServerInterruptDecision() -- DAG: Swarm Mode stripped
end

local function stopListeners()
    cleanupAll()
    local listeners = BrawlState.Session.Listeners
    for _, listener in pairs(listeners) do
        listener.stop(listener.handle)
    end
end

local function startListeners()
    debugPrint("Starting listeners...")
    BrawlState.Session.Listeners.Tick = {}
    BrawlState.Session.Listeners.Tick.handle = Ext.Events.Tick:Subscribe(M.clear)
    BrawlState.Session.Listeners.Tick.stop = function ()
        Ext.Events.Tick:Unsubscribe(BrawlState.Session.Listeners.Tick.handle)
    end
    BrawlState.Session.Listeners.ResetCompleted = {}
    BrawlState.Session.Listeners.ResetCompleted.handle = Ext.Events.ResetCompleted:Subscribe(onResetCompleted)
    BrawlState.Session.Listeners.ResetCompleted.stop = function ()
        Ext.Events.ResetCompleted:Unsubscribe(BrawlState.Session.Listeners.ResetCompleted.handle)
    end
    -- DAG: ServerStatusApplyEvent (Leaderboard) and ServerInterruptUsed (Swarm Mode) listeners stripped
    BrawlState.Session.Listeners.UserReservedFor = {
        handle = Ext.Entity.Subscribe("UserReservedFor", onUserReservedFor),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.LevelGameplayStarted = {
        handle = Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", onLevelGameplayStarted),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CombatStarted = {
        handle = Ext.Osiris.RegisterListener("CombatStarted", 1, "after", onCombatStarted),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CombatEnded = {
        handle = Ext.Osiris.RegisterListener("CombatEnded", 1, "after", onCombatEnded),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CombatRoundStarted = {
        handle = Ext.Osiris.RegisterListener("CombatRoundStarted", 2, "after", onCombatRoundStarted),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.EnteredCombat = {
        handle = Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", onEnteredCombat),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.LeftCombat = {
        handle = Ext.Osiris.RegisterListener("LeftCombat", 2, "after", onLeftCombat),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.TurnStarted = {
        handle = Ext.Osiris.RegisterListener("TurnStarted", 1, "after", onTurnStarted),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.TurnEnded = {
        handle = Ext.Osiris.RegisterListener("TurnEnded", 1, "after", onTurnEnded),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.Died = {
        handle = Ext.Osiris.RegisterListener("Died", 1, "after", onDied),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.Resurrected = {
        handle = Ext.Osiris.RegisterListener("Resurrected", 1, "after", onResurrected),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.GainedControl = {
        handle = Ext.Osiris.RegisterListener("GainedControl", 1, "after", onGainedControl),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.LeftForceTurnBased = {
        handle = Ext.Osiris.RegisterListener("LeftForceTurnBased", 1, "after", onLeftForceTurnBased),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.EnteredForceTurnBased = {
        handle = Ext.Osiris.RegisterListener("EnteredForceTurnBased", 1, "after", onEnteredForceTurnBased),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CharacterJoinedParty = {
        handle = Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", onCharacterJoinedParty),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CharacterLeftParty = {
        handle = Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", onCharacterLeftParty),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.RollResult = {
        handle = Ext.Osiris.RegisterListener("RollResult", 6, "after", onRollResult),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.DownedChanged = {
        handle = Ext.Osiris.RegisterListener("DownedChanged", 2, "after", onDownedChanged),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.KilledBy = {
        handle = Ext.Osiris.RegisterListener("KilledBy", 4, "after", onKilledBy),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.AttackedBy = {
        handle = Ext.Osiris.RegisterListener("AttackedBy", 7, "after", onAttackedBy),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.SpellSyncTargeting = {
        handle = Ext.Entity.OnCreateDeferred("SpellSyncTargeting", onSpellSyncTargeting),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.DestroySpellSyncTargeting = {
        handle = Ext.Entity.OnDestroy("SpellSyncTargeting", onDestroySpellSyncTargeting),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.SpellCastStateCreated = {
        handle = Ext.Entity.OnCreateDeferred("SpellCastState", onSpellCastStateCreated),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.SpellCastStateDestroyed = {
        handle = Ext.Entity.OnDestroy("SpellCastState", onSpellCastStateDestroyed),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.UsingSpellOnTarget = {
        handle = Ext.Osiris.RegisterListener("UsingSpellOnTarget", 6, "after", onUsingSpellOnTarget),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.UsingSpellOnZoneWithTarget = {
        handle = Ext.Osiris.RegisterListener("UsingSpellOnZoneWithTarget", 6, "after", onUsingSpellOnZoneWithTarget),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.UsingSpell = {
        handle = Ext.Osiris.RegisterListener("UsingSpell", 5, "after", onUsingSpell),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.CastedSpell = {
        handle = Ext.Osiris.RegisterListener("CastedSpell", 5, "after", onCastedSpell),
        stop = Ext.Osiris.UnregisterListener,
    }
    -- BrawlState.Session.Listeners.CastSpellFailed = {
    --     handle = Ext.Osiris.RegisterListener("CastSpellFailed", 5, "after", onCastSpellFailed),
    --     stop = Ext.Osiris.UnregisterListener,
    -- }
    BrawlState.Session.Listeners.SpellCastFinishedEvent = {
        handle = Ext.Entity.OnCreateDeferred("SpellCastFinishedEvent", onSpellCastFinishedEvent),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.ClientControlCreated = {
        handle = Ext.Entity.OnCreateDeferred("ClientControl", onClientControlCreated),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.ClientControlDestroyed = {
        handle = Ext.Entity.OnDestroy("ClientControl", onClientControlDestroyed),
        stop = Ext.Entity.Unsubscribe,
    }
    BrawlState.Session.Listeners.DialogStarted = {
        handle = Ext.Osiris.RegisterListener("DialogStarted", 2, "before", onDialogStarted),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.DialogEnded = {
        handle = Ext.Osiris.RegisterListener("DialogEnded", 2, "after", onDialogEnded),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.StatusApplied = {
        handle = Ext.Osiris.RegisterListener("StatusApplied", 4, "after", onStatusApplied),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.StatusRemoved = {
        handle = Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", onStatusRemoved),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.DifficultyChanged = {
        handle = Ext.Osiris.RegisterListener("DifficultyChanged", 1, "after", onDifficultyChanged),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.TeleportedToCamp = {
        handle = Ext.Osiris.RegisterListener("TeleportedToCamp", 1, "after", onTeleportedToCamp),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.LevelUnloading = {
        handle = Ext.Osiris.RegisterListener("LevelUnloading", 1, "after", onLevelUnloading),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.FlagSet = {
        handle = Ext.Osiris.RegisterListener("FlagSet", 3, "after", onFlagSet),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.LeveledUp = {
        handle = Ext.Osiris.RegisterListener("LeveledUp", 1, "after", onLeveledUp),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.EntityEvent = {
        handle = Ext.Osiris.RegisterListener("EntityEvent", 2, "after", onEntityEvent),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.ReactionInterruptActionNeeded = {
        handle = Ext.Osiris.RegisterListener("ReactionInterruptActionNeeded", 1, "after", onReactionInterruptActionNeeded),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.ReactionInterruptUsed = {
        handle = Ext.Osiris.RegisterListener("ReactionInterruptUsed", 3, "after", onReactionInterruptUsed),
        stop = Ext.Osiris.UnregisterListener,
    }
    BrawlState.Session.Listeners.ServerInterruptDecision = {
        handle = Ext.Entity.OnSystemUpdate("ServerInterruptDecision", onServerInterruptDecision),
        stop = Ext.Entity.Unsubscribe,
    }
end

-- DAG: Brawl's MCM settings and client keybind messages (Commands.lua) stripped

local function startSession()
    if not BrawlState or not BrawlState.Settings then
        return Ext.Timer.WaitFor(250, startSession)
    end
    if BrawlState.Settings.ModEnabled then
        startListeners()
    else
        Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", BrawlState.resetPlayers)
    end
end

local function onSessionLoaded()
    Ext.Events.GameStateChanged:Subscribe(onGameStateChanged)
    startSession() -- DAG: MCM + client keybind messages stripped
end

return {
    onCombatStarted = onCombatStarted,
    onStarted = onStarted,
    stopListeners = stopListeners,
    startListeners = startListeners,
    onSessionLoaded = onSessionLoaded,
}
