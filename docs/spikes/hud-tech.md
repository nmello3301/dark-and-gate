# HUD tech: ImGui images, hiding the vanilla HUD, Q/R, potions, XP, HP

**Status:** 2026-10-12. Desk research only (source + extracted data). Nothing here is verified in-game yet; items marked **unverified** need a playtest. Feeds ROADMAP Pass A "The engine is chosen and the vanilla HUD hide / restore lever is found" and [design/hud.md](../design/hud.md).

Sources: `reference/bg3se` (Script Extender v32 source, Docs, IDE helpers), `reference/Brawl`, Mod Configuration Menu 1.41.0 (pak unpacked to the scratchpad, read only), and game files listed/unpacked with Divine to the session scratchpad only (never into the repo): `Game.pak` UI state machine and HUD pages, `Shared.pak` `Object.txt`, `Gustav.pak` / `Shared.pak` Osiris goal files.

## 1. SE ImGui (`Ext.IMGUI`) can draw images

| API | Signature | Source |
| --- | --- | --- |
| `parent:AddImage(iconOrTexture, size?, uv0?, uv1?)` | `(FixedString, vec2?, vec2?, vec2?) -> ExtuiImage` | `BG3Extender/Extender/Client/IMGUI/IMGUI.cpp:539-549`; property map `GameDefinitions/PropertyMaps/IMGUI.inl:71`; IDE helper `IdeHelpers/ExtIdeHelpers.lua:18300` |
| `parent:AddImageButton(label, iconOrTexture, size?, uv0?, uv1?)` | `-> ExtuiImageButton` (has `Background`, `Tint`, `OnClick`) | `IMGUI.cpp:526-536`, `Objects.h:733-744` |
| `parent:AddIcon(name, size?)` | deprecated alias of `AddImage` (logs a warning) | `IMGUI.cpp:552-556` |
| `img.ImageData.Size / .UV0 / .UV1` | read/write after creation; `TextureResource`, `Icon` read-only | `PropertyMaps/IMGUI.inl:1-7`, `Objects.h:111-133` |
| `img.Tint` | `vec4` RGBA multiplier (fade, pulse, "out of mana" grey) | `Objects.h:619-628`, `PropertyMaps/IMGUI.inl:249-254` |
| `img.Border` | deprecated, ignored by the renderer | `Objects.h:626`, `IMGUI.cpp:1308-1321` |
| `parent:AddProgressBar()` -> `.Value` (0..1), `.Size`, `.Overlay` | built-in bar; colours via `:SetColor("PlotHistogram", …)`, `"FrameBg"` | `PropertyMaps/IMGUI.inl:100, 438-443`; `Enumerations/IMGUI.inl:402` |

Rendering is `ImGui::ImageWithBg(texture, Size, UV0, UV1, bg=0, Tint)` (`IMGUI.cpp:1308-1321`): no rotation, no per-image blend mode.

### What the image id refers to

`ImageReference::Bind` tries an **icon name first, then a texture resource UUID** (`IMGUI.cpp:37-45`):

- **Icon name** (`BindIcon`, `IMGUI.cpp:60-91`): looked up in the game's texture atlas map (`ls::gTextureAtlasMap->IconMap`). Size and UVs come from the atlas entry. So any atlas icon works, including spell/item `Icon` stat names (e.g. `Spell_Evocation_FireBolt`; MCM uses item/UI icon names this way, e.g. `NotiFramework/NotificationManager.lua:245`, `ListV2IMGUIWidget.lua:335` with `"panner_up_h"`).
- **Texture UUID** (`BindTexture`, `IMGUI.cpp:47-58` -> `IMGUITextureLoader::IncTextureRef`, `IMGUI.cpp:2220-2259`): any resource in the **Texture resource bank** by its UUID. It must be a 2D texture (`IMGUI.cpp:2238-2242`). `Size` defaults to the texture's pixel size, UVs to 0..1.
- There is **no `Ext.IMGUI.LoadTexture`** or load-from-file call. The whole module is `NewWindow, EnableDemo, LoadFont, SetScale (deprecated no-op), SetUIScaleMultiplier, SetFontScaleMultiplier, GetViewportSize` (`Lua/Libs/ClientIMGUI.inl:56-68`).

### Shipping our own art (PNG -> DDS in our pak)

Two ways, both data-only, both used by MCM 1.41.0 (which ships its own icons):

1. **Texture bank entry + DDS** (simplest for big layers like orb frame / liquid / glass). A `TextureBank` resource in an `.lsf` under `Public/<Mod>/Content/...`, e.g. MCM's `Public/Shared/Content/UI/[PAK]_UI/merged.lsx`:
   `Resource { ID = <uuid>, Name, SourceFile = "Public/.../X.dds", SRGB = False, Streaming = True, Template = "Icons_Items", Type = 0 }`.
   Then `AddImage("<that uuid>", {w, h})`.
2. **Texture atlas** (for many small icons, by name): `Public/<Mod>/GUI/<Atlas>.lsx` with region `TextureAtlasInfo` (`TextureAtlasIconSize`, `TextureAtlasPath { Path, UUID }`, `TextureAtlasTextureSize`) and region `IconUVList` (`IconUV { MapKey, Width, Height, U1, V1, U2, V2 }`), plus the texture bank entry for that UUID and the DDS. MCM: `Public/Shared/GUI/UIBasic_24-96.lsx` + `Public/Shared/Assets/Textures/Icons/UIBasic24-96.dds`.

Unverified: whether atlases/banks under `Public/DarkAndGate/...` are picked up (MCM puts its files under `Public/Shared/...` with unique names). Try `Public/DarkAndGate` first; fall back to MCM's layout with `DAG_`-prefixed file names. DDS format: BC3/BC7 with alpha (unverified which BG3 accepts for UI; MCM's are DDS).

### Cropping, absolute placement, layering

- **UV sub-rect: yes.** Set `img.ImageData.UV0 = {0, 1-p}`, `UV1 = {1, 1}`, `Size = {w, h*p}` and move it down by `h*(1-p)` to clip an orb's liquid from the bottom to `p`. With an atlas icon, compute inside the icon's own UVs (they are pre-filled by `BindIcon`).
- **Positioning:** every element has `PositionOffset` (relative, scaled) and `AbsolutePosition` (window-local `SetCursorPos`, not scaled) (`IMGUI.cpp:333-339`, `PropertyMaps/IMGUI.inl:38-39`), plus `SameLine` / `SamePosition`. A full-viewport window at `SetPos({0,0})`, `SetSize(viewport)` makes `AbsolutePosition` = screen pixels, and layers stack in child order (frame -> liquid -> glass) because each item re-sets the cursor.
- **Borderless, no input, transparent:** `GuiWindowFlags` include `NoTitleBar, NoResize, NoMove, NoInputs, NoBackground, NoScrollbar, NoSavedSettings, NoFocusOnAppearing, NoNav` (`Enumerations/IMGUI.inl:418-441`). We already do this: `Client/Combat/HUD.lua:45-57` and `Client/AnimLib/Gallery.lua:38-39` (with `NoBackground`). Window API: `SetPos(pos, cond?, pivot?)`, `SetSize`, `SetBgAlpha`, `Flags`, `LastSize/LastPosition` (`PropertyMaps/IMGUI.inl:109-122`).
- **Draw-list (lines/arcs/circles): none.** SE exposes no `ImDrawList` calls to Lua (only the backends touch draw lists: `DX11.inl:176`, `Vulkan.inl:218`). A crosshair arc or bow-draw ring must be art: N pre-rendered arc segments/frames, or one ring image whose visible part is a UV-cropped rect (works for straight bars, not a true radial wipe). `AddProgressBar` covers straight charge bars.
- **Scale:** per window `Scaling = "Absolute" | "Scaled"` (`Objects.h:376`, `Enumerations/IMGUI.inl:736-739`): `Scaled` multiplies sizes/offsets by SE's UI scale (`Objects.h:73-108`); `AbsolutePosition` is never scaled. Global `Ext.IMGUI.SetUIScaleMultiplier` / `SetFontScaleMultiplier` (ReleaseNotes `Docs/ReleaseNotes.md:161`) affect every mod's ImGui, MCM included, so avoid them. Fonts: `Ext.IMGUI.LoadFont(name, path, size)` then `element.Font = name` (MCM `Client/Helpers/IMGUI/Font.lua:128` loads a TTF from its pak).
- **Cost:** retained-mode objects rendered natively each frame (`IMGUIManager` frame loop, `IMGUI.cpp:2160-2195`); Lua only runs when we change a property. Textures are ref-counted and unloaded a few frames after the last user (`IMGUI.cpp:2201-2290`). No numbers documented (unverified). Keep the current pattern: throttle Lua updates (HUD.lua does 10 Hz) and only write fields that changed.
- **Caveat:** ImGui draws over everything, including BG3's pause menu, dialogue and loading screens. We have to hide our HUD ourselves outside POV combat (we already gate on `State.povOn and State.IsCombatActive()`, `HUD.lua:121`). Past crash fixes around texture binding (`ReleaseNotes.md:149, 168, 182`) mean: never bind a non-2D or missing texture; pcall every bind.

## 2. Hiding / restoring BG3's own HUD

### What `Ext.UI` exposes (client only)

`Ext.UI` functions (`Lua/Libs/ClientUI/Module.inl:181-194`): `GetRoot()` (Noesis `MainCanvas`, `:56-60`), `GetStateMachine()` (`:62-66`), `SetState(...)` (**deprecated, only logs an error**, `:70-73`), `RegisterType`, `Instantiate` (custom viewmodels), `GetPickingHelper`, `GetCursorControl`, `GetDragDrop`, `EnableErrorReporting`.

Noesis element methods (`GameDefinitions/PropertyMaps/UI.inl`): `GetProperty/SetProperty` and plain field get/set for any Noesis or dependency property (`:9-14`, fallback `Lua/Libs/ClientUI/NsHelpers.inl:51-93`; enum values can be set by name, `NsHelpers.inl:608-612`), `Find(name)`, `Child(i)`, `ChildrenCount`, `Parent` (`:139-144`), `VisualChild(i)`, `VisualChildrenCount` (`:121-123`), `Subscribe/Unsubscribe` routed events (`:132-133`). `ui::UIWidget` adds `FileName`, `StateId`, `LayerIndex`, `PlayerId` (`:183-194`).

### Finding the widgets

- Brawl does it by name under `ContentRoot`: `for _, child in ipairs(Ext.UI.GetRoot():Find("ContentRoot").Children) do if child.Name == "PlayerPortraits" then … child.DataContext …` (`reference/Brawl/.../Client/Main.lua:284-292, 804-812, 1119-1127`). SE's own doc uses `GetRoot():Find("ContentRoot"):VisualChild(1)` (`Docs/API.md:1327`). Brawl also walks `GetRoot():Child(1):Child(1):Child(i)` and matches `XAMLPath` (`Main.lua:715`).
- Widget names = the XAML root `x:Name`. The `PlayerHUD` UI state (`Mods/MainUI/GUI/StateMachines/Keyboard.xaml:748-767` in Game.pak) loads: `Overlay, HudIndicator, OverheadInfo, HotBar (layer HUDTop), Minimap, TargetInfo, PlayerPortraits, TurnModeInfo, CombatLog, CombatantsOverlay, CursorText, DragAndDropPreview, PassiveRoll, AlwaysOnTopOverlay`. Confirmed `x:Name`s: `HotBar`, `PlayerPortraits`, `CombatLog` (line 1-2 of each page). The others are assumed to match their file names (unverified).

### Levers, best first

| Lever | How | Status |
| --- | --- | --- |
| **A. Noesis `Visibility`** | For each HUD widget under `ContentRoot`: remember the old value, set `w.Visibility = "Collapsed"` (or `w:SetProperty("Visibility", "Collapsed")`); restore the saved value. Hide set: `HotBar, PlayerPortraits, CombatLog, Minimap, TargetInfo, TurnModeInfo, CombatantsOverlay, HudIndicator` (keep `OverheadInfo` for enemy bars/subtitles if wanted). | API exists; **unverified in-game** |
| A'. `Opacity = 0` + `IsHitTestVisible = false` | Fallback if the game's own bindings/triggers write `Visibility` back. | unverified |
| B. UI state change | `Ext.UI.SetState` is deprecated (no-op). `GetStateMachine()` is read-only data. No supported way to push/pop a state. | not usable |
| C. Photo mode | Hides the UI but takes over camera and input. | not usable |
| D. Osiris `HideUI` | The string `HideUI` sits among Osiris built-in names in `bg3.exe` (next to `CameraActivate`, `HideShroud`). It may be a function or just a parameter name; no story goal uses it. | **unverified lead**; probe with `pcall(Osi.HideUI, …)` on the server |
| E. A vanilla "hide HUD" key | No such input event or UI state event exists in the keyboard state machine (only `Toggle…` panel events). | none found |

### Risks

- **Persistence across states.** Dialogue (`HideStatesBelow="True"`, `Keyboard.xaml:1623`), menus and level loads hide/show the HUD state themselves. If the widget instance survives, our `Collapsed` persists through dialogue (fine) but must be restored when POV turns off. If the widget is recreated (level load, session load, reset), it comes back visible, so re-apply on `GameStateChanged`, `SessionLoaded` and every ~1 s while POV is on (cheap: ~8 lookups). Unverified which happens.
- **Input:** a collapsed widget takes no mouse hits. Hotbar number keys are game input events, which we already swallow in POV (`Client/Combat/Input.lua:185-193`). Hiding `PlayerPortraits` removes portrait click-select; Brawl drives it through `DataContext.SelectCharacter`, which should still work while hidden (unverified).
- **Splitscreen / MP:** widgets are per player (`UIWidget.PlayerId`). On separate PCs each client hides its own; no server involvement needed.
- **Always restore** on POV off, `reset`, and session unload, or the player is left with no HUD.

## 3. Keys Q and R

| Key | Vanilla BG3 (PC default) | Our mod (Lua + native) | WASD 1.9.9 / Native Camera Tweaks tomls |
| --- | --- | --- | --- |
| Q | Most likely `CameraRotateLeft` (E = `CameraRotateRight`); event names confirmed in `bg3.exe`, the default key is **unverified** (BG3's defaults are compiled in; the `PlayerProfiles/Default/inputconfig.json` in Engine.pak is generic engine data: `DefaultCameraDown = q`) | not bound | not bound |
| R | No known default (**unverified**) | not bound | not bound |

- Our bound keys: `H`, `NUM_1..NUM_0`, `SPACE` (`Client/Combat/Input.lua:141-193`), `W/A/S/D` (`Client/Movement/Jump.lua:378-383`, native `RealJump.cpp:167-170`), `PAGEUP/PAGEDOWN` (`Client/AnimLib/Browser.lua:571-577`).
- WASD toml binds only `ToggleWalkspeed = key:lshift`, `ReloadConfig = key:f11`, the rest empty. Camera Tweaks toml has no key binds.
- The player's `inputconfig_p1.json` only overrides `CharacterMove*` (W/A/S/D + arrows + stick).
- **Conflict:** `docs/DESIGN.md:55` already gives **Q = put the spell away**. The HUD art proposes Q = health potion, R = mana potion (`design/hud.md`, open question). Needs a developer decision.
- **Verify in-game (one console line):** iterate `Ext.Input.GetInputManager().InputScheme.InputBindings[1]` and `InputDefinitions[id]` (`GameDefinitions/Input.h:201-236`, `Lua/Libs/ClientInput.inl:39`) and print the events bound to Q and R. Whatever we take, block it with `e:PreventAction()` in POV like the number keys.

## 4. Potions

**Do it on the server** (server owns inventory and item use; the client sends `use_potion {kind="health"}` over our net channel).

- **Finding them:**
  - Osiris: `Osi.GetItemByTagInInventory("HEALING_POTION_1879a93d-2edf-4f54-85dd-81a3724d677f", char)` -> the first match only (Larian uses it in `GLO_Tutorials.txt:1756`). `Osi.ItemTagIsInInventory(tag, char)` -> count. `Osi.TemplateIsInInventory(template, char)` -> count, and `Osi.GetItemByTemplateInInventory(template, char)` -> item (both used widely in story goals).
  - **Best potion:** try the root templates from best to worst with `GetItemByTemplateInInventory`. From `Shared/.../Object.txt:5435-5478`, all `ObjectCategory "PotionHealing"`, `UseCosts "BonusActionPoint:1"` (inherited from `_Potion`, `:5417-5428`):

    | Stat | RootTemplate | ValueLevel |
    | --- | --- | --- |
    | `OBJ_Potion_Healing_Supreme` | `7d78f227-e8d4-486d-8121-25cf0bee751d` | 7 |
    | `OBJ_Potion_Healing_Superior` | `df4f3495-abaf-4732-b82f-55bcccd561db` | 5 |
    | `OBJ_Potion_Healing_Greater` | `e3b95c96-dc26-40fe-bfc0-baa05e1abd20` | 3 |
    | `OBJ_Potion_Healing` | `d47006e9-8a51-453d-b200-9e0d42e9bbab` | 1 |

  - Or generic, also catches modded potions: walk `entity.InventoryOwner.Inventories[i].InventoryContainer.Items[slot].Item` (`Components/Inventory.h:13-39`, as Brawl does in `Server/Utils.lua:35-56`), read `item.Data.StatsId` (`Components/Stats.h:55-61`), then `Ext.Stats.Get(statsId)`: `ItemUseType == "Potion"` (Brawl `Encounters/Loot.lua:64`) and `ObjectCategory == "PotionHealing"` (field access unverified); rank by `ValueLevel`. `item.Use` (`UseComponent`: `Charges`, `ItemUseType`, `Boosts`, `Stats.h:131-145`).
- **Drinking:** `Osi.Use(character, item, "")` (Larian: `Act1_DEN_Apprentice.txt:1211` `Use(_Player, S_DEN_Antidote_…, "")`; Brawl `Server/Quests.lua:26`). Unverified: whether it plays the drink animation and charges the bonus action under our real-time combat, and whether it is refused mid-swing.
- **Mana:** BG3 has no mana potions. Closest vanilla: spell-slot restoring shouts such as `Shout_MAG_SpellSlotRestoration_1..6` and `Shout_MAG_SpellSlotRestoration_PearlOfPower_*` (`RestoreResource(SpellSlot,1,N)`, GustavDev `Spell_Shout.txt:872, 3237`), granted by items like the Pearl of Power. No consumable in `Object.txt` restores slots. Options: (a) our own potion item (new Object stat + root template, `Use` handled by our server Lua to refill our mana pool), (b) a hotbar action that spends something (e.g. a long cooldown "focus" restore), (c) map a vanilla consumable (e.g. a specific elixir) to mana. Option (a) fits the design (mana is ours).

## 5. XP (client)

`entity.Experience` = `eoc::exp::ExperienceComponent { CurrentLevelExperience, NextLevelExperience, TotalExperience }` (`GameDefinitions/Components/Data.h:614-622`; IDE `ExtIdeHelpers.lua:601`). Level: `entity.AvailableLevel.Level` (`Data.h:624-629`), level-up ready tag `CanLevelUp` (`Data.h:631`). Bar fill = `CurrentLevelExperience / NextLevelExperience` (assumed: "current level" is XP into the level; check against the character sheet). Replication to the client is **unverified**; fall back to a server read sent over the net channel.

## 6. HP (client)

`entity.Health` = `eoc::HealthComponent { Hp, MaxHp, TemporaryHp, MaxTemporaryHp, IsInvulnerable }` (`Components/Data.h:59-69`). Already read on the client for targets (`Client/Combat/Aim.lua:36, 340`). The player entity: `Ext.Entity.GetAllEntitiesWithComponent("ClientControl")[1]` as in `Aim.lua:38-45`.

## Recommendation

- **Engine for v1: SE ImGui images.** Everything needed exists and is data-only: our own DDS layers via a texture bank entry (UUID -> `AddImage`), bottom-up clipping via `ImageData.UV0/UV1/Size`, screen-pixel placement in a full-screen `NoInputs | NoBackground` window via `AbsolutePosition`, tint for pulses, spell icons by stat `Icon` name, `AddProgressBar` or cropped art for charge bars. We already ship borderless ImGui windows. Arcs need pre-rendered art (no draw-list API).
- **Not Noesis for v1:** SE cannot add new XAML widgets from Lua (only custom viewmodels via `RegisterType/Instantiate`). A Noesis HUD means overriding a vanilla page in our pak, as MCM does with `Mods/MainUI/GUI/Pages/GameMenu.xaml`. That conflicts with other UI mods and breaks on game patches. Keep it for M4 if ImGui looks wrong.
- **Hiding vanilla:** lever A. On POV on: `Ext.UI.GetRoot():Find("ContentRoot")`, for each child whose `Name` is in `{HotBar, PlayerPortraits, CombatLog, Minimap, TargetInfo, TurnModeInfo, CombatantsOverlay, HudIndicator}`, save `Visibility` and set `"Collapsed"`. Re-apply about every 1 s while POV is on and after state changes. On POV off, `reset` or session unload: restore the saved values. If the game fights back, use `Opacity = 0` + `IsHitTestVisible = false`. First playtest step: the hide/restore round-trip, including dialogue and the pause menu.
- **Open for the developer:** Q is "put spell away" in DESIGN.md versus the health potion in the HUD art; R (mana potion) has no known vanilla conflict.
