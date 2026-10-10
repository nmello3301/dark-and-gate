# Playtest: "Movement feels good" round (2026-10-09)

One pass, about 15 minutes. Logs: `scripts\read-log.ps1` (client.log + server.log) and `Script Extender\DarkAndGate\native.log` (DLL). Console commands go to the client: type `client`, then the `!dag_…` command.

**Setup**
1. Load **DEV-SAVE**. Console: `client`, then `!dag_full_pov on`. Stand still in an open spot (no cutscene trigger: don't walk north yet).

## 1. Camera A/B: pivot vs head

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 1.1 | Stand still 3 s, then `!dag_pov_status` (head anchor is the default) | client: `FullPov A/B: anchor=head src=bone eye=… head=… delta=… jerk=…`; native.log: `HEAD calibrate: eye = Head_M + 0.xxx m` (once) and every 3 s `CAM delta anchor=head src=bone … jump=0` | — |
| 1.2 | `!dag_pov_anchor pivot`, stand still 3 s, `!dag_pov_status` | `FullPov: camera anchor = engine pivot …`; `FullPov A/B: anchor=pivot src=pivot eye=…`; `CAM delta anchor=pivot src=pivot … avg=0.0000` | Same eye height and the same slide when looking straight down as in 1.1? |
| 1.3 | In **each** anchor (`!dag_pov_anchor head` / `pivot`): walk 3 s (W), run 3 s (Shift, then W), swing LMB twice, jump standing, jump while running | `CAM delta anchor=… src=bone|pivot …` lines while you do it; one `JUMP lift seq=… liftSrc=… anchor=…` per jump | Head mode: does the view stay glued to the body with no jitter? Any shake, lag or bob that bothers you? |
| 1.4 | Only if 1.3 felt jittery in head mode: `!dag_pov_smooth 0.3`, repeat the walk + run | `FullPov: head smoothing = 0.30`; `CAM delta … smooth=0.30` with a lower `jerk` | Better? (`!dag_pov_smooth 0` turns it off) |

Leave the anchor on **head** for the rest (`!dag_pov_anchor head`).

## 2. Walk by default, Shift toggles run, speed knob

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 2.1 | Hold W after loading | you **walk** (BG3WASD `WalkingIsDefault = true`); native.log at load: `MOVE: WASD template fetch hooked at rva 0x425F428 …` and `MOVE: BG3WASD WalkSpeed=0.30 -> walk lerp t=0.250` | Walking by default? |
| 2.2 | Tap Left Shift, hold W; tap Shift again | run, then walk again. Shift+W must **not** start autoforward (unbound) | Toggle works? Anything else on Shift that misbehaves? |
| 2.3 | `!dag_move_status` | `Move: walk_speed=1.00 run_speed=1.00 speed_mult=1.00 -> walk x1.00 run x1.00 … DLL move=ok tmplStroll=1.40 tmplRun=3.75 walkT=0.250 …` (numbers are Gale's template) | — |
| 2.4 | `!dag_speed_mult 0.5`, walk 3 s, run 3 s | `Move: speed walk x0.50 run x0.50 …`; native.log `MOVE: walk x0.500 run x0.500 …`; client `Move: gait=walk speed=~1.0m/s expect walk=1.00 run=1.88 loco rate x0.50` then `gait=run … loco rate x0.50` | Half speed? Feet slide or not? |
| 2.5 | `!dag_speed_mult 1.5`, walk 3 s, run 3 s, then `!dag_move_status` | `walk x1.50 run x1.50`; `gait=run speed=~5.6m/s … loco rate x1.50`; status `rateHits=` > 0 means the play rate reaches the walk/run clips | Faster? Feet slide? Any rubber-banding? |
| 2.6 | `!dag_walk_speed 1.3`, `!dag_run_speed 0.8`, walk + run; then `!dag_speed_mult 1`, `!dag_walk_speed 1`, `!dag_run_speed 1` | walk x1.30 run x0.80, then back to x1.00 | Walk and run change separately? |

## 3. Jump while walking and running

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 3.1 | Walk forward, Space; keep holding W and steer with A/D in the air | client `Jump: start seq=… T=1.28s h=0.55m … moving=yes wasd=held`; then either `Jump: moving clip check ok (x -> y m/s with WASD held)` or `Jump: moving clip ROOTED the walk …` (then clips are skipped on moving jumps, logged `clips=off on moving jumps …`); `Jump: landed … wasd=held`. native.log `JUMP lift seq=… liftSrc=body …` | Kept moving and steering through the jump? Body and camera rose together? Clean return to walking? |
| 3.2 | Run (Shift), Space, keep W held | same, `speed=` ~3.7 m/s | Same questions, at run speed |
| 3.3 | Space twice quickly in the air | `Jump: ignored (already airborne, no double jump)` | — |
| 3.4 | `!dag_jump_mult 2`, jump while running; `!dag_jump_mult 0.5`, jump while running; `!dag_jump_mult 1.6` | `Jump: mult=2.00 (airtime 1.60s)` / `0.50 (airtime 0.40s)`; `Jump: start … T=1.60s` / `T=0.40s` (`!dag_jump_height 0.8` works the same way) | Arc right in both? |

Lift source per jump (native.log `JUMP lift`): `liftSrc=body` = the body carried the lift, camera follows the head; `body+camera-fill` = the camera had to add lift the body lost (expected only for a few frames, `fillFrames` small); `camera-only` = the body hook failed.

## 4. Swing and cast in the air

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 4.1 | Stand, Space, LMB right after take-off | `Swing: #1 anim … action=0.90s (airborne)`; `Jump: clips suspended for swing at u=0.2x (lift continues)`; `Actions: play rate x1.00 (swing start)`; then `Jump: resumed descend|land after swing at u=…` | Swing plays fully at normal speed while you keep rising and falling? |
| 4.2 | Space, LMB just before landing | `Jump: landed … (landing clip waits for swing(…))`, then `Jump: landing clip after the action (N ms after touchdown)` or `… skipped …` | Landing never cuts the swing? |
| 4.3 | Arm Fire Bolt (key 1), Space, LMB mid-air at a goblin or the ground | `Jump: clips suspended for prepare …` (arming), `Prepare: stop Projectile_FireBolt (cast)`, server `SpellCast: CAST …`, `Jump: resumed … after cast` or the landing waiting for `cast(…)` | Cast plays, arc continues? |
| 4.4 | Single LMB on the ground, wait 2 s, single LMB again | each click: `Swing: start #1 …` + `Swing: #1 anim …`, server `Net: PlayAnim uuid=… anim=…` | **First click animates?** (open item from last round) |
| 4.5 | Three single LMB clicks ~0.5 s apart | `Swing: start #1`, `#2`, `#3` (no `buffered` needed) | Chain plays 1→2→3? |

## 5. Arm Fire Bolt: prepare loop

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 5.1 | Press 1 (arm Fire Bolt), wait 3 s | `Hotbar: ARMED slot 1 = Projectile_FireBolt …`; first time: `Prepare: Projectile_FireBolt SpellAnimation (stats …) 0=<id> 1=<id> 2=<id> …` and `Prepare: Projectile_FireBolt prepare=<id> (x.xxs) loop=<id> (…)`; `Prepare: start … -> prepare …`; then `Prepare: Projectile_FireBolt loop <id> …` | Prepare pose, then a held loop? The right animation for a Fire Bolt? |
| 5.2 | LMB | `Prepare: stop Projectile_FireBolt (cast) …`; server `Net: scripted clip stopped on … (before cast)`, `SpellCast: CAST …` | Cast came out straight away (no delay)? |
| 5.3 | Press 1, wait 2 s, RMB | `Prepare: stop … (cancel-rmb)`; server `Net: scripted clip stopped on … (stop request)` | Back to idle cleanly? |
| 5.4 | Press 1, walk, press 1 again | `Hotbar: UNARMED …`, `Prepare: stop … (cancel-key)` | Back to walking cleanly? |

If 5.1 shows the wrong clip, paste nothing: the `SpellAnimation` line has every slot, and `!dag_prepare_info Projectile_FireBolt` prints it again.

## 6. Head stays hidden after swapping gear

| # | Do | Expect (log) | Tell me |
| --- | --- | --- | --- |
| 6.1 | MMB (cursor), open the inventory, unequip and re-equip the helmet / chest armour, close, MMB back | `Spike11: re-hide on visual/equipment change event -> N renderable(s) re-hidden` (a 200 ms check of the player's visual attachments; the first build's engine event subscriptions crashed the game at load and are gone) | Head/face stays hidden after the swap? Any flash? |
| 6.2 | Walk around 30 s | no `re-hid` spam; at most a few `Spike11: re-hid …` lines (1 s check) | Face showing at any point? |

## Feel questions (the log can't answer these)

1. Pivot vs head: which do you prefer while walking, running, attacking and jumping?
2. Walk/run speeds: do x0.5 / x1.5 look right with the feet planted?
3. Moving jump: does it feel like one floaty arc while you keep moving?
4. Mid-air swing / cast: does the action read clearly over the jump?
5. Fire Bolt prepare loop: right pose, right length?
