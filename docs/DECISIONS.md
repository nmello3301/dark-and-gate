# Decisions log

Newest first. One line per decision: date, decision, reason. Link the spike note when a spike decided it.

| Date | Decision | Why |
| --- | --- | --- |
| 2026-10-08 | M1 ships a native plugin bundling tight camera follow + named-bone world positions. Build it before Gate 1 ([spike 3](spikes/03-weapon-bone-reads.md), [spike 11](spikes/11-head-hiding.md#known-artifact-camera-follow-lag-during-movement)) | Both features touch engine state SE doesn't expose: `CameraController.WorldTransform` has single-tick lifetime, `Visual.MeshBinding.Pose` is `[[bg3::hidden]]`. Spikes 7 and 10 run next; if either also needs native, bundle them in. |
| 2026-10-08 | Aim ray from Lua: camera world transform via `rf::Camera.InvViewMatrix`, raycast via `Ext.Level.RaycastClosest`, hit position reconstructed as `from + dir * Distance` since `hit.Position` is bugged ([spike 2](spikes/02-aim-ray.md)) | Verified in-game. Covers melee aim and spell targeting without a native plugin. Only `hit.Normal` remains unavailable; defer surface-aligned effects or add Normal to the native plugin later. |
| 2026-10-08 | Input capture + suppression uses `Ext.Events.KeyInput` / `MouseButtonInput` + `event:PreventAction()` from the client Lua state ([spike 1](spikes/01-input-capture.md)) | Verified in-game: LMB, RMB and 1–0 all observable, and PreventAction blocks BG3's default handler for every one. No native hook needed for input. |
| 2026-10-08 | Head/hair/beard hiding uses `Visual.ObjectDescs[i].Renderable.PropertyList.RenderPasses = 0` on matched sub-visuals, local client only ([spike 11](spikes/11-head-hiding.md)) | Confirmed in-game: VisualFlags writes and Attachment.Offset writes don't take at runtime; RenderPasses is the per-frame live field the renderer reads. |
| 2026-10-07 | True first person: camera on the head bone, local player's head and headwear hidden on their own client; never shrink the character (spike 11) | A camera at eye height sees inside the head; shrinking is a hack |
| 2026-10-07 | Traversal highlights: faint glow on vines, ladders, climbable walls, stairs and jump-up ledges (M4) | First person makes the ways up hard to spot |
| 2026-10-07 | Native mods load through Ch4nKyy's Mod Loader (`bin\version.dll`), not Native Mod Loader; never install both | WASD 1.9.9 supports it, it is current, and two loaders can load the same DLLs twice |
| 2026-10-07 | Dev save `DEV-SAVE`: just before the goblin attack at the Emerald Grove entrance | First real fight of the game, reachable in seconds |
| 2026-10-07 | Windows only, PC only | Every player runs Windows; the Script Extender is required |
| 2026-10-07 | Mana pool replaces spell slots: 30 + 10·CL + 5·M, regen 0.5 + 0.1·CL + 0.1·M per second, cost by spell level | Steady regen fits real-time combat; stronger casters get more mana |
| 2026-10-07 | 10-slot hotbar on keys 1–0, set in a "Prepare Hotbar" tab in the native character menu (ImGui window until M4) | Fast spell access in first person without BG3's turn-based hotbar |
| 2026-10-07 | Companions: Follow / Wait / Camp out of combat; shared real-time AI in combat | One AI for both sides; keeps camp, approval and banter native |
| 2026-10-07 | Built client/server with net channels from day one; multiplayer ships in M6 | Avoids a rewrite for co-op |
| 2026-10-07 | Design document approved | Developer sign-off |
