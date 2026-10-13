# Script Extender API notes

Confirmed in-game, with the SE version each note was verified against. Add every API we touch here. See `reference/bg3se/Docs/API.md` for the full reference.

## SE v32 (built 2026-06-21)

### Lua sandbox omissions

The SE Lua state has **no `os` library**. Any call to `os.time`, `os.date`, `os.clock`, `os.getenv`, etc. raises `attempt to index a nil value (global 'os')` at the first use. Verified on 2026-10-07 by the M0 scaffold trying `os.date("%Y-%m-%d %H:%M:%S")` from `Shared/Log.lua`.

Assume the same for `io` (standard file handles) and `debug.getregistry`-style introspection. Use SE equivalents instead.

### Time

- `Ext.Timer.MonotonicTime(): int64` — milliseconds since engine start, monotonic. Not wall-clock, not synced between peers. **Confirmed working** from both server and client bootstrap on 2026-10-07.
- `Ext.Timer.GameTime(): number` — in-game time; still pending verification.
- Wall-clock timestamps: no first-class SE API found yet; if we need them, serialize `Ext.Timer.MonotonicTime()` deltas against a per-session timestamp sampled some other way, or ship a tiny native helper later.

### File I/O (`Ext.IO`)

- `Ext.IO.SaveFile(path, content): boolean` — writes to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\<path>`. Creates missing parent directories. **Confirmed working** on 2026-10-07 writing `DarkAndGate/session.log`.
- `Ext.IO.LoadFile(path, [context]): string?` — unverified.

### Visuals: hiding meshes on the local client

Verified by spike 11 on 2026-10-08 against SE v32 and BG3 Patch 8.

- A character's visual tree is reached via `entity.Visual.Visual.Attachments[i]` on the client — each `Attachment` wraps a sub-`Visual*` which is the actual mesh (hair, head, beard, equipped armor…).
- `Attachment.Flags` (the `VisualAttachmentFlags` bitmask: Hair, Horns, Overhead…) is **not populated at runtime** — every live attachment reads `0x0`. Match attachments by their sub-visual's template name instead (`HAIR_`, `Beard_`, `_NKD_Head_`, etc.).
- Writing `Visual.VisualFlags` (including clearing `ShowMesh`) succeeds in Lua but **has no visual effect at runtime** — the renderer doesn't re-check that field for live visibility.
- Writing `Attachment.Offset` succeeds in Lua but **does not persist** — `Attachment` is a value-type proxy; the write never reaches the live array entry.
- **The lever that actually works:** `Visual.ObjectDescs[i].Renderable.PropertyList.RenderPasses` (a `RenderPass` bitmask). Setting it to `0` makes the renderable participate in no passes — the mesh is invisible that same frame. Setting it back to the saved value restores it. This is the per-frame live field the renderer reads; it is also what we use to hide the local player's head/hair/beard without affecting other players (the component is client-only).

Minimal pattern:

```lua
for _, od in ipairs(att.Visual.ObjectDescs) do
    od.Renderable.PropertyList.RenderPasses = 0 -- hides; save the original to restore
end
```

### Entity components used

- `ClientControl` (tag) — enumerate with `Ext.Entity.GetAllEntitiesWithComponent("ClientControl")` to find the local client-controlled character. Verified 2026-10-08.
- `ClientEquipmentVisuals` (`ecl::EquipmentVisualsComponent`) — hash map by `ItemSlot` to arrays of sub-visual entity handles. Useful for hiding a helmet specifically. Verified 2026-10-08 that the sub-visual entities exist and are reachable.

### Camera + aim ray from Lua

Verified by spike 2 on 2026-10-08.

- Find the active camera: `Ext.Entity.GetAllEntitiesWithComponent("Camera")`, then on each entity, `ent.Camera.Active` is a bool. Grab `ent.Camera.Controller` for its fields.
- `controller.FOV` and `controller.AspectRatio` read correctly (radians for FOV).
- `controller.Camera.ViewMatrix` and `.InvViewMatrix` return SE's **flat 16-float column-major** Lua table (one `glm::mat4`). Column `c` (0..3) occupies indices `4*c + 1 .. 4*c + 4`. From `InvViewMatrix`:
  - Camera world position = `(invView[13], invView[14], invView[15])`.
  - Camera forward = `-(invView[9], invView[10], invView[11])` (negate the "back" axis column).
- `controller.LookAt` field reads back as `(0, 0, 0)` — same vec3 binding gap as `WorldTransform.Translate`. Compute forward from `InvViewMatrix` instead.
- `Ext.Level.RaycastClosest(from, to, physicsType, collidesWith, ignoredGroups, maxHits): PhxPhysicsHit`:
  - `physicsType`: `"Static"` or `"Dynamic"`.
  - `collidesWith` / `ignoredGroups`: Lua arrays of `PhysicsGroupFlags` names like `{"Terrain", "Scenery", "Character", "Item"}`.
  - `maxHits`: int, usually `1` for closest.
- On the returned `PhxPhysicsHit`:
  - `hit.Distance` — real; a fraction in `[0, 1]` of `|to - from|`. Reconstruct the world hit position as `from + (to - from) * hit.Distance`.
  - `hit.PhysicsGroup` — bitmask userdata; `tostring(...)` lists flag names.
  - `hit.Shape` — `phx::PhysicsShape` pointer; comparable across hits but not resolvable to an entity in Lua without a helper.
  - `hit.Position`, `hit.Normal` — same vec3 bug, read as `(0, 0, 0)`. Reconstruct Position from the ray; Normal needs the native plugin.
- Sweep / Test variants exist (`SweepSphereClosest`, `SweepCapsuleClosest`, `TestBox`, `TestSphere`), same argument shape with an extra geometry parameter.

### Visual world transform (client)

From the SE v32 source (`Render.h:77`), not yet verified in-game: `Visual:SetWorldTranslate({x, y, z})` (also `SetWorldRotate`, `SetWorldScale`) is Lua-callable on `ent.Visual.Visual` and calls the Visual's vtable slot 2, which moves the whole character render (renderables and attachments). The engine re-writes it through slot 5 whenever the entity's `TransformComponent` changes, so a Lua write only holds while standing still. `!dag_lift_probe <m>` tests it. See [m1b-visual-lift.md](spikes/m1b-visual-lift.md).

### Animation resources

From the SE v32 source, not yet verified in-game: `Ext.Resource.Get(id, "Animation")` exposes `Duration` (seconds), `Looping`, `SourceFile` and `Events`. `JumpAnims.lua` reads `Duration` to time the jump phases; a `0` falls back to `data/movement.lua`.

### Input events (client)

Verified by spike 1 on 2026-10-08.

- `Ext.Events.KeyInput:Subscribe(fn)` — called for every keyboard event. Event shape: `{ Event: SDLKeyEvent, Key: SDLScanCode, Modifiers: SDLKeyModifier, Pressed: bool, Repeat: bool, CanPreventAction: bool }`.
- `Ext.Events.MouseButtonInput:Subscribe(fn)` — called for mouse button events. Shape: `{ Button: int, Pressed: bool, Clicks: int, X: int, Y: int, CanPreventAction: bool }`. `Button == 1` is LMB, `3` is RMB (SDL convention).
- `event:PreventAction()` on either event blocks BG3's default handler from running. Confirmed to work for LMB, RMB, and the digit row — the character doesn't move, context menus don't open, hotbar slots don't fire. The log subscriber still sees the event, so our handlers run while BG3's don't.
- Digit-row scancodes stringify as `NUM_1`..`NUM_0`, not `Key1`..`Key0` as the IDE helpers' `SDLScanCode` enum suggests.
- The IDE helpers (`reference/bg3se/BG3Extender/IdeHelpers/ExtIdeHelpers.lua`) list these events under names like `EclLuaKeyInput` / `EclLuaMouseButton` with an `Ecl` prefix. **Those are wrong.** The runtime names, taken from `LuaClient.cpp:161,171`, are `KeyInput` and `MouseButtonInput`. If a subscription silently never fires, verify against `BG3Extender/Lua/Client/LuaClient.cpp` rather than the IDE helpers.

### Console commands

- `Ext.RegisterConsoleCommand(name, fn)` registers a command that is invoked from the SE console with a **`!` prefix** (`!dag11_dump`). The command only fires when the console is in the Lua state that registered it, so a client-registered command needs the console in client context (`client` to switch to `C >>`). Verified 2026-10-08 (initial Spike 11 run tripped on this because `dag11_dump` was typed without `!`).

### No world-level mouse motion events

SE's client input surface (verified 2026-10-08 against SE v32):

- `Ext.Events.KeyInput` — keyboard scancodes.
- `Ext.Events.MouseButtonInput` — button down/up with X,Y at click time.
- `Ext.Events.MouseWheelInput` — scroll deltas.
- No `MouseMove` or `MouseMotion` event, no polling API for the mouse XY
  outside UI contexts. `MouseEvent/MouseMove` exist in SE but only under
  `ClientUI/Events.inl` for Noesis UI elements, not world input.
  `ViewMousePosition[2]` exists in `UI.h:751` but is not bound to Lua.

**Implication:** always-on mouselook (FPS style, no MMB held) cannot be
built in Lua. It needs native hooks that read the mouse delta and drive
the camera's yaw/pitch each frame. Rolled into the native plugin alongside
camera follow and bone reads — see DECISIONS 2026-10-08.

### IMGUI windows: flags are one field each, and hovered windows eat the mouse

Found 2026-10-12 against SE v33 (the round 2 HUD playtest; source in
`reference/bg3se`):

- **There is no `win.Flags` field.** `P_BITMASK(Flags)` registers one
  boolean property per `GuiWindowFlags` label (`LuaObjectProxies.cpp`,
  `AddBitfieldProperty`), which is why the IDE helpers list `NoInputs`,
  `NoTitleBar`, … under `ExtuiWindowBase` and no `Flags`. Set them one by
  one (`win.NoInputs = true`) and read them back. `win.Flags = {...}` raises
  an error, so wrapping it in `pcall` silently leaves the window with no
  flags. `Client/HUD/WindowFlags.lua` does this.
- **SE drops mouse events that ImGui wants.** `Extender/Client/SDL.cpp`:
  while `io.WantCaptureMouse` is true, SDL mouse motion, button and wheel
  events are not passed to BG3 or to `Ext.Events.MouseButtonInput`. ImGui
  wants the mouse whenever a window without `NoInputs` / `NoMouseInputs`
  is under the cursor, or a button was pressed on one and is still held. A
  full-screen overlay without `NoInputs` therefore blocks BG3's camera
  rotation and every click, including the DLL's synthetic MMB press. A
  button that was pressed while no window was hovered is not ImGui's, so
  it passes even over a window.
- `Ext.UI.GetCursorControl()` returns BG3's cursor control (`ShowCursor`,
  `RequestedCursor`, …). Logged by `Hud.lua` when a menu opens or closes
  (`!dag_cursor`); values to be confirmed in round 3.

### Loose mod files do not override an installed pak

Attempted 2026-10-08 against SE v32 and BG3 Patch 8: an installed
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\DarkAndGate.pak` cannot
be shadowed by loose files written into
`<GameDir>\Data\Mods\DarkAndGate\<same tree>`. After `reset` in the SE
console, SE still logs `Loading bootstrap script: Mods/DarkAndGate/...`
with the pak's content, not the loose edits.

Mod bootstraps are loaded via `ExtensionStateBase::LuaLoadModScript(modGuid,
fileName)` (see `reference/bg3se/BG3Extender/Extender/Shared/ExtensionState.cpp:428`),
which resolves the file through the mod's pak metadata — not through the
VFS path lookup that would pick up loose files. The only paths that honour
loose-file overrides are the game's own asset VFS and SE's
`LuaBuiltinResourceDirectory` (for `builtin://` scripts, not mod Lua).

**Workflow:** Lua changes require closing BG3, running `scripts/deploy.ps1`,
and relaunching. `reset` alone is not enough. If this friction becomes
painful, the two paths worth investigating are (a) wiring `Ext.IO.AddPathOverride`
from a tiny bootstrap stub, which may or may not work depending on when SE
resolves per-mod Lua paths, and (b) temporarily removing the installed pak
so loose files are the only source for the mod (requires validating that
BG3 scans `Data\Mods\` for mods without a pak).

### Logging

- `Ext.Utils.Print(...)` goes to the SE debug console (when `CreateConsole: true` in `ScriptExtenderSettings.json`) and to the SE runtime log (when `EnableLogging: true` and `LogRuntime: true`). Default SE settings in release builds have `CreateConsole: false`; we rely on an explicit settings file.
- SE runtime log location (verified 2026-10-07): `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\Extender Runtime <timestamp>.log` — note the trailing *` Logs`* on the folder, which is a sibling of the SE data folder, not inside it.

## SE v33

### Physics ray names the entity it hit (client)

- A client world ray's hit carries the entity: `hit.Shape.PhysicsObject.Entity` was non-nil in the 2026-10-12 playtest log (`LookAt: the physics ray names entities (hit.Shape.PhysicsObject.Entity) -> used for F`), so `Client/LookAt.lua` names what the crosshair is on from the ray itself.

### Items, use tasks and dialog flags (server; static research 2026-10-13, verified in-game the same day, SE v33)

- `Osi.Use(character, item, useItem, isInteraction, event)` is the story header's signature (`Use(_Character, _Item, _UseItem, _IsInteraction, _Event)`). It queues an `OsirisUseItemTask`; with a player and `1, 1` that task runs the use again after it finishes (a ladder is climbed back and forth). End it at the first `UseFinished(character, item, success)` with `PurgeOsirisQueue(character, 1)` + `FlushOsirisQueue(character)` (`Server/Combat/Interact.lua`, [spikes/lookat.md](spikes/lookat.md)).
- `Ext.Entity.Get(uuid).ServerCharacter.OsirisController.Tasks` lists a character's queued Osiris tasks; `Tasks[1].Type` is the current one (`"UseItem"`, `"MoveToLocation"`…; enum `OsirisTaskType`). Brawl reads the same field in a debug line.
- An item's use actions: `Ext.Entity.Get(item).UseAction.UseActions[i].Type` (`eoc::item_template::UseActionComponent`; `ActionDataType`: `StoryUse` 8, `Door` 9, `Sit` 14, `Lie` 15, `Ladder` 24…), also `ServerItem.Template.OnUsePeaceActions`. Decorations have none. `ServerItem.CanUse` and `Osi.GetCanInteract` are 1 on plain decorations too, so they don't mean "usable".
- `Osi.GetHasOsirisDialog(character)` reads the flag the story sets with `SetHasDialog` on every `DB_Dialogs` speaker (1–4 speakers per row) and automated-dialogue speaker. Server field: `ServerCharacter.HasOsirisDialog`; client: `ClientCharacter.HasDialog`.
- Osiris events can be raised from Lua by calling them (SE `Docs/API.md`: "triggered synchronously"); F talk raises `Osi.DialogStartRequested(npc, player)`, the click-to-talk event.

### Party control, BG3's game over and the difficulty (server; static research 2026-10-13, not verified in-game yet)

- When the character a user controls goes down, BG3 hands that user's control to another party member and `GainedControl(other)` fires (playtest log 2026-10-13: the companion that got control counted as "controlled", so no AI drove it). `Osi.MakePlayerActive(character)` gives control back; the story uses it to return a dialogue's player to their own character (`__GLOBAL_Dialogs`). Fallback: the party portraits' `SelectCharacter` command on the client (`Client/BrawlClient.lua`, Brawl's way). Whether BG3 keeps a downed character active is what the next playtest shows (`Server/Combat/Downed.lua` logs it).
- BG3's game over is story logic (`GLO_GameOverLogic`): `PROC_StateSet_Defeated(player)` -> `PROC_GameOver_CheckGameOver()` -> `ShowGameOverMenu()` once no `DB_Players` member is left "alive" and `QRY_GameOver_BlockGameOver()` fails. A player warrants a game over when it is in `DB_Defeated` with a cause not listed in `DB_GameOver_DefeatCausesNotGameOver` (INIT: `TempBanished`, `TempPetrified`). Downed is a defeat: 500 ms after `DownedChanged(char, 1)` (object timer `GLO_Downed_VerifyStillDowned`) the story adds `DB_DefeatedCauses(char, "Downed", 0)` and `DB_Downed`, then `DB_Defeated`. So the whole party downed = game over at once, whatever the death saves say. A character that dies while already defeated (downed) isn't newly defeated, so the story may not check again at the death.
- From Lua: `Osi.DB_GameOver_DefeatCausesNotGameOver("Downed")` inserts, `:Delete("Downed")` removes and `:Get("Downed")` reads (SE `Docs/API.md`, Databases); `Osi.PROC_GameOver_CheckGameOver()` runs the story's check (PROCs are callable like built-in calls). SE listens to user PROCs (`RegisterListener("PROC_GameOver_CheckGameOver", 0, "after", fn)`) but not yet to built-in calls such as `ShowGameOverMenu`. User queries answer true / false: `Osi.QRY_GameOver_AliveCharactersLeft()` (someone not defeated, or defeated by a not-a-game-over cause) and `Osi.QRY_GameOver_BlockGameOver()` (the story forbids a game over now, e.g. the nautiloid's ending) tell whether the check just showed the game-over screen (Give up, `Server/Combat/Downed.lua`).
- The difficulty: `Osi.GetRulesetModifierString(guid)` / `Osi.GetRulesetModifierBool(guid)` with the bare modifier GUID (Brawl's `Utils.getDifficulty` does exactly this, in-game). From `Public/Shared/Ruleset/` (Shared.pak): the presets are Explorer = `DIFFICULTY_EASY`, Balanced = `DIFFICULTY_MEDIUM`, Tactician = `DIFFICULTY_HARD`, Honour = `DIFFICULTY_HARD` + `RULESET_HONOUR`, Custom = `DIFFICULTY_MEDIUM` plus the player's changes. Modifiers: `SCRIPTED_COMBAT_MECHANICS` `cac2d8bd-c197-4a84-9df1-f86f54ad4521` (EASY / MEDIUM / HARD), `AI_LETHALITY` `968ce114-d656-407c-88c2-0c071fe2181b` (AILETHALITY_FORGIVING / _BALANCED / _BRUTAL; "Enemy AI" on the custom screen), `HONOUR_STATS` `ef0506df-da9f-40e2-903a-1349523c1ae4` (bool, Honour only), `IRONMAN_MODE` `338450d9-d77d-4950-9e1e-0e7f12210bb3` (bool). Events: `DifficultyChanged(level)`, `RulesetModifierChangedString(modifier, old, new)` (and Int / Float / Bool). Entity side: `RulesetComponent.Rulesets` (the active ruleset GUIDs) and `.Modifiers`.
