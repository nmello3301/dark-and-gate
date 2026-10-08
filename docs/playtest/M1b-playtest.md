# M1b combat playtest — single pass, DEV-SAVE (round 2)

**Build date:** 2026-10-08, round 2. First pass had every combat input swallowed because `State.povOn` never flipped true. This build sets it directly from `FullPov.setOn()`. See the status table at the bottom.

Run steps in order. If a step fails, note which, keep going — later steps don't depend on earlier results.

## Step 1 — Baseline diagnostic (10 s, no gameplay)

1. Launch BG3 → load `DEV-SAVE`.
2. Open the SE console, type `client`.
3. **Before** entering POV: `!dag_combat_status`.
   - Expect: `povOn=false realTime=true inFight=false armedSpell=nil mana=60/60 IsCombatActive=false lastInput=(none)`.
   - If `povOn=true` here, something's wrong — report.
4. `!dag_full_pov` to toggle POV on.
5. `!dag_combat_status` again.
   - Expect: `povOn=true ... IsCombatActive=true lastInput=(none)`.
   - **If `povOn=false` after `!dag_full_pov`:** the Fix 1 wiring didn't take — stop and report.
6. Click LMB in empty air once.
7. `!dag_combat_status`.
   - Expect: `lastInput=Mouse Left1 down@... gateActive=true`.
   - If `gateActive=false`, something's gating us; report.

## Step 2 — Dummy spawn (template probe)

1. `!dag_spawn_dummy`.
2. Watch `client.log`. Three outcomes to look for:
   - **Success:** `SpawnDummy reply: OK uuid=<x> template=<name> tier=<training|any-dummy|act1-goblin> at (...)`. A hostile npc should appear ~3 m north of you.
   - **Template matched but CreateAt failed:** `SpawnDummy reply: FAIL reason=CreateAt failed` with the attempted template logged — tell me and we'll pick a different one.
   - **No template matched any tier:** `SpawnDummy reply: FAIL reason=no template matched the ranked patterns` **followed by** 10 `cand[N] name=... uuid=...` lines. Paste these back; we add the right pattern or name to the probe.
3. If spawn worked, walk to the dummy. If it didn't, skip to Step 5 — melee works against anything hostile.

## Step 3 — Melee swing (no spells, no block)

1. Face the dummy ~2 m away. Click **LMB** once.
   - Expect: `Swing: start #1 (swing1_R2L) damage=8.0 reach=2.2` + a `HUD: hit <uuid> zone=torso dmg=8` line.
   - If no `Swing: start`, run `!dag_combat_status` and report `lastInput`.
2. LMB three times fast in sequence.
   - Expect chain 1 → 2 → 3 (`swing1_R2L` → `swing2_L2R` → `swing3_overhead`).
3. Aim low at the dummy's feet, LMB → expect `zone=limbs dmg=4`.
4. Aim at the dummy's head/upper body, LMB → expect `zone=head dmg=16`.
5. `!dag_swing_debug on`, swing once, `!dag_swing_debug off`.
   - Expect: per-sample `SwingDbg: eye=... fwd=... arc=100 rays=7 reach=2.2 hit=<uuid>` lines in `client.log`.
6. Back off 5 m, LMB → expect **no** `HitValidator: HIT`, no HUD hit line (out of reach).

## Step 4 — Block (stub)

1. Hold **RMB**.
   - Expect: `Combat: block ON (stub, no DR applied)`.
2. Release RMB.
   - Expect: `Combat: block OFF`.
3. No visible gameplay change — stub confirms the input gate flips. If no log line appeared, run `!dag_combat_status` and report `lastInput`.

## Step 5 — Spells (arm-then-cast, HARD mode)

1. Press **1** (Fire Bolt in default slot 1).
   - Expect: `Hotbar: ARMED slot 1 = Target_FireBolt (LMB to cast, RMB or same slot to cancel)`.
   - HUD should show `ARMED: Fire Bolt`.
2. Look at the dummy. HUD should read `AIM: target <uuid> [N m]`. Then **LMB**.
   - Expect: `Spells: request Target_FireBolt (Fire Bolt) target=<uuid>` + `SpellCast: UseSpell ...` on the server + Fire Bolt visibly fires on the dummy.
3. Press **1** again (same slot) — nothing to cancel after cast; verify it ARMs again (`Hotbar: ARMED ...`).
4. Press **1** a second time → `Hotbar: UNARMED Target_FireBolt (same slot re-pressed)`. HUD line disappears.
5. Press **1** to arm, aim at empty sky (no target), **LMB**.
   - Expect: `Spells: NO TARGET IN SIGHT for Target_FireBolt -- aborting cast`.
   - Mana unchanged (no cooldown, no cost).
6. Press **2** (Fireball). HUD shows `AIM: Fireball at (x, y, z) [N m]` while you move the crosshair over ground. **LMB** to cast at ground.
   - Expect `SpellCast: UseSpellAtPosition caster=... spell=Projectile_Fireball cost=32 at (x, y, z)`.
   - If `UseSpellAtPosition` isn't available, Fireball will log an error and fall back to self — tell me (we remove the fallback if it fires).
7. Press **3** (Misty Step), aim at ground, **LMB**. Expect teleport or `UseSpellAtPosition err` log.
8. Arm **1** (Fire Bolt), press **RMB** (not LMB).
   - Expect: `Combat: canceled armed spell (RMB) was=Target_FireBolt`.
   - No cast fired.
9. Arm **1**, press **2** → re-arms as Fireball (`Hotbar: ARMED ... Projectile_Fireball`).
10. `!dag_mana refill`. HUD mana back to max.
11. `!dag_mana` → prints current pool.
12. Spam Fireball until mana < 32, press **2** and **LMB** → expect `SpellCast: INSUFFICIENT MANA spell=Projectile_Fireball cost=32 have=<x>`, no cast.

## Step 6 — Hotbar

1. `!dag_hotbar 4 Target_FireBolt`.
   - Expect: `Hotbar: slot 4 = Target_FireBolt`.
2. Press **4**, aim at dummy, **LMB**. Fire Bolt casts same as slot 1.
3. `!dag_hotbar_reset`.
   - Expect: `Hotbar: reset to defaults`. Slot 4 clears, 1-3 back to Fire Bolt / Fireball / Misty Step.
4. Press **H**.
   - Expect: `Hotbar: window open` and an ImGui window titled "Dark and Gate — Prepare Hotbar" (or the fallback log line if ImGui is unavailable this build). Binding is M4; use `!dag_hotbar` for now.

## Step 7 — Goblin fight (open-ended, last)

1. Walk north from DEV-SAVE spawn until the goblin fight triggers.
2. Fight using melee (LMB without arming) and arm-then-cast spells (`1`/`2`/`3` → LMB).
3. **Goblin AI is still vanilla this pass.** If BG3 pushes you into turn-based combat, that's expected until the Brawl import lands. The goal here is to feel whether the ray-fan hits land where the crosshair points under real combat pressure.

## When you're done

Send:
- `native.log` (DLL side)
- `client.log` + `server.log` (`scripts\read-log.ps1` merges them)
- SE console scrollback

And tell me, in one sentence each:
- Which steps passed cleanly, which failed, which were ambiguous.
- Any crashes or black screens.
- Whether the arm-then-cast flow felt natural or awkward.
- If `!dag_spawn_dummy` failed with the candidate list, paste the 10 `cand[N]` lines so we can pick a template that exists in this install.

## Status table (round 2)

| Feature | real / partial / stub | Switch / command |
| --- | --- | --- |
| First-person camera (M1a) | real | `!dag_full_pov` |
| `State.povOn` propagation | **real (fix 1)** | FullPov.setOn → State directly |
| IsCombatActive gate (POV + no modal UI) | **real (fix 1)** | works in exploration for dummy tests |
| `!dag_combat_status` diagnostic | **real (fix 5)** | prints every gate + mana + lastInput |
| `State.lastInputEvent` tracking | **real (fix 5)** | pre-gate; silent gate shows up as log line |
| LMB melee swing + ray-fan hit + damage | real | gated on `IsCombatActive` + no armed spell |
| 3-swing longsword chain with zones | real | `data/weapons/longsword.lua` |
| Mana pool + regen + spend + HUD | real | `!dag_mana`, `!dag_mana refill` |
| Fire Bolt via crosshair aim (arm → LMB) | **real (fix 4)** | key `1`, then LMB |
| Fireball / Misty Step point cast | partial | `UseSpellAtPosition` → log on failure |
| Target spell no-target → abort | **real (fix 3)** | `Spells: NO TARGET IN SIGHT ...` |
| Arm-then-cast HARD mode | **real (fix 4)** | number → arm, LMB → cast, RMB / same key → cancel |
| HUD ARMED indicator + aim readout | **real (fix 4)** | ImGui window while POV on |
| Fireball ground marker | partial | text readout `AIM: Fireball at (x, y, z)` in HUD; VFX decal is M4 |
| RMB block / parry | stub | log line only, no DR |
| Hit VFX / SFX / hit-stop | stub | log only |
| Crosshair reticle | stub | screen centre |
| Dummy template probe (name-based) | **real (fix 2)** | `!dag_spawn_dummy` logs chosen template + tier |
| Dummy spawn client reply | **real (fix 2)** | `DAG_SpawnDummyReply` writes to `client.log` |
| POV body-mesh anchor in combat | partial | still engine pivot; unverified in actual fights |
| Brawl AI / real-time combat loop | stub | goblin fight is still BG3 turn-based |
| BG3WASD RotatePlusLeftclick=false | real | repo-mirrored in `config/native/BG3WASD.toml` |
