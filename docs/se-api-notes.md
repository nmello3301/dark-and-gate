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

### Input events (client)

Verified by spike 1 on 2026-10-08.

- `Ext.Events.KeyInput:Subscribe(fn)` — called for every keyboard event. Event shape: `{ Event: SDLKeyEvent, Key: SDLScanCode, Modifiers: SDLKeyModifier, Pressed: bool, Repeat: bool, CanPreventAction: bool }`.
- `Ext.Events.MouseButtonInput:Subscribe(fn)` — called for mouse button events. Shape: `{ Button: int, Pressed: bool, Clicks: int, X: int, Y: int, CanPreventAction: bool }`. `Button == 1` is LMB, `3` is RMB (SDL convention).
- `event:PreventAction()` on either event blocks BG3's default handler from running. Confirmed to work for LMB, RMB, and the digit row — the character doesn't move, context menus don't open, hotbar slots don't fire. The log subscriber still sees the event, so our handlers run while BG3's don't.
- Digit-row scancodes stringify as `NUM_1`..`NUM_0`, not `Key1`..`Key0` as the IDE helpers' `SDLScanCode` enum suggests.
- The IDE helpers (`reference/bg3se/BG3Extender/IdeHelpers/ExtIdeHelpers.lua`) list these events under names like `EclLuaKeyInput` / `EclLuaMouseButton` with an `Ecl` prefix. **Those are wrong.** The runtime names, taken from `LuaClient.cpp:161,171`, are `KeyInput` and `MouseButtonInput`. If a subscription silently never fires, verify against `BG3Extender/Lua/Client/LuaClient.cpp` rather than the IDE helpers.

### Console commands

- `Ext.RegisterConsoleCommand(name, fn)` registers a command that is invoked from the SE console with a **`!` prefix** (`!dag11_dump`). The command only fires when the console is in the Lua state that registered it, so a client-registered command needs the console in client context (`client` to switch to `C >>`). Verified 2026-10-08 (initial Spike 11 run tripped on this because `dag11_dump` was typed without `!`).

### Logging

- `Ext.Utils.Print(...)` goes to the SE debug console (when `CreateConsole: true` in `ScriptExtenderSettings.json`) and to the SE runtime log (when `EnableLogging: true` and `LogRuntime: true`). Default SE settings in release builds have `CreateConsole: false`; we rely on an explicit settings file.
- SE runtime log location (verified 2026-10-07): `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\Extender Runtime <timestamp>.log` — note the trailing *` Logs`* on the folder, which is a sibling of the SE data folder, not inside it.
