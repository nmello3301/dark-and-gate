# Spike: what the crosshair is on (LookAt)

2026-10-12. Static research (SE v33 source, BG3's story header and goals, the game's UI files), built into `Client/LookAt.lua`. **Not verified in-game yet**: the probes below run in the real-time combat playtest ([playtest/realtime-combat.md](../playtest/realtime-combat.md), step 9).

## Question

In first person there is no mouse cursor over the world. How do we find the character, door, chest, lever, item, ladder or corpse under the crosshair? How does the engine mark what is interactive, and can we reuse its hover highlight?

## Answers

### Finding the thing under the crosshair

- **Our own ray can probably name the entity now.** SE v33 exposes the chain `hit.Shape.PhysicsObject.Entity` (`GameDefinitions/Physics.h`, IDE helpers `PhxPhysicsObject.Entity`). Spike 2 (2026-10-08) only ever printed `hit.Shape`, so "ray hits can't name an entity" was never actually tested. LookAt tries it first: `Ext.Level.RaycastClosest(eye, eye + fwd * reach, {"Static", "Dynamic"}, {"Item", "Character"}, {}, 1)`. It logs once whether it works (`LookAt: the physics ray names entities` or `can't name entities`).
- **Fallback: a scan of what's around the player.** It first tries the engine's spatial grid, `Ext.Entity.GetEntitiesAroundPosition(feet, 8, true, true)` (2D, 12.7 m cells). The grid may not exist on the client; if so, it falls back to a sliced scan of every `IsItem` and `ClientCharacter` entity, 64 per tick. The candidate is the item or corpse closest to the crosshair inside 8°, with line of sight. Living characters come from their hitbox cylinders (`Shared/Hitbox.lua`), as for spells.
- **The engine's own hover is cursor-based.** `Ext.UI.GetPickingHelper(1).Inner.Inner[1]` holds `Character`, `DeadCharacter`, `Item` and `GameObject` under the mouse; Brawl reads `.GameObject`. While the DLL holds Camera Rotate, BG3's cursor reads `CameraRotation`, so the hover is probably frozen or off in first person. `!dag_lookat` prints it next to our answer so the playtest settles it.

### What is interactive, and what kind

The server decides (`Server/Combat/Interact.lua`), so the answer is authoritative and works in multiplayer. The client sends the entity's UUID (`InteractClassify`), and the server answers with a kind, a verb and a name (`InteractInfo`). Answers are cached for 10 s.

| Kind | Server data |
| --- | --- |
| talk | `Osi.IsCharacter`, alive, not `IsEnemy` and not in combat, not `IsDialogueBlocked`, and `GetHasDefaultDialog` or `DB_Dialogs` or a party member |
| loot | a dead character, unless the story blocks it with `DB_CustomLootCorpseResponse(player, corpse, 0)` |
| climb / door / close / locked / open / pickup / use | `ServerItem` flags `IsLadder`, `IsDoor` (+ `Osi.IsOpened`, `IsLocked`), `IsContainer`, `CanBePickedUp`, `CanUse`, `CanClimbOn`; `InteractionDisabled`, `Invisible`, `OffStage` and `Destroyed` mean none |

The client components (`UseAction`, `IsDoor`, `Ladder`, `InventoryOwner`, `ClientCharacter.HasDialog`…) exist too, but which ones replicate to the client is unverified. That is another reason to ask the server.

### The highlight

- **BG3's hover outline can't be driven from Lua.** SE has nothing for it, and there is no Osiris call for highlights, outlines or glows. The engine picks highlights from its cursor picking (`EclCharacterManager.UpdateCharacterHighlights` are internal queues).
- **We draw our own, from BG3's own UI art:**
  - the circle BG3 draws under a highlighted character (`VFX_UI_Circle_Highlight_01`), spawned locally under the object through `Ext.System.ClientEffectHandler:InitMultiEffect` (`Client/WorldFx.lua`). Our MultiEffectInfo wraps the vanilla effect by GUID (`Public/DarkAndGate/MultiEffectInfos/`, sources in `tools/mei/`);
  - a `[F]` marker on the object;
  - the prompt `[F] Open Chest` under the crosshair (`Client/HUD/Overlay.lua`).
- Only things the server calls interactive get them.

### Starting the interaction (the F key, Part 8)

- talk: fire the engine's own event, `Osi.DialogStartRequested(npc, player)`, so every story handler runs exactly as for a click (`__GLOBAL_Dialogs.txt:2164`).
- doors, levers, containers, ladders, chairs: `Osi.Use(player, item, 1, 1, "DAG_Interact")`: the character walks up and plays the use animation. The story header names the arguments `Use(_Character, _Item, _UseItem, _IsInteraction, _Event)`; vanilla's own 3-argument `Use` wrapper passes `1, 0`, and `1, 1` shows up in story scripts for NPCs using doors and pods. (An earlier line here said `1, 1` was vanilla's pattern for players; it isn't.) The task behind it re-runs the use; see the 2026-10-13 findings below.
- pick up: `Osi.Pickup(player, item, "DAG_Pickup", 1)`.
- corpses: `Osi.OpenCharacterLootUI(player, corpse)`.
- `Server/Net.lua` purges the Osiris queue before every scripted animation, which would cancel a pending `Use`/`Pickup`; it skips that while an interaction runs.

## Playtest findings, 2026-10-13 (sorcerer run, nautiloid)

Static research: the run's logs, BG3's level and template data (extracted to the scratchpad, not the repo), the story header and goals, and Ghidra on `bg3_dx11.exe`. **Verified in-game 2026-10-13** (second nautiloid run): both vines climbed once per F with the task ended, the lever fired once per press, Brain Jar and the rubble helper got no prompt, and Myrnath talked.

**One F climbed a vine up and down forever.** The log shows one `[F] Climb Arterial Mesh` followed by `UseFinished (ok)` every 2.3–2.8 s for two minutes, with no new F press. The Neural Apparatus lever showed the same bug in a milder form: one press logged `ok`, then `failed` 30 ms later.
- In Ghidra, the `esv::OsirisUseItemTask` vtable is at `0x1457ede10`, with `GetName` at `0x1430d8890` returning "OsirisUseItemTask".
- Its `Update` (`FUN_1430e64a0`) gets the character's behaviour of type 7, a `BSMoveAndUseItem` (size 0x118, created in `FUN_142f6da10`). It re-applies the item and flags and keeps that behaviour going whenever **neither** of these is true:
  - `FUN_143044f50`: success, meaning vt+0x88 plus flag 8 at +0x9c;
  - `FUN_143044590`: a result code at +0xd4, or the `ASUseItem` action with the same transaction finished.
- A player-style use (`IsInteraction` 1) on a ladder evidently ends with both false, so the task runs the use again: back down, then back up.
- **Fix:** at the first `UseFinished` of the item F used, if the character's current Osiris task (`ServerCharacter.OsirisController.Tasks[1].Type`) is still `UseItem`, call `PurgeOsirisQueue` + `FlushOsirisQueue`. A `UseStarted` of the same item afterwards is logged as "AGAIN on its own".

**"[F] Use" on things that aren't interactive.** Every false hit in the log has no use actions in BG3's data:
- `Brain Jar` and the `Mind Sanctuary` jars are `DEC_MF_Brain_Jar_B/C` (base `BASE_DEC_Medium_Immovable`, `Tooltip` 0).
- `Object` is `S_TUT_Misc_RubbleHelper_001`, a `Helper_Invisible_Walkthrough` item.

Everything that worked has use actions: the pod, the brine pool and the resting station have `StoryUse` (8) on the level object; the lever console has `StoryUse`; the door has `Door` (9); the chair has `Sit` (14); the vine has `Ladder` (24). `ServerItem.CanUse` and `GetCanInteract` are set on plain decorations too, so they were the wrong test. **Fix:** "use" now needs one of the world use actions in `data/interact.lua` `use_actions`, read from the item's `UseAction.UseActions[i].Type` (`eoc::item_template::UseActionComponent`) plus `ServerItem.Template.OnUsePeaceActions`. `GetCanInteract` = 0 (the story's `SetCanInteract`) still switches an item off.

**The brain couldn't be talked to.** "Myrnath" is `S_TUT_Lab_DevourerVictim`, the man in the lab's operation chair with his brain exposed. His dialogue is `DB_Dialogs(S_TUT_Lab_DevourerVictim, S_TUT_Lab_SpeakerHelper, TUT_Lab_TrappedDevourer)`, a 3-speaker row, and our check only read the 2-column `DB_Dialogs`. The story flags every speaker of every `DB_Dialogs` row (1 to 4 speakers) with `SetHasDialog`, and automated-dialogue speakers too; `GetHasOsirisDialog` reads that flag, which is what the click-to-talk cursor follows. **Fix:** talk is a party member, `GetHasOsirisDialog`, `GetHasDefaultDialog`, or a 2-column `DB_Dialogs` row.

**A non-interactive hit hid the rest.** `findObject` stopped at the ray's first entity even when the server called it "none". Now the candidates (ray, character on the line, nearby scan) are tried in order until one is interactive.

## Bug found on the way

`Client/Combat/Aim.lua` passed `"Door"` as a physics group, and there is no such group. SE raised an error inside `WorldRay`'s `pcall`, so **every client world ray since fix3 returned nil**. `client.log` never showed `via ray`, and `LineOfSight` always said yes. Fixed: the groups are now `Terrain, Scenery, Item`, the server's set. Two consequences:
- spells now aim at the wall or ground the crosshair is on, instead of the point 100 m out;
- melee line of sight works.

`Shared/NativeBridge.lua` had two dead fallbacks too: `"Static,Dynamic"` as one string, and `pick.HoverCharacter`, a field that doesn't exist. Both are fixed.

## Probes (playtest step 9)

1. `!dag_lookat on`, then look at Zevlor, a door, a chest, a lever, a ladder and a corpse. The lines should name the right object with `via ray` or `via scan`. The `engine hover` field shows what BG3's own picking sees.
2. The first lines tell which path works: `LookAt: the physics ray names entities` or `can't name entities`, and `nearby objects from the engine's spatial grid` or `sliced item scan`.
3. Each kind's first classification is logged once by the server: `Interact: Chest (…) is open -> "[F] Open"`.
