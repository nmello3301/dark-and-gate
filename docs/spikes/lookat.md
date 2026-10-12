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
- doors, levers, containers, ladders, chairs: `Osi.Use(player, item, 1, 1, "DAG_Interact")`. That is the pattern vanilla uses for a player opening a door or climbing a ladder: the character walks up and plays the use animation.
- pick up: `Osi.Pickup(player, item, "DAG_Pickup", 1)`.
- corpses: `Osi.OpenCharacterLootUI(player, corpse)`.
- `Server/Net.lua` purges the Osiris queue before every scripted animation, which would cancel a pending `Use`/`Pickup`; it skips that while an interaction runs.

## Bug found on the way

`Client/Combat/Aim.lua` passed `"Door"` as a physics group, and there is no such group. SE raised an error inside `WorldRay`'s `pcall`, so **every client world ray since fix3 returned nil**. `client.log` never showed `via ray`, and `LineOfSight` always said yes. Fixed: the groups are now `Terrain, Scenery, Item`, the server's set. Two consequences:
- spells now aim at the wall or ground the crosshair is on, instead of the point 100 m out;
- melee line of sight works.

`Shared/NativeBridge.lua` had two dead fallbacks too: `"Static,Dynamic"` as one string, and `pick.HoverCharacter`, a field that doesn't exist. Both are fixed.

## Probes (playtest step 9)

1. `!dag_lookat on`, then look at Zevlor, a door, a chest, a lever, a ladder and a corpse. The lines should name the right object with `via ray` or `via scan`. The `engine hover` field shows what BG3's own picking sees.
2. The first lines tell which path works: `LookAt: the physics ray names entities` or `can't name entities`, and `nearby objects from the engine's spatial grid` or `sliced item scan`.
3. Each kind's first classification is logged once by the server: `Interact: Chest (…) is open -> "[F] Open"`.
