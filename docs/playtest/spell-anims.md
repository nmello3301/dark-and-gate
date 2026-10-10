# Playtest: spell channel animations (2026-10-10)

Console: `client` first, then the commands. Logs: client.log / server.log, `Script Extender\DarkAndGate\native.log`.

## 0. One-time capture of BG3's spell event (POV off)

The arg order of BG3's spell animation event isn't decoded, so it's captured from one vanilla cast.

1. Load **DEV-SAVE**. Run `!dag_genome_events on`.
   - Expect `Genome: logging the player's animation gameplay events …`.
2. With the normal camera, cast **Fire Bolt** from the vanilla hotbar at the ground.
   - Expect `Genome event ba293d56-… args(21) 0:AnimationSimpleName=… …`, plus a few other `Genome event` lines.
3. Select Fire Bolt again and cancel it with **right-click**.
   - Expect more `Genome event …` lines.
4. Run `!dag_genome_events off`.
   - Expect `Genome: template saved (21 args, cancel=<guid or nil>) -> DarkAndGate/genome-spell-template.txt`.
   - If you get `no ba293d56 event captured`, or no `Genome event` lines appeared at all, stop and send the log: the event list wasn't readable from Lua.

## 1. Resolution

Run `!dag_spell_anims Projectile_FireBolt`, then `Projectile_Fireball`, then `Target_MistyStep`.

- Expect `SpellAnims: <spell> rig=HUM_M sets=… prepare ok / loop ok / cast ok / recover ok`.
- Then a slots line and `prepare=3ff87abf… HUM_M_Rig_VIO_SPL_Bard_01_Prepare (2.13s)` (Fire Bolt).
- Misty Step lists its own clips.

## 2. Arm Fire Bolt standing (`!dag_full_pov on`, key 1)

| Expect | Log |
| --- | --- |
| Prepare plays, filling exactly 2.0 s | `Prepare: start Projectile_FireBolt via genome event -> prepare HUM_M_Rig_VIO_SPL_Bard_01_Prepare (2.13s clip at x1.07 = 2.00s cast time), loop …` |
| | native.log: `RATE: clip rates on …: 3ff87abf-…:1.065 (1 ids)` |
| Loop at READY | `Prepare: Projectile_FireBolt READY after 2.0xs -> loop …` |
| LMB: cast → fires → recover → idle | `Prepare: stop Projectile_FireBolt (cast) … (was READY)`; server `SpellCast: CAST …`; native `RATE: clip rates … 20.000 (2 ids)`, then `Prepare: release guard over` |

Tell me: does the prepare match the cast time, and is there a second prepare after LMB?

## 3. Same while walking and running

- Expect `Spells: casting slow ON (x0.70)`, then `off` at READY.
- No rooting.
- The legs hold the cast pose (sliding accepted).

Tell me: is movement free, and how does the slide look?

## 4. `!dag_cast_time 1.0`, arm Fire Bolt

- Expect `Spells: base cast time = 1.00s (override)`, then `… (2.13s clip at x2.13 = 1.00s cast time)` and `READY after 1.0xs`.
- Reset with `!dag_cast_time` (no value).

## 5. Cancel: arm then RMB; arm then key 1 again

- Expect `Prepare: cancel via event <guid>` (or `none (no cancel event captured)`), then `Prepare: stop … (cancel-rmb|cancel-key)`.

Tell me: does Gale leave the pose cleanly?

## 6. Arm, jump, release in the air

- Expect `Jump: clips suspended for prepare …`, then `Prepare: stop … (cast)`.
- The arc continues; the landing comes after.

## 7. Fireball (key 2) and Misty Step (key 3)

- Expect a `Prepare: start …` line with each spell's own clips.

## 8. Shadowheart (switch character, arm Fire Bolt via `!dag_hotbar 1 Projectile_FireBolt` if needed)

- Expect `SpellAnims: Projectile_FireBolt rig=HUM_F … prepare ok / …`, or the gaps with `[fallback anims]`.
