# M1b combat playtest — single pass, DEV-SAVE

**Build date:** 2026-10-08. First M1b slice: real combat vertical, not everything from the design doc. Status table at the bottom.

Run everything in order. Each step should start from the end state of the previous. If a step fails, note which, then skip ahead — later steps don't depend on earlier results.

## Setup (90 seconds)

1. Launch BG3 → load `DEV-SAVE`.
2. Open the SE console, type `client`, then run `!dag_full_pov` to enter first person.
   - Expect: head anchors at Gale's eyes; head/hair/beard hidden; MMB toggles mouselook.
   - **If camera is third-person or clips the head:** stop and report `native.log` from load → now.
3. In the console: `!dag_mana`.
   - Expect: `Mana: 65 / 65  +1.3/s` or similar (depends on Gale's INT).

## Step 1 — Dummy spawn + melee swing

1. `!dag_spawn_dummy`.
   - Expect `native.log`-style line `Dummy: spawned <uuid> at ...` or `Dummy: all templates failed`.
   - **If "all templates failed":** skip to step 2 — melee needs a target.
2. Walk forward until the dummy is in front of you (3 m away).
3. Click **LMB** once.
   - Expect `[Client] Swing: start #1 (swing1_R2L) damage=8.0 reach=2.2` and the attack animation plays.
   - If the ray-fan hits the dummy, `[Client] HUD: hit <uuid> zone=torso dmg=8`.
   - **If nothing happens on LMB:** POV / combat gate off → run `!dag_rt on` and `!dag_full_pov on`.
4. Click LMB three times fast.
   - Expect: swings 1 → 2 → 3 (`swing1_R2L` → `swing2_L2R` → `swing3_overhead`) with the overhead ending the chain.
5. `!dag_swing_debug on`, swing once, then `!dag_swing_debug off`.
   - Expect per-sample `SwingDbg: eye=... fwd=... arc=100 rays=7 reach=2.2 hit=<uuid>` lines in `client.log`.
6. Walk 5 m away from the dummy, LMB.
   - Expect: no HitClaim fires (range gate). Server log should NOT show `HitValidator: HIT`.

## Step 2 — Block (stub)

1. Hold **RMB**.
   - Expect `[Client] Combat: block ON (stub, no DR applied yet)`.
2. Release RMB. No visible gameplay change — this is a stub, no DR, no parry. Just confirm the flag flips in the log.

## Step 3 — Spells and mana

1. Press **1** (Fire Bolt).
   - Expect `[Client] Spells: request Target_FireBolt (Fire Bolt)`, server casts, mana drops by 0 (level-0 cantrip is free).
   - Fire Bolt should visibly fire at the dummy and damage it.
2. Press **2** (Fireball, cost 32).
   - Expect `[Client] Spells: request Projectile_Fireball` and `[Client] HUD: ... mana ...` showing drop. Fireball may land at caster feet if `UseSpellAtPosition` isn't available — that's the known partial.
3. Press **3** (Misty Step, cost 20).
   - Expect either a teleport or `[Server] SpellCast: UseSpellAtPosition err`. Either outcome is acceptable this pass.
4. `!dag_mana refill`.
   - Expect mana back to max; `[Client] HUD` mana bar refills.
5. Keep pressing **1** until mana wouldn't be enough for Fireball, then press **2**.
   - Expect `[Server] SpellCast: INSUFFICIENT MANA spell=Projectile_Fireball cost=32 have=<x>` and no cast.

## Step 4 — Hotbar

1. `!dag_hotbar` (no args) — currently a no-op (prints usage).
2. `!dag_hotbar 4 Target_FireBolt` — expect `[Client] Hotbar: slot 4 = Target_FireBolt`.
3. Press **4** → Fire Bolt casts (same as slot 1).
4. `!dag_hotbar_reset` → expect `[Client] Hotbar: reset to defaults`, keys 1-3 populated again.
5. Press **H**.
   - Expect `[Client] Hotbar: window open` and an ImGui window titled "Dark and Gate — Prepare Hotbar" with the slot list (or `Hotbar: ImGui not available` fallback). ImGui binding of assigns is M4; use the console command for now.

## Step 5 — Goblin fight (open-ended)

1. Walk north from DEV-SAVE spawn until the goblin fight triggers.
2. Fight: swing + spell. **Goblin AI is still vanilla for this pass** — they attack via BG3's own turn-based intent. If BG3 pushes you into turn-based, that's expected until `!dag_rt` wires through Brawl (archived).
3. Record how the swing feels: does the ray fan land where the crosshair points? Does Fire Bolt go where you aim?

## When you're done

Send `native.log` + the SE console scrollback for the session. Also tell me:

- Which steps passed cleanly, which failed, which were ambiguous.
- Any crashes or black screens.
- Overall "does this feel like a combat loop" judgment, even if rough.

## Status table

| Feature | Real / partial / stub | Switch |
| --- | --- | --- |
| First-person camera (M1a) | real | `!dag_full_pov` |
| LMB melee swing + ray-fan hit | real | gated on POV + `!dag_rt` (default on) |
| 3-swing longsword chain | real | `data/weapons/longsword.lua` |
| Server-side damage (ApplyDamage) | real | automatic on `HitClaim` |
| Mana pool + regen + spend | real | `!dag_mana`, `!dag_mana refill` |
| Fire Bolt via crosshair aim | real | key `1`, `!dag_hotbar 1 Target_FireBolt` |
| Fireball / Misty Step | partial | fall back to `UseSpell` if `UseSpellAtPosition` missing |
| Hotbar key handling (1-0, H) | real | `!dag_hotbar <slot> <spellId>` |
| Hotbar ImGui window | partial | H toggles; binding is console-only for now |
| Mana HUD | real | ImGui window shown while POV on |
| Crosshair reticle | **stub** | not drawn — rely on screen centre |
| RMB block + parry | **stub** | flag flips, no DR, no parry window |
| Hit feedback (VFX, SFX, hit-stop) | **stub** | log only |
| POV anchors to body-mesh root (combat focus) | **partial** | still engine-pivot; expected OK out of combat, unverified in combat |
| Real-time combat loop (Brawl import) | **stub** | goblin AI stays vanilla until Brawl wiring; `!dag_rt` only gates our input |
| Debug: `!dag_spawn_dummy` | real | server CreateAt goblin template probe |
| Debug: `!dag_swing_debug` on/off | real | logs per-sample ray fan |
| BG3WASD `EnableRotatePlusLeftclickMovesForward` | real | patched to false (so LMB attacks instead of walking) |

Deferred to the Archived (future) list in ROADMAP.md:
- Head-bone anchor and bone reads (M1a archive) — the ray-fan hit above doesn't need bones.
- `SetAnimPlaySpeed` / hit-stop — logs only.
- Directional ragdoll push — no engine lever.
