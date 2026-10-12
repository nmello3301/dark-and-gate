# Playtest: HUD + projectiles v1 (Pass A, 2026-10-12)

## Round 3 (2026-10-12): the camera works again

Round 2: our HUD drew ("looks amazing"), but **the camera didn't turn at all** and MMB didn't help. In the Tab / I menus the **cursor was invisible**, so the new Prepare Hotbar menu couldn't be used. Everything after R2.3 was blocked by this.

**Cause:** our full-screen HUD window was set up with `win.Flags = {...}`. The Script Extender has no `Flags` field: each window flag is its own true/false field (`win.NoInputs = true`). The assignment errored, and a `pcall` hid the error. So the HUD went up as a normal, hoverable window over the whole screen. While a hoverable ImGui window is under the cursor, SE drops every mouse event before BG3 gets it (`Extender/Client/SDL.cpp`, `io.WantCaptureMouse`): mouse moves, MMB, and the DLL's own "hold Camera Rotate" press. In round 1 this window was never built, because its texture didn't load.

**Fixes:**
- Every ImGui window's flags are now set field by field and read back (`Client/HUD/WindowFlags.lua`). The HUD refuses to show a window that can't be made click-through, and falls back to the status line instead.
- When the last menu closes, mouse-look waits 200 ms (`data/hud.lua` `menu_release_ms`) until our menu window is gone. That way the DLL's synthetic MMB press can't land on it.
- When a menu opens or closes, the log records BG3's cursor state. `!dag_cursor` logs it on demand.
- The jump's `%d` format error in `Server/Net.lua` is fixed: it threw on every jump and cut the jump notice to other players. The native log's per-frame `RATE: clip rates …` spam is gone.

| # | Do | Expect | Log |
| --- | --- | --- | --- |
| R3.1 | Load DEV-SAVE, `!dag_full_pov`, move the mouse | Our HUD draws **and the mouse turns the camera**. MMB: cursor appears, camera stops; MMB again: mouse-look back. | `Hud: built <w>x<h> … 3 slot icons, click-through` (no `flags not set`). No `HUD: ##DAG_… flags not set` line. native.log: `POV: mouselook ON (MMB toggles)` |
| R3.2 | **Tab** | Party view opens, BG3's HUD comes back, **the cursor shows**, our Prepare Hotbar menu is on the right. Tab again: menu closes, mouse-look is back about 0.2 s later. | `Hud: menu PartyPanel open -> cursor free (mouse-look off), BG3 HUD back`, `Hud: cursor after menu open: BG3 ShowCursor=<…> cursor=<…> DLL holds rotate=false`; on close `Hud: menus closed -> mouse-look back on`, `Hud: cursor after menus closed: … DLL holds rotate=true`. native.log: `POV: mouselook OFF (menu open)` / `ON (MMB toggles)` |
| R3.3 | **I**, then close it | Same with the inventory. | `Hud: menu CharacterPanel open …`, same cursor lines |
| R3.4–R3.10 | Rows **R2.4–R2.10** below: bind a spell from the menu, cast it from its key, H pin, reload keeps the layout, Fire Bolt at the moving goblin (straight, then leading it), at a wall, Fireball | As in round 2 | As in round 2 |
| R3.11 | Jump a few times | Same jump | `Net: Jump uuid=<…> dur=1280ms h=0.80 (hitbox lifted)`. No `deferred Osi error … Net.lua:269` |

If the cursor is still invisible in a menu: with the menu open, open the SE console and type `client`, then `!dag_cursor`. It logs `Hud: cursor now: …`, which shows whether BG3 thinks the cursor is shown and whether the DLL still holds Camera Rotate.

## Round 2 (2026-10-12): fixes from round 1 + the Prepare Hotbar menu

Round 1: BG3's HUD hid, but **ours didn't draw** (its texture bank wasn't loaded: it shipped only as `merged.lsx` under `Public/DarkAndGate`); **Tab stopped working** (collapsing PlayerPortraits killed its key binding); the **projectile hits were BG3's own** (Lua can't write a spell's damage fields, so the "visual" copy still dealt damage; our flight started 1.2 s late and the server's world ray rejected the "Door" physics group).

Fixes:
- HUD texture now ships the way MCM's does (`Public/Shared/...`, `merged.lsf` + an icon atlas), and is drawn by icon name.
- BG3's widgets are hidden with opacity, so their keys keep working.
- The clones come from a stats file.
- The server polls for BG3's projectile every tick.
- The world ray now uses groups the server accepts.

| # | Do | Expect | Log |
| --- | --- | --- | --- |
| R2.1 | Load DEV-SAVE, `!dag_full_pov` | **Our HUD draws**: orbs, hotbar, potions, XP. BG3's hotbar / portraits / log are gone. | `Hud: atlas icon DAG_HUD_bar bound (texture 5b0b4f6e-…)`, `Hud: built …`, `VanillaHud: hidden HotBar, PlayerPortraits, …`. If instead `Hud: atlas icon DAG_HUD_bar did NOT bind …`, the status line shows, and SE's console has a warning saying why: copy that line to me. |
| R2.2 | **Tab** | BG3's party view opens; BG3's HUD comes back; the **cursor is free** (mouse-look off); **our Prepare Hotbar menu** is on the right. Tab again closes it, and mouse-look comes back. | `Hud: menu PartyPanel open -> cursor free (mouse-look off), BG3 HUD back`, `HotbarMenu: built`, then `Hud: menus closed -> mouse-look back on`. native.log: `POV: mouselook OFF (menu open)` / `ON` |
| R2.3 | **I** (also K, Esc) | Same for the inventory (and the spellbook / game menu; our menu appears with I / K only). | `Hud: menu CharacterPanel open …` / `menu GameMenu open …` |
| R2.4 | In the menu: click slot **4**, then a spell from the list (e.g. one of Gale's level-1 spells) | The spell's icon is in slot 4, the selection moves to the next empty slot, and the HUD's hotbar shows the new icon. **Clear slot** / **Defaults** work. Search filters by name. | `HotbarMenu: slot 4 = <spell id>` |
| R2.5 | Close the menu, press **4**, wait, **LMB** | That spell channels and casts like the others (its own prepare animation and mana cost). | `Hotbar: CASTING slot 4 = …`, `SpellCast: CAST …`. If it's rejected: `SpellCast: REJECTED … (<uuid> doesn't have it)` |
| R2.6 | **H** | Pins the menu open with the cursor free anywhere in first person; H again closes it. | `HotbarMenu: pinned open …` / `closed` |
| R2.7 | Reload the save (or switch character) | The layout you set is still there (per character). | `Hotbar: loaded the saved layout of <uuid>` |
| R2.8 | Fire Bolt at the **moving** goblin, straight at it, then leading it | Straight shots miss more often. Led shots hit and deal damage **once** (no BG3 double hit). The bolt flies from your hand at the crosshair. | `ProjectileSpells: Projectile_FireBolt -> DAG_V_Projectile_FireBolt loaded (SpellRoll= SpellSuccess= …)`, `Projectiles: server world ray uses groups Terrain,Scenery,Item`, `PROJ #n flight starts (BG3 projectile DAG_V_Projectile_FireBolt seen after <ms> ms) …`, `PROJ #n HIT character … via CreateExplosion(…) ok; BG3 projectile: RequestDelete set`, `PROJ #n target HP a -> b (damage applied)`. Misses: `PROJ #n expired … (closest character <uuid> passed <m> m from its cylinder)` |
| R2.9 | Fire Bolt at a wall / the ground | It stops there, and BG3's bolt vanishes there. | `PROJ #n HIT world at (…)` |
| R2.10 | Fireball at the goblin | One explosion where our orb touched it (Dex save, 4 m). | `PROJ #n HIT character … via CreateExplosionAtPosition …` |

Tell me:
- Does BG3's bolt **look** right: start, path, vanishing at the hit?
- Does the cast still feel right?
- Is the menu usable: size, clicking, the spell list?

The round-1 table below still applies to everything else (cast bar, potions, bow ring, the 8-item checklist).

One pass on **DEV-SAVE**. Everything is in the deployed pak (no `reset` needed). After the run, `scripts\read-log.ps1` shows the merged log. The expected log lines are quoted so they can be grepped; `<…>` marks a value that varies.

Arrows and throwables (Part C) are **not built** in this pass: they come only after the spell projectiles pass this test.

## 0. Start

1. Load DEV-SAVE. Open the SE console, type `client`, then `!dag_full_pov`.
2. Expected at load:
   - `Hud: registered (art HUD, …)`
   - `ProjectileSpells: Projectile_FireBolt -> visual DAG_V_Projectile_FireBolt created, impact DAG_I_Projectile_FireBolt created (StatsLoaded)`, and the same for `Projectile_Fireball`, on both server and client. Any `(errors: …)` there matters.
   - `Projectiles: OnCreate(ServerProjectile) subscribed`
   - `HudStats: registered …`

## 1. HUD

| # | Do | Expect on screen | Expect in the log |
| --- | --- | --- | --- |
| 1.1 | Enter first person | Your HUD at the bottom centre: health orb, hotbar, potion slots, XP bar, mana orb. BG3's hotbar, portraits and combat log are gone. The crosshair stays. | `Hud: atlas texture 5b0b4f6e-… found in the texture bank` (or `can't check …, drawing it anyway`), `Hud: built <w>x<h> scale <s> …, 3 slot icons`, `VanillaHud: hidden HotBar, PlayerPortraits, CombatLog, … (first person)`. Any `-- not found: <names>` is fine; it lists BG3 widgets that weren't there. |
| 1.2 | Look at the hotbar | Slots 1–3 show the Fire Bolt, Fireball and Misty Step icons. The key numbers 1…0 are on the hotbar (where the art had them). The potion plates read **R** and **T**. Under the orbs: `<hp>/<max> HP` and `<mana>/<max> MP`. | `Hud: stats from server: XP <cur>/<next> (level <n>), potions health <n> mana 0` |
| 1.3 | Press **1** | Slot 1 glows gold. The blue cast bar above the hotbar fills over 2 s (`Fire Bolt 1.2s`…), then turns bright and pulses (`READY Fire Bolt`). | |
| 1.4 | **RMB** | The bar drains back to empty in about 0.3 s; the glow goes. | |
| 1.5 | **1**, wait for READY, **LMB** at the ground | The bar flashes and disappears. | |
| 1.6 | **2** (Fireball) with less than 32 mana (cast it until you run low) | The Fireball icon greys / blues out when the pool can't pay for it. The mana orb's liquid drops with every cast and refills slowly; the bright line rides the surface. | |
| 1.7 | Cast **Fireball** about 3 m in front of your feet (you take damage) | The health orb drains to the new HP and the numbers update. Below 25 % the orb pulses. | |
| 1.8 | **R** | You drink your best healing potion and the HP orb rises. The `x<n>` count drops. With no potion, nothing happens. | `Hud: potion key -> health`, then `HudStats: health potion -> <Supreme/Superior/Greater/Healing> potion <uuid>: Osi.Use ok` or `HudStats: health potion -> none in the inventory` |
| 1.9 | **T** | The mana flask is dimmed (BG3 has no mana potions yet). | `HudStats: mana potion -> none (BG3 has no mana potions; ours comes later)` |
| 1.10 | `!dag_bow_bar demo` | An amber ring around the crosshair fills in 1 s, with a white mark at 30 %, glows at full, then disappears after 1 more second. `!dag_bow_bar 0.5` holds it half full; `!dag_bow_bar off` hides it. | `Hud: bow ring demo` |
| 1.11 | Talk to someone (dialogue) | Your HUD hides, BG3's comes back; after the dialogue, yours returns and BG3's hides again. | `VanillaHud: restored … (first person off / dialogue / cutscene)`, then `VanillaHud: hidden … (first person)` |
| 1.12 | Open the inventory (I), then the pause menu (Esc) | **Tell me:** does our HUD stay drawn over them? (Menu detection uses guessed widget names.) With the inventory open, type `!dag_hud widgets`. | `Hud: BG3 HUD widgets: <Name>=<Visible/Collapsed>, …`: this gives me the real menu names. |
| 1.13 | `!dag_hud vanilla`, then `!dag_hud off`, then `!dag_hud on` | vanilla: both HUDs. off: only BG3's. on: only ours. | `Hud: mode vanilla/off/on`, `VanillaHud: restored … (!dag_hud …)` |
| 1.14 | `!dag_full_pov` off | BG3's HUD is fully back. | `VanillaHud: restored …` |

**Look and feel (tell me):**
- Size and placement at your resolution (`data/hud.lua`: `width_frac` 0.58, `bottom_px` 34).
- Whether the numbers line up with the plates and slots. ImGui can't measure text from Lua, so centring is estimated.
- Whether the text font size is right (`font_numbers` / `font_keys`).
- Whether the art looks crisp or blurry.

## 2. Projectiles: Fire Bolt and Fireball

`!dag_spawn_dummy` makes a still goblin 3 m to +X; `!dag_spawn_dummy moving` makes one 9 m ahead that walks back and forth across your view over 6 m. Neither is hostile, so the game stays out of turn-based.

| # | Do | Expect | Log |
| --- | --- | --- | --- |
| 2.1 | `!dag_spawn_dummy`, then hit it with Fire Bolt | Gale casts as before. The bolt flies at the crosshair and the goblin takes fire damage on contact. **Tell me** whether BG3's bolt vanishes at the hit or flies through. | Server: `Projectiles: Projectile_FireBolt template 792ba497…: InitialSpeed <v>, VelocityMode <m>, Acceleration <a>` (the first cast only); `PROJ #<n> launch Projectile_FireBolt: origin … speed <v> m/s …, visual clone DAG_V_Projectile_FireBolt cast at (…)`; `SpellCast: CAST projectile flight spell=Projectile_FireBolt cost=0`; `PROJ #<n> flight starts (BG3 projectile seen after <ms> ms), BG3 projectile SourcePos … is <d> m from our origin`; `PROJ #<n> HIT character <uuid> at (…) after <m> m / <s> s zone <head/torso/limbs>: impact DAG_I_Projectile_FireBolt lvl <n> via CreateExplosion(<uuid>) ok; BG3 projectile: RequestDelete set`; `PROJ #<n> target HP <a> -> <b> (damage applied)`. Client: `ProjView #<n>: launch …`, `ProjView #<n>: client projectile FOUND via <component> …; components: …` or `… NOT found …`, up to 6 `ProjView #<n>: t=<s>s BG3 visual at …, our flight at …, drift <m> m`, `ProjView #<n>: character at … (max visual drift <m> m)` |
| 2.2 | Fireball at the still goblin | The explosion happens where our orb touched it (4 m area, Dex save). | `PROJ #<n> HIT character … via CreateExplosionAtPosition (…) ok`, `… target HP … (damage applied)` |
| 2.3 | `!dag_spawn_dummy moving`, then Fire Bolt aimed **straight at** it while it walks | It often misses, flying past behind it. | `PROJ #<n> HIT world …` or `PROJ #<n> expired after 120.0 m (no hit)` |
| 2.4 | Same, but **lead** the shot (aim ahead of it) | It hits mid-flight, wherever the goblin is when the bolt reaches it. **Tell me** how leading felt (speed). | `PROJ #<n> HIT character …` |
| 2.5 | Fire Bolt at a wall or rock | It stops at the wall. BG3's bolt should vanish there. | `PROJ #<n> HIT world at (…)` |
| 2.6 | Jump, and cast Fire Bolt at the still goblin at the top of the jump | It flies from where your eyes are in the air and hits. | `Net: JumpLift from the client: <uuid> is <m> m up (server hitbox follows the real jump)` (first jump only), `JumpReport: landed, peak lift sent to the server <m> m`, then `PROJ #<n> launch … origin (…)` with an origin about 1 m higher than a ground cast |
| 2.7 | Misty Step | Unchanged; it isn't a projectile. | `SpellCast: CAST UseSpellAtPosition …` |

Things only you can tell me:
- Did BG3's own projectile **look** right: start at Gale's hand, follow the crosshair line, vanish on the hit?
- Whether steering looked smooth or jittery. Both are in `ProjView` drift lines: `steering … works` means the call was accepted, not that it looked right.
- Any double damage: the visual clone has no effect, so there should be none.

## 3. Checklist (the 8 items from 2026-10-09 / 10-10, tick while you play)

- [ ] **First jump of a session works** (fix `42ba492`). If the 2nd jump glitches instead, look for `RJUMP: Falling Update hooked` in native.log.
- [ ] **LMB spam** (3 fast clicks): WASD still works, and `!dag_unstick` isn't needed.
- [ ] **Head-bone camera**: the view stays glued to the body while attacking.
- [ ] **Face never flashes**, including after a gear change.
- [ ] **Cylinder hitboxes**: swing reach is measured to the body, and a goblin's cylinder matches its body (also exercised by the projectile hits above).
- [ ] **Casting slows** to x0.7 on the ground and full speed at READY (`Spells: casting slow ON / off`).
- [ ] **No foot sliding**: locomotion clips play at the gait's speed.
- [ ] **Actions in the air**: a swing or cast in the air plays, the arc continues, and the landing waits.

## Known, not bugs

- The 2 s channel, mana and cooldowns are unchanged; only the flight and the impact are ours.
- Fireball's flight has no gravity in v1 (`data/projectiles.lua` `gravity`), so it flies straight like Fire Bolt.
- Fireball ground preview (B5): not in this pass.
- A mana potion item doesn't exist yet. T is wired but finds nothing.
