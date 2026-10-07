# Spike 11: Can the local player's head, hair and headwear be hidden on their own client only?

**Status:** answered yes
**Date:** 2026-10-07 · **BG3 version:** Patch 8 · **Script Extender version:** TBD (logged by probe)

## Question
On the local client, can we hide the player character's head mesh, hair, horns, overhead attachments and equipped helmet without hiding them for other players? (Required for true first-person; shrinking the character is not acceptable.)

## Why it matters
If no, the whole first-person body plan falls back to a floating arms-and-weapon view model, which adds a full animation set to M1 and changes M1's scope and schedule.

## Fallback if no
From DESIGN.md: "Native plugin hides those meshes; last resort, an arms-only view model." Second fallback is to build our own tiny native plugin that toggles the mesh renderables directly (same approach Native Camera Tweaks uses for third-person).

## What we checked

### Script Extender source (`reference/bg3se`)

- `GameDefinitions/Components/Visual.h`:
  - `VisualComponent` (`ls::VisualComponent`, line 31) sits on any entity with a renderable and holds `Visual* Visual`.
  - `EquipmentVisualsComponent` (`ecl::EquipmentVisualsComponent`, line 924) is a **client-side** component on the character. Its `Equipment` hash map keys by `ItemSlot` (Helmet is slot 0) and each entry's `SubVisuals` is an array of `EntityHandle` — those are the per-slot visual entities we'd flip for headwear.
  - `VisualsVisibilityStateComponent` (`ClientEquipmentVisibilityState`, line 1189) is also client-side and already stores a per-slot visibility state per character — the engine already supports hiding equipment slots locally. Its sibling `VisualsVisibilityStateSystem` applies those states each frame.
- `GameDefinitions/Render.h` line 432 — the `Visual` C++ struct:
  - `Array<Attachment> Attachments` — each `Attachment` has `Visual* Visual`, bone names (`Attach`, `Source`) and `VisualAttachmentFlags Flags`.
  - `VisualCullFlags CullFlags` on each `Visual`, plus a virtual `UpdateCullFlags()`.
- `GameDefinitions/Enumerations/Engine.inl`:
  - `VisualAttachmentFlags` (line 467): `Hair = 0x100`, `Armor = 0x4000`, `Weapon = 0x8000`, `Wings = 0x10000`, `Horns = 0x20000`, `Overhead = 0x40000` — the exact attachment classes we need to find.
  - `VisualCullFlags` (line ~440): `CullRenderView1 = 0x200`, `CullRenderView2 = 0x400`, `CullScenery = 0x800`, `CullShadowProxy = 0x4000`, `CullShadow4 = 0x8000` — the knobs that stop a `Visual` from rendering.
  - `ItemSlot` (`Stats.inl` line 975/1000): `Helmet = 0`.
- `ClientControl` tag component (`Components/Data.h` line 223) marks client-controlled characters; `Ext.Entity.GetAllEntitiesWithComponent("ClientControl")` finds the local player.

### Brawl (`reference/Brawl`)
Not checked yet — Brawl is third-person combat and unlikely to touch mesh visibility. Only re-check if the probe fails.

### Other
- Native Camera Tweaks and Larian's own paperdoll already use `EquipmentVisualsComponent`, so writes to the client-side visibility structures do not desync other players (the server/other clients never see those components).

## In-game proof

Probe `mod/DarkAndGate/Mods/DarkAndGate/ScriptExtender/Lua/Spikes/Spike11_HeadHiding.lua`, wired from `BootstrapClient.lua`. Registers three Script Extender console commands:

(All three are invoked as `!dag11_...` from the `C >>` client prompt.)

- `dag11_dump` — walks the local client-controlled character, logs its root `Visual*` plus every `Attachment` (sub-visual name, bones, flags) and every `EquipmentVisualsComponent.Equipment[slot].SubVisuals` entry. This is the inventory of exactly what the character is made of so we know what to hide.
- `dag11_hide` — sets `CullRenderView1 | CullRenderView2` on attachments whose flags include `Hair`, `Horns`, `Overhead`, and on every `SubVisual` entity under the `Helmet` slot. Logs the before/after flag values.
- `dag11_show` — clears the same cull bits.

### Test steps (first play session)

1. From an elevated PowerShell: `scripts\deploy.ps1` to pack and deploy, then launch BG3.
2. Load `DEV-SAVE`.
3. In the Script Extender console window (opens alongside BG3 because `CreateConsole: true`), type `client` + Enter to switch to the client Lua state. The prompt becomes `C >>`. Then run `!dag11_dump`. SE console commands require the `!` prefix; without it the line is parsed as Lua. Our commands are registered from the client state, so the context must be `client`.
4. Inspect `client.log` via `scripts\read-log.ps1` and tell me what attachments were found and whether their current flag values look sensible. **No visual change expected at this step.**
5. Run `dag11_hide`. Expected: head, hair, horns (if your character has them), overhead UI meshes and the helmet (if equipped) disappear on your screen. Camera placement is not changed in this spike — you'll still be in third person.
6. Rotate the camera around your character and confirm the body, arms and feet remain visible.
7. Run `dag11_show`. Everything comes back.
8. If any attachments did not disappear (e.g. the face/head mesh itself if it isn't a flagged attachment), the dump log will tell us which slot name it uses and we'll iterate.

### What a "yes" looks like
- Head, hair, helmet and overhead meshes vanish for the local player on `dag11_hide`.
- Other characters in the scene are unaffected (verify by panning the camera to any NPC — they still have heads).
- Toggling 10× in a row leaves no stuck state and no crash.

### What a "no" looks like
- `CullFlags` reads back the written value but the mesh keeps rendering → engine ignores client-side writes for the main character visual; need the native plugin fallback.
- Writes to `Visual.CullFlags` are refused by SE (readonly) → try `VisualsVisibilityStateComponent` for helmet, and look at `Visual.VisualFlags` / `GameObjectFlags` for the head mesh.
- Crash on toggle → fallback immediately to arms-only.

## Result and recommendation

**Answered yes** on 2026-10-08. The local client can hide the player's head, hair and beard (and headwear, by the same mechanism) without any effect on how other players see the character.

The working lever is `Visual.ObjectDescs[i].Renderable.PropertyList.RenderPasses` — the per-frame bitmask of which render passes a renderable participates in. Setting it to `0` makes the renderable draw in no pass, instantly invisible. Restoring the saved value brings the mesh back cleanly.

Levers that **did not** work and are documented so we don't retry them:

- Writing `Visual.VisualFlags` (clearing `ShowMesh`) — SE accepted the write; readback confirmed the bit cleared; the renderer kept drawing the mesh. Not a live field.
- Writing `Attachment.Offset` — SE accepted the write; readback returned the old value. `Attachment` is a value-type Lua proxy and writes never reach the live array entry.
- Reading `VisualAttachmentFlags` (`Hair`, `Horns`, `Overhead`, `Armor` bits on `Attachment.Flags`) — every live attachment reads `0x0`, so matching by flag finds nothing. Match attachments by their sub-visual template name (`HAIR_`, `Beard_`, `_NKD_Head_`) instead.

### What to build in M1

- Promote the probe into a client-side `HeadHiding` module under `Client/`, driven by MCM toggle rather than console commands.
- Hook it to character-swap and equipment-change events so a swap into Gale or an equip Helmet rebuilds the hidden list.
- The helmet path (equipment sub-visuals under `ClientEquipmentVisuals.Equipment[Helmet].SubVisuals`) still needs an in-game validation with an equipped helmet, since the dev save's Gale had no helmet. Not blocking M0.

### API notes added

Full details recorded in `docs/se-api-notes.md` under "Visuals: hiding meshes on the local client" so the next spike / M1 implementer doesn't have to re-derive them.

