# Playtest: spell channel animations (2026-10-10)

Console: `client` first, then the commands. Logs: client.log / server.log, `Script Extender\DarkAndGate\native.log`.

How it plays: arming a spell replays BG3's own **select** event with that spell's prepare and loop clips. The prepare is stretched to the cast time, then the loop holds. LMB lets the engine play cast → recover. Cancel replays BG3's **cancel** event with the spell's un-prepare clip. Layouts were captured from your vanilla Fire Bolt ([genome-capture.md](../spikes/genome-capture.md)).

## 1. Resolution

Run `!dag_spell_anims Projectile_FireBolt`, then `Projectile_Fireball`, then `Target_MistyStep`.

- Expect `SpellAnims: <spell> rig=HUM_M sets=… prepare ok / loop ok / cast ok / recover ok`.
- Then a slots line with `6=eadedcce` (Fire Bolt), and `prepare=3ff87abf… HUM_M_Rig_VIO_SPL_Bard_01_Prepare (2.13s)`.
- Misty Step lists its own clips.
- For each phase, expect `SpellAnims: Projectile_FireBolt prepare 3ff87abf in every set:` followed by one line per set / subset (clip name and length). Expect one for the staff.
- Expect `SpellAnims: stance …, weapon set …`.

## 2. Arm Fire Bolt standing (`!dag_full_pov on`, key 1)

**If the game crashes here, stop and tell me** (paste native.log's last lines).

| Expect | Log |
| --- | --- |
| Gale draws the staff (no draw animation), server log | `SpellCast: arm Projectile_FireBolt Sheathing=(default) -> unsheath (ok)` |
| The prepare waits for the staff | `Prepare: Projectile_FireBolt waits up to 0.40s for the weapon (stance Sheathed)` (only when sheathed) |
| Prepare plays, filling exactly 2.0 s | `Prepare: start Projectile_FireBolt via select event to 0x… (stance Melee after 0.0xs) -> prepare … (… = 1.9xs left of 2.00s), loop …` |
| | native.log: `RATE: clip rates on …: 3ff87abf-…:1.0x (1 ids)` |
| Loop at READY | `Prepare: Projectile_FireBolt READY after 2.0xs -> loop …` |
| LMB: cast → fires → recover → idle | `Prepare: stop Projectile_FireBolt (cast) … (was READY)`; server `SpellCast: CAST …`; then `Prepare: release guard over` |
| Hand fire + prepare sound, then the loop sound | `SpellFx: start Projectile_FireBolt: effect c88e9cfa -> 0x…, sound Spell_Prepare_… -> true, sound …_Loop -> true` |
| Fire and loop sound end at LMB; vanilla cast fire / sound play | `SpellFx: stop Projectile_FireBolt (cast) effect destroyed true, sounds stopped ok` |

Tell me: is it now the same prepare as vanilla (staff in hand)? Does Gale play the Fire Bolt prepare and then the loop? Does the prepare end right as READY shows? Is there a second prepare after LMB? Are the hand fire and the sounds there, and do they look and sound like vanilla?

## 3. Same while walking and running

- Expect `Spells: casting slow ON (x0.70)`, then `off` at READY.
- No rooting.
- The legs hold the cast pose (sliding accepted).

Tell me: is movement free, and how does the slide look?

## 4. `!dag_cast_time 1.0`, arm Fire Bolt

- Expect `Spells: base cast time = 1.00s (override)`, then `… (2.13s clip at x2.13 = 1.00s cast time)` and `READY after 1.0xs`.
- Reset with `!dag_cast_time` (no value).

## 5. Cancel: arm then RMB; arm then key 1 again

- Expect `SpellFx: stop … (cancel-rmb|cancel-key) effect destroyed true, sounds stopped ok`.
- Then `Prepare: cancel via cancel event eadedcce`, then `Prepare: stop … (cancel-rmb|cancel-key)`.

Tell me: does Gale leave the pose cleanly, like a vanilla right-click cancel?

## 6. Arm, jump, release in the air

- Expect `Jump: clips suspended for prepare …`, then `Prepare: stop … (cast)`.
- The arc continues; the landing comes after.

## 7. Fireball (key 2) and Misty Step (key 3)

- Expect a `Prepare: start …` line with each spell's own clips, and each spell's own prepare on screen.

## 8. Shadowheart (switch character, arm Fire Bolt via `!dag_hotbar 1 Projectile_FireBolt` if needed)

- Expect `SpellAnims: Projectile_FireBolt rig=HUM_F … prepare ok / …`, or the gaps with `[fallback anims]`.
